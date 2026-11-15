--[[
    InPost Plugin dla vCLU

    Fabryka obiektów śledzących paczki InPost przez publiczne API śledzenia
    (ShipX, bez logowania i bez klucza). Plugin tylko pilnuje paczek i wywołuje
    zdarzenia. Co z nimi zrobić (panel Grentona, alarm, push), decyduje Twój moduł.

    Użycie:
        local inpost = Plugin.getPlugin("@vonxavier/inpost")

        local paczki = inpost:create({
            id = "paczki",
            numbers = { "520000000000000000000000" },
        })

        -- Wtyczka niczego nie ustawia sama (nie zmienia obiektów vCLU).
        -- Wskaźnik robisz w swoim module:
        local czeka = VirtualNumber:new("paczki_czeka")
        local function odswiez() czeka:setValue(paczki:readyCount()) end
        paczki:on("ready", odswiez)
        paczki:on("delivered", odswiez)
        odswiez()   -- stan z KV jest od razu po create(), przed on()

        paczki:track("520000000000000000000001")   -- kolejną dodasz w locie
]]

--------------------------------------------------------------------------------
-- PLUGIN REGISTRATION
--------------------------------------------------------------------------------

local plugin = Plugin:new("inpost", {
    name = "InPost Paczki",
    version = "0.1.0",
    description = "Factory for InPost parcel tracking"
})

local API = "https://api-shipx-pl.easypack24.net/v1/tracking/"

local EVENTS = { new = true, status = true, ready = true, delivered = true }

-- Statusy końcowe: po nich paczka przestaje być śledzona.
local FINAL = { delivered = true, returned_to_sender = true, canceled = true }

local LABELS = {
    created = "Etykieta utworzona",
    offers_prepared = "Oferta przygotowana",
    confirmed = "Paczka potwierdzona",
    dispatched_by_sender = "Nadawca wysłał paczkę",
    collected_from_sender = "Odebrana od nadawcy",
    taken_by_courier = "Odebrana przez kuriera",
    adopted_at_source_branch = "Przyjęta w oddziale",
    sent_from_source_branch = "Wysłana z oddziału",
    adopted_at_sorting_center = "W sortowni",
    sent_from_sorting_center = "Wyjechała z sortowni",
    out_for_delivery = "W doręczeniu",
    ready_to_pickup = "Gotowa do odbioru",
    pickup_reminder_sent = "Przypomnienie o odbiorze",
    delivered = "Doręczona",
    avizo = "Awizo",
    returned_to_sender = "Zwrot do nadawcy",
    canceled = "Anulowana"
}

--------------------------------------------------------------------------------
-- GMAIL HELPERS
--------------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_INDEX = {}
for i = 1, #B64 do B64_INDEX[B64:sub(i, i)] = i - 1 end

-- Gmail gives bodies as base64url. Plain arithmetic, no bit operators, so it
-- runs on any Lua the runtime embeds.
local function b64urlDecode(data)
    data = tostring(data or ""):gsub("-", "+"):gsub("_", "/"):gsub("[^%w%+/]", "")
    local out, i = {}, 1
    while i <= #data do
        local chunk = data:sub(i, i + 3)
        local n, count = 0, #chunk
        for j = 1, 4 do
            n = n * 64 + (B64_INDEX[chunk:sub(j, j)] or 0)
        end
        local b1 = math.floor(n / 65536)
        local b2 = math.floor(n / 256) % 256
        local b3 = n % 256
        if count >= 2 then out[#out + 1] = string.char(b1) end
        if count >= 3 then out[#out + 1] = string.char(b2) end
        if count >= 4 then out[#out + 1] = string.char(b3) end
        i = i + 4
    end
    return table.concat(out)
end

-- All text of a Gmail message: the snippet plus every text part of the body.
local function messageText(msg)
    local parts = { tostring(msg.snippet or "") }
    local function walk(node)
        if type(node) ~= "table" then return end
        local body = node.body
        if type(body) == "table" and body.data then
            parts[#parts + 1] = b64urlDecode(body.data)
        end
        if type(node.parts) == "table" then
            for _, child in ipairs(node.parts) do walk(child) end
        end
    end
    walk(msg.payload)
    return table.concat(parts, "\n")
end

-- InPost tracking numbers are 24 digits.
local function findNumbers(text)
    local found, seen = {}, {}
    for run in tostring(text):gmatch("%d+") do
        if #run == 24 and not seen[run] then
            seen[run] = true
            found[#found + 1] = run
        end
    end
    return found
end

--------------------------------------------------------------------------------
-- PARCELS OBJECT
--------------------------------------------------------------------------------

-- Method table copied onto each instance. The plugin sandbox exposes no
-- setmetatable, so inheritance through __index is not available here.
local Parcels = {}

local function cleanNumber(n)
    if n == nil then return nil end
    n = tostring(n):gsub("%s", "")
    if n == "" then return nil end
    return n
end

function Parcels:new(options)
    local obj = {
        _id = options.id or "inpost",
        _interval = options.interval or 600,
        _parcels = {},     -- numer -> { status, machine }
        _order = {},       -- numery w kolejności dodania
        _handlers = { new = {}, status = {}, ready = {}, delivered = {} },
        _lastError = nil,
        _poller = nil,
        _mail = options.gmail,
        _mailPoller = nil,
        _mailSeen = {},    -- id maila -> true
        _mailSeenOrder = {},
        _tokenValue = nil,
        _tokenExp = 0,
        _lastMailError = nil,
        _sensorReady = nil,
        _sensorActive = nil
    }
    for name, fn in pairs(Parcels) do obj[name] = fn end

    obj:_restore()
    obj:_restoreSeen()
    for _, n in ipairs(options.numbers or {}) do obj:track(n) end

    obj._sensorReady = plugin:sensor(obj._id .. "_ready", function() return obj:readyCount() end)
    obj._sensorActive = plugin:sensor(obj._id .. "_active", function() return obj:count() end)

    if options.polling ~= false then
        obj:_start()
        if obj._mail then obj:_startMail() end
    end

    -- Numer można też podać z zewnątrz przez MQTT (wbudowany broker vCLU).
    plugin:mqttSubscribe("vclu/inpost/" .. obj._id .. "/add", function(topic, payload)
        obj:track(payload)
    end)
    return obj
end

--------------------------------------------------------------------------------
-- STORE
--------------------------------------------------------------------------------

-- Numery i ostatnie statusy leżą w KV wtyczki, żeby po restarcie nie ogłaszać
-- drugi raz tego, co już było.
function Parcels:_save()
    local data = {}
    for _, n in ipairs(self._order) do
        local p = self._parcels[n]
        data[#data + 1] = { number = n, status = p.status, machine = p.machine }
    end
    plugin:kvSet("parcels:" .. self._id, data)
end

function Parcels:_restore()
    local data = plugin:kvGet("parcels:" .. self._id, {})
    for _, row in ipairs(data) do
        if row.number and not self._parcels[row.number] then
            self._parcels[row.number] = { status = row.status, machine = row.machine }
            self._order[#self._order + 1] = row.number
        end
    end
end

--------------------------------------------------------------------------------
-- EVENTS
--------------------------------------------------------------------------------

function Parcels:_fire(event, ...)
    for _, fn in ipairs(self._handlers[event]) do
        local ok, err = pcall(fn, ...)
        if not ok then
            plugin:log("error", "InPost handler '" .. event .. "': " .. tostring(err))
        end
    end
end

local function snapshot(number, p)
    return {
        number = number,
        status = p.status,
        label = LABELS[p.status] or p.status,
        machine = p.machine
    }
end

--- Calls fn on an event; returns a function that removes it.
-- new(parcel): a tracked parcel got its first status; status(parcel, previous):
-- the status changed; ready(parcel): waiting for pickup; delivered(parcel).
-- parcel = { number, status, label, machine }
function Parcels:on(event, fn)
    if not EVENTS[event] then error("inpost: unknown event '" .. tostring(event) .. "'") end
    if type(fn) ~= "function" then error("inpost: on() needs a function") end
    local list = self._handlers[event]
    list[#list + 1] = fn
    return function()
        for i, f in ipairs(list) do
            if f == fn then
                table.remove(list, i)
                return
            end
        end
    end
end

--------------------------------------------------------------------------------
-- TRACKING
--------------------------------------------------------------------------------

--- Start tracking a parcel by its tracking number. Returns false for an empty
-- number or one that is already tracked.
function Parcels:track(number)
    number = cleanNumber(number)
    if not number or self._parcels[number] then return false end
    self._parcels[number] = {}
    self._order[#self._order + 1] = number
    self:_save()
    plugin:log("info", "InPost " .. self._id .. ": tracking " .. number)
    if self._poller then self:_check(number) end
    return true
end

--- Stop tracking a parcel.
function Parcels:untrack(number)
    number = cleanNumber(number)
    if not number or not self._parcels[number] then return false end
    self._parcels[number] = nil
    for i, n in ipairs(self._order) do
        if n == number then
            table.remove(self._order, i)
            break
        end
    end
    self:_save()
    return true
end

-- Applies a fresh status from the API and fires the events it earns.
function Parcels:_apply(number, status, machine)
    local p = self._parcels[number]
    if not p or not status then return end
    local previous = p.status
    p.machine = machine or p.machine
    if previous == status then return end
    p.status = status
    self:_save()

    local parcel = snapshot(number, p)
    if previous == nil then
        self:_fire("new", parcel)
    else
        self:_fire("status", parcel, previous)
    end
    if status == "ready_to_pickup" then self:_fire("ready", parcel) end
    if status == "delivered" then self:_fire("delivered", parcel) end

    for _, sensor in ipairs({ self._sensorReady, self._sensorActive }) do
        if sensor and sensor._notify then sensor:_notify() end
    end

    -- Paczka w statusie końcowym zostaje na liście do następnego odświeżenia,
    -- potem znika, żeby lista nie rosła.
    if FINAL[status] then self._finished = self._finished or {}; self._finished[number] = true end
end

function Parcels:_check(number, done)
    plugin:httpRequest({
        url = API .. number,
        timeout = 10000,
        parseJson = "success"
    }, function(resp)
        if resp.err then
            self._lastError = number .. ": " .. tostring(resp.err)
            plugin:log("warn", "InPost " .. number .. ": " .. tostring(resp.err))
            if done then done(false) end
            return
        end
        local json = resp.json
        if type(json) ~= "table" or not json.status then
            self._lastError = number .. ": no status in response"
            if done then done(false) end
            return
        end
        local attrs = type(json.custom_attributes) == "table" and json.custom_attributes or {}
        self._lastError = nil
        self:_apply(number, json.status, attrs.target_machine_id)
        if done then done(true) end
    end)
end

function Parcels:_checkAll(done)
    -- Statusy końcowe z poprzedniego obiegu usuwamy teraz.
    if self._finished then
        for number in pairs(self._finished) do self:untrack(number) end
        self._finished = nil
    end

    local numbers = {}
    for i, n in ipairs(self._order) do numbers[i] = n end
    local pending, okCount = #numbers, 0
    if pending == 0 then
        if done then done() end
        return
    end
    for _, n in ipairs(numbers) do
        self:_check(n, function(ok)
            if ok then okCount = okCount + 1 end
            pending = pending - 1
            if pending == 0 and done then
                if okCount == 0 then done(nil, self._lastError or "all requests failed") else done() end
            end
        end)
    end
end

function Parcels:_start()
    self._poller = plugin:poller("inpost_" .. self._id, {
        interval = self._interval * 1000,
        immediate = true,
        timeout = 30000,
        retry = { maxAttempts = 2, backoff = 5000 },
        onTick = function(done) self:_checkAll(done) end,
        onError = function(err)
            self._lastError = tostring(err)
            plugin:log("error", "InPost " .. self._id .. ": " .. tostring(err))
        end
    })
    self._poller:start()
end

function Parcels:_stop()
    if self._poller then self._poller:stop() end
    if self._mailPoller then self._mailPoller:stop() end
end

--------------------------------------------------------------------------------
-- GMAIL
--------------------------------------------------------------------------------

function Parcels:_restoreSeen()
    local ids = plugin:kvGet("mailseen:" .. self._id, {})
    for _, id in ipairs(ids) do
        self._mailSeen[id] = true
        self._mailSeenOrder[#self._mailSeenOrder + 1] = id
    end
end

function Parcels:_markSeen(id)
    if self._mailSeen[id] then return end
    self._mailSeen[id] = true
    self._mailSeenOrder[#self._mailSeenOrder + 1] = id
    while #self._mailSeenOrder > 300 do
        local old = table.remove(self._mailSeenOrder, 1)
        self._mailSeen[old] = nil
    end
    plugin:kvSet("mailseen:" .. self._id, self._mailSeenOrder)
end

-- Access token from the refresh token; kept until a minute before it expires.
function Parcels:_mailToken(cb)
    if self._tokenValue and os.time() < self._tokenExp - 60 then
        cb(self._tokenValue)
        return
    end
    local m = self._mail
    plugin:httpRequest({
        url = "https://oauth2.googleapis.com/token",
        method = "POST",
        form = {
            client_id = m.clientId,
            client_secret = m.clientSecret,
            refresh_token = m.refreshToken,
            grant_type = "refresh_token"
        },
        timeout = 10000,
        parseJson = "always"
    }, function(resp)
        local j = resp.json
        if resp.err or type(j) ~= "table" or not j.access_token then
            local why = (type(j) == "table" and (j.error_description or j.error)) or resp.err or "no token"
            cb(nil, "gmail token: " .. tostring(why))
            return
        end
        self._tokenValue = j.access_token
        self._tokenExp = os.time() + (tonumber(j.expires_in) or 3600)
        cb(self._tokenValue)
    end)
end

function Parcels:_gmailGet(path, query, cb)
    self:_mailToken(function(token, err)
        if not token then cb(nil, err) return end
        plugin:httpRequest({
            url = plugin:url("https://gmail.googleapis.com/gmail/v1/users/me/" .. path, query),
            headers = { ["Authorization"] = plugin:bearerAuth(token) },
            timeout = 15000,
            parseJson = "success"
        }, function(resp)
            if resp.err then
                if resp.status == 401 then self._tokenValue = nil end
                cb(nil, "gmail " .. path .. ": " .. tostring(resp.err))
                return
            end
            cb(resp.json or {})
        end)
    end)
end

-- Looks for new InPost mails and starts tracking the numbers in them.
function Parcels:_mailCheck(done)
    local m = self._mail
    local query = m.query or "from:inpost.pl newer_than:3d"
    self:_gmailGet("messages", { q = query, maxResults = 20 }, function(list, err)
        if not list then
            self._lastMailError = err
            plugin:log("error", "InPost " .. self._id .. ": " .. tostring(err))
            if done then done(nil, err) end
            return
        end
        local ids = {}
        for _, row in ipairs(list.messages or {}) do
            if row.id and not self._mailSeen[row.id] then ids[#ids + 1] = row.id end
        end
        local pending = #ids
        if pending == 0 then
            self._lastMailError = nil
            if done then done() end
            return
        end
        for _, id in ipairs(ids) do
            self:_gmailGet("messages/" .. id, { format = "full" }, function(msg, merr)
                if msg then
                    for _, number in ipairs(findNumbers(messageText(msg))) do
                        self:track(number)
                    end
                    self:_markSeen(id)
                else
                    self._lastMailError = merr
                    plugin:log("warn", "InPost: " .. tostring(merr))
                end
                pending = pending - 1
                if pending == 0 and done then done() end
            end)
        end
    end)
end

function Parcels:_startMail()
    local m = self._mail
    self._mailPoller = plugin:poller("inpost_mail_" .. self._id, {
        interval = (m.interval or 300) * 1000,
        immediate = true,
        timeout = 60000,
        retry = { maxAttempts = 2, backoff = 10000 },
        onTick = function(done) self:_mailCheck(done) end,
        onError = function(err)
            self._lastMailError = tostring(err)
        end
    })
    self._mailPoller:start()
end

--------------------------------------------------------------------------------
-- PUBLIC API
--------------------------------------------------------------------------------

--- Number of tracked parcels.
function Parcels:count() return #self._order end

--- Number of parcels waiting for pickup.
function Parcels:readyCount()
    local n = 0
    for _, number in ipairs(self._order) do
        if self._parcels[number].status == "ready_to_pickup" then n = n + 1 end
    end
    return n
end

--- Tracked parcels in the order they were added.
function Parcels:list()
    local out = {}
    for _, number in ipairs(self._order) do
        out[#out + 1] = snapshot(number, self._parcels[number])
    end
    return out
end

--- Sensor with the number of parcels waiting for pickup, for expose().
function Parcels:sensor() return self._sensorReady end

--- Ask InPost again right away.
function Parcels:refresh()
    if self._poller then self._poller:poll() end
end

--- Check Gmail for new InPost mails right away.
function Parcels:refreshMail()
    if self._mailPoller then self._mailPoller:poll() end
end

function Parcels:getId() return self._id end

function Parcels:getState()
    return {
        id = self._id,
        tracked = self:count(),
        ready = self:readyCount(),
        parcels = self:list(),
        lastError = self._lastError,
        mailError = self._lastMailError
    }
end

--------------------------------------------------------------------------------
-- PLUGIN FACTORY
--------------------------------------------------------------------------------

local instances = {}

plugin:onInit(function(config)
    plugin:log("info", "InPost factory ready")
end)

plugin:onCleanup(function()
    for _, p in ipairs(instances) do p:_stop() end
    instances = {}
    plugin:log("info", "InPost cleanup")
end)

--- Create a parcel tracker
-- @param options table { id, numbers, interval, polling, gmail }
-- @return Parcels
function plugin:create(options)
    options = options or {}
    if options.id ~= nil and (type(options.id) ~= "string" or options.id == "") then
        error("inpost:create: id must be a non-empty string")
    end
    if options.interval ~= nil and (type(options.interval) ~= "number" or options.interval < 60) then
        error("inpost:create: interval must be a number of seconds, 60 or more")
    end
    if options.numbers ~= nil and type(options.numbers) ~= "table" then
        error("inpost:create: numbers must be a list")
    end
    if options.gmail ~= nil then
        local g = options.gmail
        if type(g) ~= "table" then error("inpost:create: gmail must be a table") end
        for _, k in ipairs({ "clientId", "clientSecret", "refreshToken" }) do
            if type(g[k]) ~= "string" or g[k] == "" then
                error("inpost:create: gmail." .. k .. " is required")
            end
        end
        if g.interval ~= nil and (type(g.interval) ~= "number" or g.interval < 60) then
            error("inpost:create: gmail.interval must be a number of seconds, 60 or more")
        end
    end
    local id = options.id or "inpost"
    for _, p in ipairs(instances) do
        if p._id == id then
            plugin:log("error", "InPost: duplicate id '" .. id .. "', returning the existing one")
            return p
        end
    end

    local p = Parcels:new(options)
    instances[#instances + 1] = p
    plugin:log("info", "Created: " .. id)
    return p
end

function plugin:getInstances()
    return instances
end

return plugin
