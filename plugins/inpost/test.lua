--- Tests for the inpost plugin.
--
-- Run from the repository root:
--   lua plugins/inpost/test.lua

local here = arg[0]:match("^(.*)[/\\][^/\\]+$") or "."
local harness = dofile(here .. "/../../test/harness.lua")
local check = harness.check

local answers = {}
local requests = {}

local mails = {}      -- id -> message table
local mailCalls = { token = 0, list = 0, get = 0 }
local tokenOk = true

local env = harness.install({
    http = function(req)
        local url = tostring(req.url)
        if url:find("oauth2.googleapis.com/token", 1, true) then
            mailCalls.token = mailCalls.token + 1
            if not tokenOk then return { status = 400, json = { error = "invalid_grant" } } end
            return { status = 200, json = { access_token = "tok", expires_in = 3600 } }
        end
        if url:find("gmail.googleapis.com", 1, true) then
            local id = url:match("/messages/([%w]+)")
            if id then
                mailCalls.get = mailCalls.get + 1
                return { status = 200, json = mails[id] }
            end
            mailCalls.list = mailCalls.list + 1
            local rows = {}
            for mid in pairs(mails) do rows[#rows + 1] = { id = mid } end
            table.sort(rows, function(a, b) return a.id < b.id end)
            return { status = 200, json = { messages = rows } }
        end
        local number = tostring(req.url):match("tracking/(%w+)$")
        requests[#requests + 1] = number
        local a = answers[number]
        if a == nil then return { status = 404 } end
        if a == "down" then return { err = "timeout" } end
        return { status = 200, json = { tracking_number = number, status = a, custom_attributes = { target_machine_id = "WAW01M" } } }
    end
})

local subs = {}
function Plugin:mqttSubscribe(topic, fn) subs[topic] = fn end

local plugin = dofile(here .. "/init.lua")

--------------------------------------------------------------------------------
-- FACTORY
--------------------------------------------------------------------------------

answers["111"] = "confirmed"
local p = plugin:create({ id = "paczki", numbers = { "111", " 111 ", "" } })
check("create returns an instance with its id", p:getId() == "paczki")
check("duplicate numbers and empty ones are ignored", p:count() == 1)
check("duplicate id returns the same instance", plugin:create({ id = "paczki" }) == p)
check("a bad interval is an error", not pcall(function() plugin:create({ id = "x", interval = 5 }) end))
check("polling is on by default", env.pollers["inpost_paczki"] ~= nil and env.pollers["inpost_paczki"].started)
check("the ready sensor is registered", env.sensors["paczki_ready"] ~= nil)
check("the active sensor is registered", env.sensors["paczki_active"] ~= nil)
check("no clobbered sensors", #env.clobbered == 0)

for _, name in ipairs({ "track", "untrack", "on", "count", "readyCount", "list", "sensor", "refresh", "getState", "getId" }) do
    check("method " .. name .. " is on the instance", type(rawget(p, name)) == "function")
end
local src = io.open(here .. "/init.lua"):read("a")
check("plugin does not call setmetatable", src:find("setmetatable%s*%(") == nil)

--------------------------------------------------------------------------------
-- EVENTS
--------------------------------------------------------------------------------

local got = { new = {}, status = {}, ready = {}, delivered = {} }
for ev in pairs(got) do
    p:on(ev, function(parcel, prev) got[ev][#got[ev] + 1] = { parcel = parcel, prev = prev } end)
end
check("unknown event is an error", not pcall(function() p:on("nope", function() end) end))
check("on() without a function is an error", not pcall(function() p:on("new") end))

env.tick("inpost_paczki")
check("first status fires new", #got.new == 1 and got.new[1].parcel.number == "111")
check("new carries a Polish label", got.new[1].parcel.label == "Paczka potwierdzona")
check("new carries the machine", got.new[1].parcel.machine == "WAW01M")
check("no status event on the first status", #got.status == 0)

env.tick("inpost_paczki")
check("same status fires nothing", #got.new == 1 and #got.status == 0)

answers["111"] = "ready_to_pickup"
env.tick("inpost_paczki")
check("a change fires status with the previous one", #got.status == 1 and got.status[1].prev == "confirmed")
check("ready_to_pickup fires ready", #got.ready == 1)
check("readyCount is 1", p:readyCount() == 1)
check("ready sensor gives 1", env.sensors["paczki_ready"]:get() == 1)

answers["111"] = "delivered"
env.tick("inpost_paczki")
check("delivered fires delivered", #got.delivered == 1)
check("readyCount back to 0", p:readyCount() == 0)
check("delivered parcel stays until the next round", p:count() == 1)
env.tick("inpost_paczki")
check("then it is dropped", p:count() == 0)

--------------------------------------------------------------------------------
-- TRACK, UNTRACK, ERRORS
--------------------------------------------------------------------------------

answers["222"] = "out_for_delivery"
check("track adds a parcel", p:track("222") == true)
check("track again is false", p:track("222") == false)
check("track asks the API at once", requests[#requests] == "222")
check("a new parcel fires new", #got.new == 2 and got.new[2].parcel.status == "out_for_delivery")

check("kv keeps the parcels", type(env.kv["parcels:paczki"]) == "table" and env.kv["parcels:paczki"][1].number == "222")

check("untrack removes it", p:untrack("222") == true and p:count() == 0)
check("untrack of unknown is false", p:untrack("999") == false)

p:track("404")
local _, res = env.tick("inpost_paczki")
check("an unknown number does not crash, all failing is an error", res and res.err ~= nil)
check("lastError is kept", p:getState().lastError ~= nil)
p:untrack("404")

-- a handler that fails must not stop the others
local seen = false
p:on("new", function() error("boom") end)
p:on("new", function() seen = true end)
answers["333"] = "created"
p:track("333")
check("a failing handler does not block the next one", seen)

-- unsubscribe
local calls = 0
local off = p:on("status", function() calls = calls + 1 end)
off()
answers["333"] = "confirmed"
env.tick("inpost_paczki")
check("unsubscribe removes the handler", calls == 0)

-- restore after restart: the status is remembered, so no new event
check("state in KV survives", env.kv["parcels:paczki"] ~= nil)

-- a restarted instance with the same KV does not announce again
local plugin2 = dofile(here .. "/init.lua")
local again = plugin2:create({ id = "paczki", polling = false })
check("parcels come back from KV", again:count() == p:count())
check("statuses come back too, so readyCount is right at once", again:readyCount() == p:readyCount() and again:list()[1].status == p:list()[1].status)


--------------------------------------------------------------------------------
-- GMAIL
--------------------------------------------------------------------------------

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local function b64url(str)
    local out = {}
    for i = 1, #str, 3 do
        local a, b, c = str:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        local idx = { n // 262144, (n // 4096) % 64, (n // 64) % 64, n % 64 }
        local chars = (c and 4) or (b and 3) or 2
        for j = 1, chars do out[#out + 1] = B64:sub(idx[j] + 1, idx[j] + 1) end
    end
    return table.concat(out)
end

check("sanity: test encoder matches a known value", b64url("Man") == "TWFu" and b64url("Ma") == "TWE")

check("bad gmail config is an error", not pcall(function() plugin:create({ id = "m0", gmail = { clientId = "a" } }) end))

mails["m1"] = {
    snippet = "Twoja paczka jest w drodze",
    payload = { mimeType = "multipart/alternative", parts = {
        { mimeType = "text/plain", body = { data = b64url("Numer paczki: 600000000000000000000001. Kod 1234") } },
        { mimeType = "text/html", body = { data = b64url("<b>600000000000000000000001</b> 123456789012345678901234567") } },
    } }
}
mails["m2"] = { snippet = "Brak numeru tutaj 12345", payload = { body = { data = b64url("nic") } } }

answers["600000000000000000000001"] = "confirmed"
local mp = plugin:create({
    id = "poczta",
    gmail = { clientId = "cid", clientSecret = "sec", refreshToken = "rt", query = "from:inpost.pl" },
})
check("a gmail poller is created", env.pollers["inpost_mail_poczta"] ~= nil and env.pollers["inpost_mail_poczta"].started)

local newFromMail = {}
mp:on("new", function(parcel) newFromMail[#newFromMail + 1] = parcel.number end)
env.tick("inpost_mail_poczta")
check("a token was fetched once", mailCalls.token == 1)
check("the number from the mail is tracked", mp:count() == 1 and mp:list()[1].number == "600000000000000000000001")
check("only 24-digit numbers count (27 digits ignored)", mp:count() == 1)
check("tracking started at once, so new fired", newFromMail[1] == "600000000000000000000001")

local fetched = mailCalls.get
env.tick("inpost_mail_poczta")
check("seen mails are not fetched again", mailCalls.get == fetched)
check("the token is reused", mailCalls.token == 1)
check("seen ids are kept in KV", type(env.kv["mailseen:poczta"]) == "table" and #env.kv["mailseen:poczta"] == 2)

mails["m3"] = { snippet = "x", payload = { body = { data = b64url("paczka 600000000000000000000002") } } }
answers["600000000000000000000002"] = "created"
env.tick("inpost_mail_poczta")
check("a new mail adds a new parcel", mp:count() == 2)

tokenOk = false
mp._tokenValue = nil
local _, bad = env.tick("inpost_mail_poczta")
check("a token failure is reported, not thrown", bad and bad.err and tostring(bad.err):find("invalid_grant") ~= nil)
check("mailError is in the state", mp:getState().mailError ~= nil)
tokenOk = true

-- MQTT add
check("MQTT add topic is subscribed", type(subs["vclu/inpost/poczta/add"]) == "function")
answers["700000000000000000000009"] = "confirmed"
subs["vclu/inpost/poczta/add"]("vclu/inpost/poczta/add", "700000000000000000000009")
check("MQTT add tracks the parcel", mp:count() == 3)

plugin._cleanup()
check("cleanup stops pollers", env.pollers["inpost_paczki"].started == false and env.pollers["inpost_mail_poczta"].started == false)

os.exit(harness.report())
