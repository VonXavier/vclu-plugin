--[[
    shelly.lua - most vCLU -> Grenton dla Shelly (plugin @vonxavier/shelly)

    Plik wrzuc do katalogu modules/ w vCLU (Edytor w panelu), np. modules/shelly.lua.

    Co robi:
      1. tworzy obiekty Shelly (plugin @vonxavier/shelly),
      2. laczy kazde Shelly z lokalnym DOUT vCLU (pole `dout`): stan Shelly -> DOUT
         i komenda z Grentona (DOUT) -> Shelly. Grenton widzi taki DOUT w Object Managerze
         jak zwykly przekaznik,
      3. opcjonalnie wysyla pomiary (moc, energia, napiecie, prad, temperatura)
         do CECH UZYTKOWNIKA na CLU Grentona,
      4. wystawia obiekt do Home Assistant / HomeKit przez expose() (jesli ich uzywasz).

    Dodanie urzadzenia = jeden blok w tabeli DEVICES nizej.
    Instrukcja krok po kroku: README pluginu.
]]

local sh = Plugin.getPlugin("@vonxavier/shelly")
if not sh then
    print("shelly.lua: brak pluginu @vonxavier/shelly (zainstaluj go w vCLU)")
    return
end

-- Podsiec do skanowania, jesli inna niz 192.168.1
-- sh:setSubnet("192.168.0")

--------------------------------------------------------------------------------
-- USTAWIENIA
--------------------------------------------------------------------------------

-- CLU, na ktorym masz cechy uzytkownika (numer z Registry w panelu vCLU).
-- Potrzebne tylko do wysylania pomiarow do Grentona.
local CLU = CLU221000290   -- ZMIEN na numer swojego CLU

local DEVICES = {
    {
        deviceId = "907069747f40",          -- ID urzadzenia z aplikacji Shelly
        channel  = 0,                       -- kanal (domyslnie 0)
        name     = "Gniazdo Shelly",        -- nazwa

        -- Sposob polaczenia z Shelly: "http" (domyslnie) albo "mqtt" (README, krok 5).
        -- transport = "mqtt",
        -- topic     = "moj/prefiks",   -- tylko gdy w Shelly zmieniles prefiks tematu MQTT

        -- DOUT w vCLU, ktory Grenton widzi jako przekaznik (usun linie, jesli niepotrzebny).
        -- Wpisz ID z panelu vCLU (np. "CLU.DOU5048") albo nazwe z kreatora
        -- (np. "CLU.DOUT8T_1_DOU1").
        dout     = "CLU.DOU5048",

        -- Pomiary do Grentona (usun dwie ponizsze linie, jesli niepotrzebne):
        grenton  = "shelly_gniazdo",        -- poczatek nazwy cech uzytkownika
        features = { "moc", "energia" },    -- ktore pomiary wysylac (lista nizej)
    },
}

-- Dostepne pomiary. Cecha na CLU nazywa sie <grenton>_<pomiar>,
-- np. shelly_gniazdo_moc (typ NUMBER, tworzysz ja w Object Managerze).
local FEATURES = {
    moc         = "getPower",         -- W
    energia     = "getEnergy",        -- Wh (licznik calkowity)
    napiecie    = "getVoltage",       -- V
    prad        = "getCurrent",       -- A
    temperatura = "getTemperature",   -- st. C
}

local MIN_CHANGE_W = 1        -- wysylaj, gdy moc zmieni sie o tyle watow
local REFRESH_MS = 5 * 60 * 1000   -- co ile odswiezac cechy (np. po restarcie CLU)

--------------------------------------------------------------------------------
-- DOUT <-> SHELLY (przypisanie do Grentona)
--------------------------------------------------------------------------------

local function bindDout(sw, d)
    local found, dout = pcall(function() return _:get(d.dout) end)
    if not found or not dout then
        print("shelly.lua: nie znaleziono DOUT '" .. tostring(d.dout)
            .. "' (sprawdz ID w panelu vCLU, w Registry)")
        return nil
    end

    -- Shelly -> DOUT: Grenton widzi aktualny stan (takze po wcisnieciu przycisku na gniazdku)
    sw:onChange(function(new)
        if dout:getValue() ~= new then
            dout:set(DOUT.FEATURE_VALUE, new)
        end
    end)

    -- Grenton -> Shelly: komenda z OM, skryptu albo aplikacji
    -- Gdy komenda sie nie uda, DOUT wraca do prawdziwego stanu Shelly.
    local function revertOnFail(ok)
        if not ok then dout:set(DOUT.FEATURE_VALUE, sw:getValue()) end
    end

    dout:add_event(DOUT.EVENT_ON_SWITCH_ON, function()
        if not sw:isOn() then sw:on(revertOnFail) end
    end)

    dout:add_event(DOUT.EVENT_ON_SWITCH_OFF, function()
        if sw:isOn() then sw:off(revertOnFail) end
    end)

    return dout
end

--------------------------------------------------------------------------------
-- POMIARY -> CECHY UZYTKOWNIKA NA CLU
--------------------------------------------------------------------------------

local function pushToGrenton(sw, prefix, features)
    if not CLU then return end
    for i, f in ipairs(features) do
        local getter = FEATURES[f]
        local value = getter and sw[getter](sw)
        if value ~= nil then
            CLU:set(prefix .. "_" .. f, value)
        end
    end
end

local function exportToGrenton(sw, d)
    if not d.grenton then return end
    if not CLU then
        print("shelly.lua: nie ustawiono CLU, pomiary nie beda wysylane do Grentona")
        return
    end
    local features = d.features or { "moc", "energia" }

    for i, f in ipairs(features) do
        if not FEATURES[f] then
            print("shelly.lua: nieznany pomiar '" .. tostring(f) .. "' (dozwolone: moc, energia, napiecie, prad, temperatura)")
        end
    end

    -- zapis przy zmianie mocy
    local last = nil
    sw:onMeasure(function(m)
        if m.power ~= nil and (last == nil or math.abs(m.power - last) >= MIN_CHANGE_W) then
            last = m.power
            pushToGrenton(sw, d.grenton, features)
        end
    end)

    -- cykliczne odswiezenie (po restarcie CLU cecha wraca do wartosci poczatkowej)
    every(REFRESH_MS, function()
        pushToGrenton(sw, d.grenton, features)
    end)
end

--------------------------------------------------------------------------------
-- URZADZENIA
--------------------------------------------------------------------------------

local objects = {}

for i, d in ipairs(DEVICES) do
    local sw = sh:create({
        deviceId = d.deviceId,
        channel = d.channel or 0,
        name = d.name,
        transport = d.transport,   -- nil = http
        topic = d.topic            -- nil = domyslny prefiks (id Shelly)
    })

    local dout = nil
    if d.dout then
        dout = bindDout(sw, d)
    end

    -- Home Assistant / HomeKit (tylko jesli ich uzywasz): wystawiamy DOUT, a bez DOUT samo Shelly
    expose(dout or sw, "switch", { name = d.name })

    exportToGrenton(sw, d)

    objects[d.name] = sw
end

return objects
