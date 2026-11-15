--[[
    BleBox plugin dla vCLU (v0.2.0)

    Fabryka obiektow dla urzadzen BleBox z API "switchBox" (switchBox, switchBoxD)
    po lokalnym HTTP. Tak jak @vclu/tasmota-switch: plugin nie ma wlasnej
    konfiguracji, urzadzenia konfiguruje sie w kodzie przez create().

    Uzycie:
        local bb = Plugin.getPlugin("@vonxavier/blebox")

        -- jeden przekaznik (switchBox) albo wybrany przekaznik switchBoxD (relay = 0 lub 1)
        local lampa = bb:create({ deviceId = "ee64c9c7496d", relay = 0, name = "Lampa" })

        lampa:on()
        lampa:off()
        lampa:toggle()
        lampa:onChange(function(new, old) print(new) end)

        expose(lampa, "switch", { name = "Lampa" })

    deviceId = "Identyfikator urzadzenia" z aplikacji BleBox. Adres IP nie jest potrzebny:
    plugin znajduje urzadzenie po id i sam sledzi zmiane adresu (DHCP).
]]

local plugin = Plugin:new("blebox", {
    name = "BleBox",
    version = "0.2.0",
    description = "Factory for BleBox switchBox objects (local HTTP)"
})

-- pcall, jesli sandbox go nie ma, wywolujemy funkcje bez ochrony
local _pcall = pcall or function(f, ...) return true, f(...) end

local MAX_FAILS = 3          -- tyle bledow z rzedu = urzadzenie offline
local VERIFY_EVERY = 60      -- co ile sekund sprawdzic, czy pod adresem jest to samo urzadzenie
local HTTP_TIMEOUT = 3000    -- ms
local PROBE_TIMEOUT = 800    -- ms, odpowiedz na skanowanie
local SCAN_CONCURRENCY = 10
local SCAN_COOLDOWN = 30     -- s, minimalny odstep miedzy skanami tej samej podsieci

local defaultSubnet = "192.168.1"
local records = {}       -- key -> rekord urzadzenia (wspolny dla wszystkich przekaznikow urzadzenia)
local knownIps = {}      -- deviceId -> ostatni adres IP (zapisywane w KV)
local discovered = {}    -- deviceId -> { id, ip, product } (znalezione skanem)
local scanning = {}      -- podsiec -> true gdy trwa skan
local lastScan = {}      -- podsiec -> os.time() ostatniego skanu

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function toState(v)
    if v == true or v == 1 or v == "1" or v == "on" or v == "ON" then
        return 1
    end
    return 0
end

local function call(cb, ...)
    if cb then _pcall(cb, ...) end
end

local function sanitize(s)
    return (string.gsub(tostring(s), "[^%w_]", "_"))
end

local function encodeIps(map)
    local parts = {}
    for id, ip in pairs(map) do
        parts[#parts + 1] = id .. "=" .. ip
    end
    return table.concat(parts, ";")
end

local function decodeIps(s)
    local map = {}
    if type(s) ~= "string" then return map end
    for id, ip in string.gmatch(s, "(%w+)=([%d%.]+)") do
        map[id] = ip
    end
    return map
end

local function rememberIp(id, ip)
    if id and ip and knownIps[id] ~= ip then
        knownIps[id] = ip
        plugin:kvSet("ips", encodeIps(knownIps))
    end
end

local function label(rec)
    return rec.deviceId or rec.ip or rec.key
end

local function subnetOf(rec)
    return rec.subnet or defaultSubnet
end

--------------------------------------------------------------------------------
-- HTTP
--------------------------------------------------------------------------------

local function getJson(ip, path, timeout, cb)
    plugin:httpRequest({
        url = "http://" .. ip .. path,
        method = "GET",
        timeout = timeout,
        parseJson = "success"
    }, function(resp)
        if resp.err or not resp.ok or type(resp.json) ~= "table" then
            cb(nil, resp.err or ("HTTP " .. tostring(resp.status)))
            return
        end
        cb(resp.json, nil)
    end)
end

-- Sprawdza, czy pod adresem jest BleBox z API switchBox. cb(d) albo cb(nil)
local function probe(ip, cb)
    getJson(ip, "/api/device/state", PROBE_TIMEOUT, function(json)
        local d = json and json.device
        if type(d) ~= "table" or d.type ~= "switchBox" or not d.id then
            cb(nil)
            return
        end
        cb(d)
    end)
end

--------------------------------------------------------------------------------
-- DEVICE RECORD (jedno urzadzenie BleBox, wspolne dla jego przekaznikow)
--------------------------------------------------------------------------------

local function newRecord(key, deviceId, ip, subnet)
    return {
        key = key,
        deviceId = deviceId,
        ip = ip,
        subnet = subnet,
        online = false,
        fails = 0,
        lastVerify = 0,
        lastUpdate = 0,
        lastError = nil,
        product = nil,
        apiLevel = nil,
        count = 0,
        relays = {},     -- numer przekaznika -> 0/1
        switches = {},   -- numer przekaznika -> lista obiektow BleBoxSwitch
        pending = {},    -- numer przekaznika -> true, gdy trwa komenda
        polling = true,
        pollInterval = 2,
        poller = nil
    }
end

local function setOnline(rec, flag)
    if rec.online == flag then return end
    rec.online = flag
    if flag then
        rec.lastError = nil
        plugin:log("info", "BleBox " .. label(rec) .. " online @ " .. tostring(rec.ip))
    else
        plugin:log("warn", "BleBox " .. label(rec) .. " offline")
    end
end

-- force = true: odpowiedz na wlasna komende; false: polling (pomija przekazniki z trwajaca komenda)
local function applyRelays(rec, list, force)
    rec.count = #list
    for k, r in ipairs(list) do
        local idx = tonumber(r.relay)
        if idx ~= nil and (force or not rec.pending[idx]) then
            local st = toState(r.state)
            rec.relays[idx] = st
            local group = rec.switches[idx]
            if group then
                for i, sw in ipairs(group) do
                    sw:_apply(st)
                end
            end
        end
    end
    rec.lastUpdate = os.time()
end

local function markFail(rec, err)
    rec.lastError = err
    rec.fails = rec.fails + 1
    if rec.fails >= MAX_FAILS then
        setOnline(rec, false)
        rec.lastVerify = 0
        -- adres mogl sie zmienic: znane id pozwala znalezc urzadzenie skanem
        if rec.deviceId then rec.ip = nil end
    end
end

--------------------------------------------------------------------------------
-- DISCOVERY (skan podsieci tylko wtedy, gdy trzeba kogos znalezc)
--------------------------------------------------------------------------------

local function adopt(rec, ip, d)
    rec.ip = ip
    rec.fails = 0
    rec.lastVerify = os.time()
    rec.product = d.product
    rec.apiLevel = d.apiLevel
    -- stan od razu, bez czekania na kolejny tik
    getJson(ip, "/api/relay/state", HTTP_TIMEOUT, function(json, err)
        if json and type(json.relays) == "table" then
            setOnline(rec, true)
            applyRelays(rec, json.relays, false)
        else
            markFail(rec, err or "brak stanu przekaznikow")
        end
    end)
end

local function onFound(d, ip)
    rememberIp(d.id, ip)
    if not discovered[d.id] then
        discovered[d.id] = { id = d.id, ip = ip, product = d.product }
        plugin:log("info", "Znaleziono BleBox " .. d.id .. " (" .. tostring(d.product) .. ") @ " .. ip
            .. ", uzyj: create({ deviceId = \"" .. d.id .. "\", relay = 0 })")
    else
        discovered[d.id].ip = ip
    end
    for key, rec in pairs(records) do
        if rec.deviceId == d.id and (not rec.online or rec.ip ~= ip) then
            adopt(rec, ip, d)
        end
    end
end

local function scanSubnet(subnet, reason)
    if scanning[subnet] then return end
    local now = os.time()
    if lastScan[subnet] and now - lastScan[subnet] < SCAN_COOLDOWN then return end
    scanning[subnet] = true
    lastScan[subnet] = now

    local ips, seen = {}, {}
    local function add(ip)
        if not seen[ip] then
            seen[ip] = true
            ips[#ips + 1] = ip
        end
    end
    for id, ip in pairs(knownIps) do add(ip) end
    for i = 1, 254 do add(subnet .. "." .. i) end

    local idx, running, found = 1, 0, 0
    local pump

    pump = function()
        while running < SCAN_CONCURRENCY and idx <= #ips do
            local ip = ips[idx]
            idx = idx + 1
            running = running + 1
            probe(ip, function(d)
                running = running - 1
                if d then
                    found = found + 1
                    _pcall(onFound, d, ip)
                end
                pump()
            end)
        end
        if running == 0 and idx > #ips and scanning[subnet] then
            scanning[subnet] = nil
            plugin:log("info", "Skan " .. subnet .. ".x (" .. reason .. ") zakonczony, znaleziono: " .. found)
        end
    end

    plugin:log("info", "Skan " .. subnet .. ".x (" .. reason .. ")")
    pump()
end

--------------------------------------------------------------------------------
-- POLLING (jeden poller na urzadzenie)
--------------------------------------------------------------------------------

local function tick(rec, done)
    if not rec.ip then
        scanSubnet(subnetOf(rec), "szukam " .. label(rec))
        done()
        return
    end

    local function read()
        getJson(rec.ip, "/api/relay/state", HTTP_TIMEOUT, function(json, err)
            done()
            if json and type(json.relays) == "table" then
                rec.fails = 0
                setOnline(rec, true)
                applyRelays(rec, json.relays, false)
            else
                markFail(rec, err or "brak stanu przekaznikow")
            end
        end)
    end

    if os.time() - rec.lastVerify >= VERIFY_EVERY then
        -- czy pod tym adresem nadal jest to samo urzadzenie (DHCP mogl przydzielic adres innemu)
        probe(rec.ip, function(d)
            if d and (not rec.deviceId or d.id == rec.deviceId) then
                rec.deviceId = rec.deviceId or d.id
                rec.product = d.product
                rec.apiLevel = d.apiLevel
                rec.lastVerify = os.time()
                rememberIp(d.id, rec.ip)
                read()
            else
                done()
                if d then
                    markFail(rec, "pod adresem " .. rec.ip .. " jest inne urzadzenie (" .. tostring(d.id) .. ")")
                else
                    markFail(rec, "brak odpowiedzi")
                end
            end
        end)
    else
        read()
    end
end

local function startPolling(rec)
    if rec.poller or not rec.polling then return end
    rec.poller = plugin:poller("poll_" .. sanitize(rec.key), {
        interval = rec.pollInterval * 1000,
        immediate = true,
        timeout = 15000,
        onTick = function(done)
            tick(rec, done)
        end,
        onError = function(err)
            plugin:log("warn", "BleBox " .. label(rec) .. ": poll - " .. tostring(err))
        end
    })
    rec.poller:start()
end

local function stopPolling(rec)
    if rec.poller then
        rec.poller:stop()
        rec.poller = nil
    end
end

--------------------------------------------------------------------------------
-- COMMANDS
--------------------------------------------------------------------------------

local function sendRelay(rec, relay, want, cb)
    if not rec.ip then
        call(cb, false, "adres urzadzenia nieznany")
        return
    end
    rec.pending[relay] = true

    plugin:httpRequest({
        url = "http://" .. rec.ip .. "/api/relay/set",
        method = "POST",
        json = { relays = { { relay = relay, state = want } } },
        timeout = HTTP_TIMEOUT,
        parseJson = "success"
    }, function(resp)
        rec.pending[relay] = nil
        if resp.err or not resp.ok then
            local err = resp.err or ("HTTP " .. tostring(resp.status))
            plugin:log("warn", "BleBox " .. label(rec) .. " #" .. relay .. ": komenda nieudana (" .. tostring(err) .. ")")
            markFail(rec, err)
            call(cb, false, err)
            return
        end
        rec.fails = 0
        setOnline(rec, true)
        -- odpowiedz zawiera pelny stan wszystkich przekaznikow
        if type(resp.json) == "table" and type(resp.json.relays) == "table" then
            applyRelays(rec, resp.json.relays, true)
        end
        call(cb, true)
    end)
end

--------------------------------------------------------------------------------
-- SWITCH OBJECT (jeden przekaznik)
--------------------------------------------------------------------------------

-- Tablica metod kopiowana do kazdej instancji (sandbox nie ma setmetatable).
local BleBoxSwitch = {}

function BleBoxSwitch:new(rec, options)
    local relay = tonumber(options.relay) or 0
    local ident = rec.deviceId and rec.deviceId or sanitize(rec.ip or rec.key)
    local obj = {
        _type = "switch",
        _rec = rec,
        _relay = relay,
        _id = options.id or ("blebox_" .. ident .. "_" .. relay),
        _name = options.name or ("BleBox " .. ident .. " #" .. relay),
        _value = 0,
        _known = false,
        _eventHandlers = {}
    }
    for name, fn in pairs(BleBoxSwitch) do obj[name] = fn end

    if not rec.switches[relay] then rec.switches[relay] = {} end
    table.insert(rec.switches[relay], obj)
    return obj
end

-- wywolywane przez plugin przy odczycie stanu z urzadzenia
function BleBoxSwitch:_apply(st)
    local old = self._value
    local first = not self._known
    self._known = true
    self._value = st
    if first then
        self:emit("OnChange", st, nil)      -- pierwszy odczyt: old = nil
    elseif st ~= old then
        self:emit("OnChange", st, old)
    end
end

-- Sterowanie (cb opcjonalny: cb(ok, err))

function BleBoxSwitch:on(cb)
    sendRelay(self._rec, self._relay, 1, cb)
end

function BleBoxSwitch:off(cb)
    sendRelay(self._rec, self._relay, 0, cb)
end

function BleBoxSwitch:toggle(cb)
    sendRelay(self._rec, self._relay, self._value == 1 and 0 or 1, cb)
end

function BleBoxSwitch:refresh()
    local rec = self._rec
    if not rec.ip then return end
    getJson(rec.ip, "/api/relay/state", HTTP_TIMEOUT, function(json)
        if json and type(json.relays) == "table" then
            applyRelays(rec, json.relays, false)
        end
    end)
end

-- Konfiguracja (fluent)

function BleBoxSwitch:setId(id)
    self._id = id
    return self
end

function BleBoxSwitch:setName(name)
    self._name = name
    return self
end

function BleBoxSwitch:setIp(ip)
    self._rec.ip = ip
    self._rec.lastVerify = 0
    return self
end

-- polling dotyczy calego urzadzenia (wszystkich jego przekaznikow)
function BleBoxSwitch:setPolling(enabled, intervalSec)
    local rec = self._rec
    rec.polling = enabled
    if intervalSec then rec.pollInterval = intervalSec end
    stopPolling(rec)
    if enabled then startPolling(rec) end
    return self
end

-- Stan

function BleBoxSwitch:getId() return self._id end
function BleBoxSwitch:getDeviceId() return self._rec.deviceId end
function BleBoxSwitch:getRelay() return self._relay end
function BleBoxSwitch:isOn() return self._value == 1 end
function BleBoxSwitch:isOnline() return self._rec.online end
function BleBoxSwitch:getValue() return self._value end

function BleBoxSwitch:getState()
    local rec = self._rec
    return {
        id = self._id,
        name = self._name,
        deviceId = rec.deviceId,
        relay = self._relay,
        ip = rec.ip,
        product = rec.product,
        value = self._value,
        online = rec.online,
        lastUpdate = rec.lastUpdate,
        lastError = rec.lastError
    }
end

-- Interfejs wymagany przez expose()

function BleBoxSwitch:get(feature)
    return self._value
end

function BleBoxSwitch:set(feature, value)
    if toState(value) == 1 then
        self:on()
    else
        self:off()
    end
end

function BleBoxSwitch:switchOn()
    self:on()
end

function BleBoxSwitch:switchOff()
    self:off()
end

-- Zdarzenia

function BleBoxSwitch:on_event(event, callback)
    if not self._eventHandlers[event] then
        self._eventHandlers[event] = {}
    end
    local handlers = self._eventHandlers[event]
    table.insert(handlers, callback)
    -- expose() zachowuje te funkcje i wola ja przy unexpose()
    return function()
        for i, cb in ipairs(handlers) do
            if cb == callback then
                table.remove(handlers, i)
                return
            end
        end
    end
end

function BleBoxSwitch:emit(event, ...)
    local handlers = self._eventHandlers[event]
    if handlers then
        for i, cb in ipairs(handlers) do
            _pcall(cb, ...)
        end
    end
end

-- callback(newVal, oldVal); przy pierwszym odczycie oldVal = nil
function BleBoxSwitch:onChange(callback)
    return self:on_event("OnChange", callback)
end

--------------------------------------------------------------------------------
-- PLUGIN FACTORY
--------------------------------------------------------------------------------

plugin:onInit(function(config)
    knownIps = decodeIps(plugin:kvGet("ips", ""))
    plugin:log("info", "BleBox factory ready")
end)

plugin:onCleanup(function()
    for key, rec in pairs(records) do
        stopPolling(rec)
    end
    records = {}
    scanning = {}
    plugin:log("info", "BleBox cleanup")
end)

--- Tworzy obiekt przelacznika (jeden przekaznik urzadzenia BleBox)
-- @param options table { deviceId, relay, name, id, ip, subnet, polling, pollInterval }
--   deviceId  - Identyfikator urzadzenia z aplikacji BleBox (zalecane; adres IP nie jest wtedy potrzebny)
--   relay     - numer przekaznika, domyslnie 0 (switchBoxD ma 0 i 1)
--   name      - nazwa wyswietlana
--   id        - staly identyfikator dla expose() (domyslnie blebox_<deviceId>_<relay>)
--   ip        - opcjonalna podpowiedz adresu; bez deviceId urzadzenie nie przetrwa zmiany IP
--   subnet    - podsiec do skanowania (3 pierwsze oktety), domyslnie ustawiona przez setSubnet()
--   polling, pollInterval - odpytywanie stanu (domyslnie wlaczone, co 2 s)
function plugin:create(options)
    if type(options) == "string" then
        options = { deviceId = options }
    end
    options = options or {}

    local deviceId = options.deviceId
    if deviceId then deviceId = string.lower(tostring(deviceId)) end
    local ip = options.ip

    if not deviceId and not ip then
        error("blebox: create() wymaga deviceId (lub ip)")
    end

    local key = deviceId or ("ip:" .. ip)
    local rec = records[key]
    if not rec then
        rec = newRecord(key, deviceId, ip or (deviceId and knownIps[deviceId]), options.subnet)
        rec.polling = options.polling ~= false
        rec.pollInterval = options.pollInterval or 2
        records[key] = rec
        startPolling(rec)
    end

    local sw = BleBoxSwitch:new(rec, options)
    plugin:log("info", "Created: " .. sw._name .. " (" .. label(rec) .. " #" .. sw._relay .. ")")
    return sw
end

--- Ustawia domyslna podsiec skanowania (3 pierwsze oktety), np. "192.168.0"
function plugin:setSubnet(subnet)
    if type(subnet) ~= "string" or not string.match(subnet, "^%d+%.%d+%.%d+$") then
        plugin:log("error", "setSubnet: oczekiwany format 192.168.1")
        return false
    end
    defaultSubnet = subnet
    return true
end

--- Reczny skan podsieci (loguje znalezione urzadzenia)
function plugin:scan(subnet)
    local s = subnet or defaultSubnet
    lastScan[s] = nil
    scanSubnet(s, "reczny")
end

--- Urzadzenia znane pluginowi
function plugin:getDevices()
    local out = {}
    for key, rec in pairs(records) do
        out[#out + 1] = {
            key = key,
            deviceId = rec.deviceId,
            ip = rec.ip,
            online = rec.online,
            product = rec.product,
            relays = rec.count,
            lastUpdate = rec.lastUpdate,
            lastError = rec.lastError
        }
    end
    return out
end

--- Urzadzenia znalezione skanem (id -> { id, ip, product })
function plugin:getDiscovered()
    return discovered
end

return plugin
