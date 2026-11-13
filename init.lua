-- BleBox plugin v0.1.1
-- Urzadzenia z API "switchBox" (switchBox, switchBoxD, ...) po lokalnym HTTP.
--  * tozsamosc urzadzenia = "id" z /api/device/state (nie IP)
--  * IP trzymany w KV; po bledach plugin skanuje podsiec i szuka tego samego id
--  * kazdy przekaznik = plugin:control (expose -> dashboard/HomeKit/HA)
--  * opcjonalny most: przekaznik <-> wolny DOUT z modulu wirtualnego (widoczny w OM)

local plugin = Plugin:new("blebox", {
    name = "BleBox",
    version = "0.1.1",
    description = "BleBox switchBox API: lokalne HTTP, wykrywanie po id, most do DOUT"
})

local MAX_FAILS = 3

local cfg = {}
local state = { ready = false, lastUpdate = 0, lastError = nil }

local devices = {}    -- id -> {id, ip, name, product, apiLevel, online, fails, count, relays = {[0]=0|1}}
local knownIps = {}   -- id -> ip (zapisywane w KV)
local controls = {}   -- nazwa kontrolki -> true
local bindings = {}   -- "id:relay" -> sciezka DOUT w rejestrze
local bound = {}      -- "id:relay" -> true (callback onChange juz podpiety)
local pending = {}    -- "id:relay" -> true gdy trwa komenda (ignorujemy polling dla tego przekaznika)

local poller = nil
local scanning = false
local lastScan = 0

local sendRelay -- forward declaration

-- ---------------------------------------------------------------- helpers

local function urlFor(ip, path)
    return "http://" .. ip .. path
end

local function toState(v)
    if v == true or v == 1 or v == "1" or v == "on" or v == "ON" then
        return 1
    end
    return 0
end

local function ctlName(id, relay)
    return "relay_" .. id .. "_" .. relay
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

local function countDevices()
    local n = 0
    for k, dev in pairs(devices) do n = n + 1 end
    return n
end

local function publishStatus()
    local online = 0
    for k, dev in pairs(devices) do
        if dev.online then online = online + 1 end
    end
    plugin:upsertObject("status", {
        ready = state.ready,
        devices = countDevices(),
        online = online,
        scanning = scanning,
        lastScan = lastScan,
        lastError = state.lastError or ""
    })
end

local function publishDevice(dev)
    local obj = {
        id = dev.id,
        ip = dev.ip,
        product = dev.product or "",
        online = dev.online,
        relays = dev.count
    }
    for i = 0, dev.count - 1 do
        obj["relay" .. i] = dev.relays[i] or 0
    end
    plugin:upsertObject("dev_" .. dev.id, obj)
end

-- ---------------------------------------------------------------- bridge (DOUT)

local function boundObject(key)
    local path = bindings[key]
    if not path then return nil end
    return _:get(path)
end

local function mirrorToDout(dev, idx, st)
    if not cfg.enableBridge then return end
    local obj = boundObject(dev.id .. ":" .. idx)
    if obj and obj.getValue and obj.setValue then
        if obj:getValue() ~= st then
            obj:setValue(st)
        end
    end
end

local function tryBind(dev, idx)
    if not cfg.enableBridge then return end
    local key = dev.id .. ":" .. idx
    if bound[key] or not bindings[key] then return end

    local obj = boundObject(key)
    if not obj or not obj.onChange then return end -- DOUT jeszcze niedostepny, sprobujemy przy kolejnym pollu

    bound[key] = true
    obj:onChange(function(newValue, oldValue)
        local want = toState(newValue)
        local d = devices[dev.id]
        if d and d.relays[idx] ~= want then
            sendRelay(dev.id, idx, want)
        end
    end)
    mirrorToDout(dev, idx, dev.relays[idx] or 0)
    plugin:log("info", "Most: " .. key .. " <-> " .. bindings[key])
end

-- ---------------------------------------------------------------- state

local function applyRelays(dev, list, force)
    for k, r in ipairs(list) do
        local idx = tonumber(r.relay)
        if idx ~= nil then
            local key = dev.id .. ":" .. idx
            if force or not pending[key] then
                local st = toState(r.state)
                local changed = (dev.relays[idx] ~= st)
                dev.relays[idx] = st
                if changed then
                    state.lastUpdate = os.time()
                    local c = plugin:get(ctlName(dev.id, idx))
                    if c then c:notify() end
                    plugin:emit("blebox:changed", { id = dev.id, relay = idx, state = st })
                end
                mirrorToDout(dev, idx, st)
            end
        end
    end
    publishDevice(dev)
end

local function ensureControls(dev)
    for i = 0, dev.count - 1 do
        local name = ctlName(dev.id, i)
        if not controls[name] then
            controls[name] = true
            plugin:control(name,
                function()
                    local d = devices[dev.id]
                    if d and d.relays[i] then return d.relays[i] end
                    return 0
                end,
                function(v)
                    sendRelay(dev.id, i, toState(v))
                end
            )
        end
    end
end

-- ---------------------------------------------------------------- discovery

local function probe(ip, cb)
    plugin:httpRequest({
        url = urlFor(ip, "/api/device/state"),
        method = "GET",
        timeout = cfg.probeTimeout,
        parseJson = "success"
    }, function(resp)
        if resp.err or not resp.ok or type(resp.json) ~= "table" then
            cb(nil)
            return
        end
        local d = resp.json.device
        if type(d) ~= "table" or d.type ~= "switchBox" or not d.id then
            cb(nil)
            return
        end
        cb(d)
    end)
end

local function register(d, ip, done)
    local id = d.id
    local existing = devices[id]
    if existing and existing.online and existing.ip == ip then
        done()
        return
    end

    plugin:httpRequest({
        url = urlFor(ip, "/api/relay/state"),
        method = "GET",
        timeout = cfg.timeout,
        parseJson = "success"
    }, function(resp)
        if resp.err or not resp.ok or type(resp.json) ~= "table" or type(resp.json.relays) ~= "table" then
            plugin:log("warn", "BleBox " .. id .. " (" .. ip .. "): brak stanu przekaznikow")
            done()
            return
        end

        local list = resp.json.relays
        local dev = devices[id]
        if not dev then
            dev = { id = id, relays = {}, fails = 0 }
            devices[id] = dev
        end
        local oldIp = dev.ip
        dev.ip = ip
        dev.name = d.deviceName
        dev.product = d.product
        dev.apiLevel = d.apiLevel
        dev.count = #list
        dev.online = true
        dev.fails = 0

        knownIps[id] = ip
        plugin:kvSet("ips", encodeIps(knownIps))

        ensureControls(dev)
        applyRelays(dev, list, true)
        for i = 0, dev.count - 1 do tryBind(dev, i) end

        if oldIp and oldIp ~= ip then
            plugin:log("info", "BleBox " .. id .. ": nowy adres " .. oldIp .. " -> " .. ip)
        else
            plugin:log("info", "BleBox " .. id .. " (" .. tostring(d.product) .. ") @ " .. ip .. ", przekazniki: " .. dev.count)
        end
        publishStatus()
        done()
    end)
end

local function candidateList()
    local ips, seen = {}, {}
    local function add(ip)
        if ip and not seen[ip] then
            seen[ip] = true
            ips[#ips + 1] = ip
        end
    end
    for ip in string.gmatch(cfg.hosts or "", "[^,%s]+") do add(ip) end
    for id, ip in pairs(knownIps) do add(ip) end
    for i = cfg.rangeFrom, cfg.rangeTo do add(cfg.subnet .. "." .. i) end
    return ips
end

local function scan(reason)
    if scanning then return end
    local now = os.time()
    if now - lastScan < cfg.rescanCooldown then return end
    scanning = true
    lastScan = now

    local ips = candidateList()
    local idx, running, found = 1, 0, 0
    local pump

    local function finish()
        scanning = false
        plugin:log("info", "Skan (" .. reason .. ") zakonczony, znaleziono: " .. found)
        publishStatus()
    end

    pump = function()
        while scanning and running < cfg.concurrency and idx <= #ips do
            local ip = ips[idx]
            idx = idx + 1
            running = running + 1
            probe(ip, function(d)
                if d then
                    found = found + 1
                    register(d, ip, function()
                        running = running - 1
                        pump()
                    end)
                else
                    running = running - 1
                    pump()
                end
            end)
        end
        if scanning and running == 0 and idx > #ips then
            finish()
        end
    end

    plugin:log("info", "Skan podsieci (" .. reason .. "): " .. #ips .. " adresow")
    publishStatus()
    pump()
end

-- ---------------------------------------------------------------- commands

local function markFail(dev)
    dev.fails = (dev.fails or 0) + 1
    if dev.fails >= MAX_FAILS and dev.online then
        dev.online = false
        state.lastError = "offline: " .. dev.id
        plugin:log("warn", "BleBox " .. dev.id .. " offline (ostatni IP " .. tostring(dev.ip) .. "), szukam ponownie")
        publishDevice(dev)
        publishStatus()
        scan("offline " .. dev.id)
    end
end

sendRelay = function(id, idx, want)
    local dev = devices[id]
    if not dev or not dev.ip then return false end
    local key = id .. ":" .. idx
    pending[key] = true

    plugin:httpRequest({
        url = urlFor(dev.ip, "/api/relay/set"),
        method = "POST",
        json = { relays = { { relay = idx, state = want } } },
        timeout = cfg.timeout,
        parseJson = "success"
    }, function(resp)
        pending[key] = nil
        if resp.err or not resp.ok then
            plugin:log("warn", "BleBox " .. key .. ": komenda nieudana (" .. tostring(resp.err or resp.status) .. ")")
            markFail(dev)
            mirrorToDout(dev, idx, dev.relays[idx] or 0) -- cofnij DOUT do realnego stanu
            return
        end
        dev.fails = 0
        if type(resp.json) == "table" and type(resp.json.relays) == "table" then
            applyRelays(dev, resp.json.relays, true)
        end
    end)
    return true
end

-- ---------------------------------------------------------------- lifecycle

plugin:onInit(function(config)
    cfg.subnet = plugin:coerceString(config.subnet, "192.168.1")
    cfg.rangeFrom = plugin:coerceNumber(config.rangeFrom, 1)
    cfg.rangeTo = plugin:coerceNumber(config.rangeTo, 254)
    cfg.hosts = plugin:coerceString(config.hosts, "")
    cfg.interval = plugin:coerceNumber(config.interval, 2)
    cfg.enableBridge = plugin:coerceBool(config.enableBridge, true)
    cfg.rescanCooldown = plugin:coerceNumber(config.rescanCooldown, 30)
    cfg.concurrency = plugin:coerceNumber(config.scanConcurrency, 10)
    cfg.timeout = 3000
    cfg.probeTimeout = 800

    if not string.match(cfg.subnet, "^%d+%.%d+%.%d+$") then
        state.lastError = "zly format subnet: " .. cfg.subnet
        plugin:log("error", state.lastError .. " (oczekiwane np. 192.168.1)")
        return
    end
    if cfg.interval < 1 then cfg.interval = 1 end
    if cfg.concurrency < 1 then cfg.concurrency = 1 end

    local bstr = plugin:coerceString(config.bindings, "")
    for id, relay, path in string.gmatch(bstr, "(%w+):(%d+)=([^;%s]+)") do
        bindings[id .. ":" .. tonumber(relay)] = path
    end

    knownIps = decodeIps(plugin:kvGet("ips", ""))

    state.ready = true
    publishStatus()

    poller = plugin:poller("poll", {
        interval = cfg.interval * 1000,
        immediate = false,
        initialDelay = 2000,
        onTick = function(done)
            local list, anyOffline = {}, false
            for id, dev in pairs(devices) do
                if dev.online then
                    list[#list + 1] = dev
                else
                    anyOffline = true
                end
            end
            if anyOffline then scan("offline") end

            local left = #list
            if left == 0 then
                done()
                return
            end
            for k, dev in ipairs(list) do
                plugin:httpRequest({
                    url = urlFor(dev.ip, "/api/relay/state"),
                    method = "GET",
                    timeout = cfg.timeout,
                    parseJson = "success"
                }, function(resp)
                    if resp.err or not resp.ok or type(resp.json) ~= "table" or type(resp.json.relays) ~= "table" then
                        markFail(dev)
                    else
                        dev.fails = 0
                        applyRelays(dev, resp.json.relays, false)
                        for i = 0, dev.count - 1 do tryBind(dev, i) end
                    end
                    left = left - 1
                    if left == 0 then done() end
                end)
            end
        end,
        onError = function(err, stats)
            state.lastError = tostring(err)
            plugin:log("error", "Poll: " .. tostring(err))
        end
    })
    poller:start()

    scan("start")
end)

plugin:onCleanup(function()
    plugin:log("info", "BleBox plugin stopped")
end)

-- ---------------------------------------------------------------- public API

function plugin:isReady() return state.ready end
function plugin:getLastError() return state.lastError end
function plugin:getData() return devices end
function plugin:refresh() if poller then poller:poll() end end
function plugin:getStats() if poller then return poller:stats() end end
function plugin:rescan() lastScan = 0; scan("reczny") end

function plugin:getRelay(id, idx)
    local dev = devices[id]
    if dev then return dev.relays[idx] end
    return nil
end

function plugin:setRelay(id, idx, value)
    return sendRelay(id, idx, toState(value))
end

return plugin
