--[[
    shelly.lua - most vCLU -> Grenton dla Shelly (plugin @vonxavier/shelly)

    Plik wrzuc do katalogu modules/ w vCLU (Edytor w panelu), np. modules/shelly.lua.

    Co robi:
      1. tworzy obiekty Shelly i wystawia je do Grentona przez expose() jako przelaczniki
         (jak lampy BleBox),
      2. opcjonalnie wysyla pomiary (moc, energia, napiecie, prad, temperatura)
         do CECH UZYTKOWNIKA na CLU Grentona.

    Dodanie urzadzenia = jedna linia w tabeli DEVICES nizej.
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
-- Zostaw jak jest, jesli nie wysylasz pomiarow do Grentona.
local CLU = CLU221000290   -- ZMIEN na numer swojego CLU

local DEVICES = {
    {
        deviceId = "907069747f40",          -- ID urzadzenia z aplikacji Shelly
        channel  = 0,                       -- kanal (domyslnie 0)
        name     = "Gniazdo Shelly",        -- nazwa widoczna w Grentonie
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
        name = d.name
    })

    -- Wystawienie do Grentona jako przelacznik (on/off + stan)
    expose(sw, "switch", { name = d.name })

    exportToGrenton(sw, d)

    objects[d.name] = sw
end

return objects
