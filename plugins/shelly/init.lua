--[[
    Shelly plugin dla vCLU (v0.1.0)

    Fabryka obiektow dla urzadzen Shelly Gen2 / Gen3 / Gen4 (API RPC) po lokalnym HTTP,
    z przekaznikiem (komponent "switch") i pomiarem mocy. Tak jak @vonxavier/blebox: plugin nie ma
    wlasnej konfiguracji, urzadzenia konfiguruje sie w kodzie przez create().

    Uzycie:
        local sh = Plugin.getPlugin("@vonxavier/shelly")

        -- jeden kanal (Plug, Plus 1/1PM) albo wybrany kanal wieloprzekaznikowego Shelly (channel = 0, 1, ...)
        local gniazdo = sh:create({ deviceId = "907069747f40", channel = 0, name = "Gniazdo" })

        gniazdo:on()
        gniazdo:off()
        gniazdo:toggle()
        gniazdo:onChange(function(new, old) print(new) end)
        gniazdo:onMeasure(function(m) print(m.power, m.voltage) end)

        print(gniazdo:getPower(), gniazdo:getEnergy())   -- W, Wh

        expose(gniazdo, "switch", { name = "Gniazdo" })

    deviceId = "ID urzadzenia" z aplikacji Shelly (np. 907069747f40) albo pelny id z /shelly
    (shellyplugmg3-907069747f40). Adres IP nie jest potrzebny: plugin znajduje urzadzenie po id
    i sam sledzi zmiane adresu (DHCP).

    transport: v0.1 obsluguje tylko "http" (domyslnie). MQTT jest zaplanowany jako drugi transport.
    Wymagania v0.1: Shelly Gen2 lub nowszy, bez hasla (auth_en = false).
]]

local plugin = Plugin:new("shelly", {
    name = "Shelly",
    version = "0.1.0",
    description = "Factory for Shelly Gen2+ switch objects (local HTTP RPC)"
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
local records = {}       -- key -> rekord urzadzenia (wspolny dla wszystkich kanalow urzadzenia)
local knownIps = {}      -- deviceId -> ostatni adres IP (zapisywane w KV)
local discovered = {}    -- deviceId -> { id, ip, product } (znalezione skanem)
local scanning = {}      -- podsiec -> true gdy trwa skan
local lastScan = {}      -- podsiec -> os.time() ostatniego skanu

-- pola pomiarowe sprawdzane przy wykrywaniu zmiany (zdarzenie OnMeasure)
local MEASURE_FIELDS = { "power", "voltage", "current", "freq", "energy", "temperature" }

--------------------------------------------------------------------------------
-- HELPERS
--------------------------------------------------------------------------------

local function call(cb, ...)
    if cb then _pcall(cb, ...) end
end

local function sanitize(s)
    return (string.gsub(tostring(s), "[^%w_]", "_"))
end

-- "shellyplugmg3-907069747F40" / "907069747f40" -> "907069747f40" (koncowy ciag hex = MAC)
local function normalizeId(s)
    if s == nil then return nil end
    return string.match(string.lower(tostring(s)), "(%x+)$")
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

-- Sprawdza, czy pod adresem jest Shelly Gen2+ (GET /shelly). cb(d) albo cb(nil)
local function probe(ip, cb)
    getJson(ip, "/shelly", PROBE_TIMEOUT, function(json)
        local gen = json and tonumber(json.gen)
        if type(json) ~= "table" or not json.id or not json.mac or not gen or gen < 2 then
            cb(nil)
            return
        end
        cb({
            id = normalizeId(json.mac),
            fullId = json.id,
            gen = gen,
            app = json.app,
            model = json.model,
            fw = json.ver,
            auth = json.auth_en == true
        })
    end)
end

--------------------------------------------------------------------------------
-- DEVICE RECORD (jedno urzadzenie Shelly, wspolne dla jego kanalow)
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
        app = nil,
        gen = nil,
        auth = false,
        authWarned = false,
        count = 0,
        state = {},      -- kanal -> ostatnie pomiary { output, power, ... }
        switches = {},   -- kanal -> lista obiektow ShellySwitch
        pending = {},    -- kanal -> true, gdy trwa komenda
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
        plugin:log("info", "Shelly " .. label(rec) .. " online @ " .. tostring(rec.ip))
    else
        plugin:log("warn", "Shelly " .. label(rec) .. " offline")
    end
end

local function numOrNil(v)
    return tonumber(v)
end

-- Przetwarza odpowiedz Shelly.GetStatus: kluczami sa komponenty "switch:0", "switch:1", ...
-- force = true: odpowiedz na wlasna komende; false: polling (pomija kanaly z trwajaca komenda)
local function applyStatus(rec, status, force)
    local n = 0
    for key, comp in pairs(status) do
        local idx = string.match(key, "^switch:(%d+)$")
        if idx and type(comp) == "table" then
            idx = tonumber(idx)
            n = n + 1
            if force or not rec.pending[idx] then
                local m = {
                    output = (comp.output == true) and 1 or 0,
                    power = numOrNil(comp.apower),
                    voltage = numOrNil(comp.voltage),
                    current = numOrNil(comp.current),
                    freq = numOrNil(comp.freq),
                    energy = (type(comp.aenergy) == "table") and numOrNil(comp.aenergy.total) or nil,
                    temperature = (type(comp.temperature) == "table") and numOrNil(comp.temperature.tC) or nil
                }
                rec.state[idx] = m
                local group = rec.switches[idx]
                if group then
                    for i, sw in ipairs(group) do
                        sw:_apply(m)
                    end
                end
            end
        end
    end
    if n ~= rec.count then
        rec.count = n
        if n == 0 then
            plugin:log("warn", "Shelly " .. label(rec) .. ": brak komponentow switch w statusie")
        end
    end
    rec.lastUpdate = os.time()
end

-- Odczyt stanu urzadzenia (jedno wywolanie dla wszystkich kanalow). cb(ok, err).
-- early() jest wolane od razu po odpowiedzi HTTP, przed przetwarzaniem (poller: done()).
local function readState(rec, cb, early)
    getJson(rec.ip, "/rpc/Shelly.GetStatus", HTTP_TIMEOUT, function(json, err)
        if early then early() end
        if not json then
            cb(false, err or "brak statusu")
            return
        end
        rec.fails = 0
        setOnline(rec, true)
        applyStatus(rec, json, false)
        cb(true)
    end)
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

local function warnAuth(rec)
    if not rec.authWarned then
        rec.authWarned = true
        plugin:log("error", "Shelly " .. label(rec)
            .. ": urzadzenie ma wlaczone haslo (auth), v0.1 go nie obsluguje - wylacz haslo w Shelly")
    end
end

--------------------------------------------------------------------------------
-- DISCOVERY (skan podsieci tylko wtedy, gdy trzeba kogos znalezc)
--------------------------------------------------------------------------------

local function adopt(rec, ip, d)
    rec.ip = ip
    rec.fails = 0
    rec.lastVerify = os.time()
    rec.product = d.model
    rec.app = d.app
    rec.gen = d.gen
    rec.auth = d.auth
    if d.auth then warnAuth(rec) end
    -- stan od razu, bez czekania na kolejny tik
    readState(rec, function(ok, err)
        if not ok then markFail(rec, err) end
    end)
end

local function onFound(d, ip)
    rememberIp(d.id, ip)
    if not discovered[d.id] then
        discovered[d.id] = { id = d.id, ip = ip, product = d.model, app = d.app }
        plugin:log("info", "Znaleziono Shelly " .. d.id .. " (" .. tostring(d.app) .. ", " .. tostring(d.model)
            .. ") @ " .. ip .. ", uzyj: create({ deviceId = \"" .. d.id .. "\", channel = 0 })")
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
        readState(rec, function(ok, err)
            if not ok then markFail(rec, err) end
        end, done)
    end

    if os.time() - rec.lastVerify >= VERIFY_EVERY then
        -- czy pod tym adresem nadal jest to samo urzadzenie (DHCP mogl przydzielic adres innemu)
        probe(rec.ip, function(d)
            if d and (not rec.deviceId or d.id == rec.deviceId) then
                rec.deviceId = rec.deviceId or d.id
                rec.product = d.model
                rec.app = d.app
                rec.gen = d.gen
                rec.auth = d.auth
                rec.lastVerify = os.time()
                rememberIp(d.id, rec.ip)
                if d.auth then warnAuth(rec) end
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
            plugin:log("warn", "Shelly " .. label(rec) .. ": poll - " .. tostring(err))
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

local function sendSwitch(rec, channel, want, cb)
    if not rec.ip then
        call(cb, false, "adres urzadzenia nieznany")
        return
    end
    rec.pending[channel] = true

    plugin:httpRequest({
        url = "http://" .. rec.ip .. "/rpc/Switch.Set?id=" .. channel
            .. "&on=" .. (want == 1 and "true" or "false"),
        method = "GET",
        timeout = HTTP_TIMEOUT,
        parseJson = "success"
    }, function(resp)
        rec.pending[channel] = nil
        if resp.err or not resp.ok then
            local err = resp.err or ("HTTP " .. tostring(resp.status))
            plugin:log("warn", "Shelly " .. label(rec) .. " #" .. channel .. ": komenda nieudana (" .. tostring(err) .. ")")
            markFail(rec, err)
            call(cb, false, err)
            return
        end
        rec.fails = 0
        setOnline(rec, true)
        -- Switch.Set zwraca tylko was_on, wiec stan pobieramy od razu (nie czekamy na tik pollera)
        readState(rec, function(ok, err)
            if not ok then markFail(rec, err) end
        end)
        call(cb, true)
    end)
end

--------------------------------------------------------------------------------
-- SWITCH OBJECT (jeden kanal)
--------------------------------------------------------------------------------

-- Tablica metod kopiowana do kazdej instancji (sandbox nie ma setmetatable).
local ShellySwitch = {}

function ShellySwitch:new(rec, options)
    local channel = tonumber(options.channel) or 0
    local ident = rec.deviceId and rec.deviceId or sanitize(rec.ip or rec.key)
    local obj = {
        _type = "switch",
        _rec = rec,
        _channel = channel,
        _id = options.id or ("shelly_" .. ident .. "_" .. channel),
        _name = options.name or ("Shelly " .. ident .. " #" .. channel),
        _value = 0,
        _m = nil,
        _known = false,
        _eventHandlers = {}
    }
    for name, fn in pairs(ShellySwitch) do obj[name] = fn end

    if not rec.switches[channel] then rec.switches[channel] = {} end
    table.insert(rec.switches[channel], obj)
    return obj
end

local function measureChanged(a, b)
    if a == nil or b == nil then return true end
    for i, f in ipairs(MEASURE_FIELDS) do
        if a[f] ~= b[f] then return true end
    end
    return false
end

-- wywolywane przez plugin przy odczycie stanu z urzadzenia
function ShellySwitch:_apply(m)
    local old = self._value
    local oldM = self._m
    local first = not self._known
    self._known = true
    self._value = m.output
    self._m = m
    if first then
        self:emit("OnChange", m.output, nil)    -- pierwszy odczyt: old = nil
    elseif m.output ~= old then
        self:emit("OnChange", m.output, old)
    end
    if first or measureChanged(m, oldM) then
        self:emit("OnMeasure", m)
    end
end

-- Sterowanie (cb opcjonalny: cb(ok, err))

function ShellySwitch:on(cb)
    sendSwitch(self._rec, self._channel, 1, cb)
end

function ShellySwitch:off(cb)
    sendSwitch(self._rec, self._channel, 0, cb)
end

function ShellySwitch:toggle(cb)
    sendSwitch(self._rec, self._channel, self._value == 1 and 0 or 1, cb)
end

function ShellySwitch:refresh()
    local rec = self._rec
    if not rec.ip then return end
    readState(rec, function(ok) end)
end

-- Konfiguracja (fluent)

function ShellySwitch:setId(id)
    self._id = id
    return self
end

function ShellySwitch:setName(name)
    self._name = name
    return self
end

function ShellySwitch:setIp(ip)
    self._rec.ip = ip
    self._rec.lastVerify = 0
    return self
end

-- polling dotyczy calego urzadzenia (wszystkich jego kanalow)
function ShellySwitch:setPolling(enabled, intervalSec)
    local rec = self._rec
    rec.polling = enabled
    if intervalSec then rec.pollInterval = intervalSec end
    stopPolling(rec)
    if enabled then startPolling(rec) end
    return self
end

-- Stan i pomiary (nil, dopoki urzadzenie nie odpowie albo nie ma danego pomiaru)

function ShellySwitch:getId() return self._id end
function ShellySwitch:getDeviceId() return self._rec.deviceId end
function ShellySwitch:getChannel() return self._channel end
function ShellySwitch:isOn() return self._value == 1 end
function ShellySwitch:isOnline() return self._rec.online end
function ShellySwitch:getValue() return self._value end
function ShellySwitch:getPower() return self._m and self._m.power end            -- W
function ShellySwitch:getVoltage() return self._m and self._m.voltage end        -- V
function ShellySwitch:getCurrent() return self._m and self._m.current end        -- A
function ShellySwitch:getFrequency() return self._m and self._m.freq end         -- Hz
function ShellySwitch:getEnergy() return self._m and self._m.energy end          -- Wh (licznik calkowity)
function ShellySwitch:getTemperature() return self._m and self._m.temperature end -- C

function ShellySwitch:getState()
    local rec = self._rec
    local m = self._m or {}
    return {
        id = self._id,
        name = self._name,
        deviceId = rec.deviceId,
        channel = self._channel,
        ip = rec.ip,
        product = rec.product,
        value = self._value,
        power = m.power,
        voltage = m.voltage,
        current = m.current,
        freq = m.freq,
        energy = m.energy,
        temperature = m.temperature,
        online = rec.online,
        lastUpdate = rec.lastUpdate,
        lastError = rec.lastError
    }
end

-- Interfejs wymagany przez expose(). Pomiary dostepne pod nazwa cechy.

function ShellySwitch:get(feature)
    if feature == "power" then return self:getPower() or 0 end
    if feature == "voltage" then return self:getVoltage() or 0 end
    if feature == "current" then return self:getCurrent() or 0 end
    if feature == "energy" then return self:getEnergy() or 0 end
    if feature == "temperature" then return self:getTemperature() or 0 end
    return self._value
end

function ShellySwitch:set(feature, value)
    if value == true or value == 1 or value == "1" or value == "on" or value == "ON" then
        self:on()
    else
        self:off()
    end
end

function ShellySwitch:switchOn()
    self:on()
end

function ShellySwitch:switchOff()
    self:off()
end

-- Zdarzenia

function ShellySwitch:on_event(event, callback)
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

function ShellySwitch:emit(event, ...)
    local handlers = self._eventHandlers[event]
    if handlers then
        for i, cb in ipairs(handlers) do
            _pcall(cb, ...)
        end
    end
end

-- callback(newVal, oldVal): zmiana stanu 0/1; przy pierwszym odczycie oldVal = nil
function ShellySwitch:onChange(callback)
    return self:on_event("OnChange", callback)
end

-- callback(m): zmiana pomiarow, m = { output, power, voltage, current, freq, energy, temperature }
function ShellySwitch:onMeasure(callback)
    return self:on_event("OnMeasure", callback)
end

--------------------------------------------------------------------------------
-- PLUGIN FACTORY
--------------------------------------------------------------------------------

plugin:onInit(function(config)
    knownIps = decodeIps(plugin:kvGet("ips", ""))
    plugin:log("info", "Shelly factory ready")
end)

plugin:onCleanup(function()
    for key, rec in pairs(records) do
        stopPolling(rec)
    end
    records = {}
    scanning = {}
    plugin:log("info", "Shelly cleanup")
end)

--- Tworzy obiekt przelacznika (jeden kanal urzadzenia Shelly Gen2+)
-- @param options table { deviceId, channel, name, id, ip, subnet, polling, pollInterval, transport }
--   deviceId  - ID urzadzenia z aplikacji Shelly albo pelny id z /shelly (zalecane; IP nie jest wtedy potrzebny)
--   channel   - numer kanalu (komponent switch:N), domyslnie 0
--   name      - nazwa wyswietlana
--   id        - staly identyfikator dla expose() (domyslnie shelly_<deviceId>_<channel>)
--   ip        - opcjonalna podpowiedz adresu; bez deviceId urzadzenie nie przetrwa zmiany IP
--   subnet    - podsiec do skanowania (3 pierwsze oktety), domyslnie ustawiona przez setSubnet()
--   polling, pollInterval - odpytywanie stanu (domyslnie wlaczone, co 2 s)
--   transport - "http" (domyslnie); MQTT dojdzie w kolejnej wersji
function plugin:create(options)
    if type(options) == "string" then
        options = { deviceId = options }
    end
    options = options or {}

    local transport = options.transport or "http"
    if transport ~= "http" then
        error("shelly: transport \"" .. tostring(transport) .. "\" nieobslugiwany w v0.1 (dostepny tylko http)")
    end

    local deviceId = normalizeId(options.deviceId)
    local ip = options.ip

    if not deviceId and not ip then
        error("shelly: create() wymaga deviceId (lub ip)")
    end

    local key = deviceId or ("ip:" .. ip)
    local rec = records[key]
    if not rec then
        rec = newRecord(key, deviceId, ip or (deviceId and knownIps[deviceId]), options.subnet)
        rec.polling = options.polling ~= false
        rec.pollInterval = tonumber(options.pollInterval) or 2
        records[key] = rec
        startPolling(rec)
    end

    local sw = ShellySwitch:new(rec, options)
    plugin:log("info", "Created: " .. sw._name .. " (" .. label(rec) .. " #" .. sw._channel .. ")")
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
            app = rec.app,
            gen = rec.gen,
            channels = rec.count,
            lastUpdate = rec.lastUpdate,
            lastError = rec.lastError
        }
    end
    return out
end

--- Urzadzenia znalezione skanem (id -> { id, ip, product, app })
function plugin:getDiscovered()
    return discovered
end

return plugin
