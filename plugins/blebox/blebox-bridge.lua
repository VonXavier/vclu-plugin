
-- Most BleBox <-> DOUT (modul wirtualny z wizarda)
-- Wklej jako nowy plik w clu/modules/ (np. blebox-bridge.lua) przez edytor Lua w panelu.
-- NIE do user.lua - to plik generowany przez OM i nadpisywany przy synchronizacji.
--
-- Wynik: DOUT jest w Object Managerze jak zwykly przekaznik Grentona,
--        a zmiana z Grentona / aplikacji / BleBoxa synchronizuje druga strone.
--
-- DEBUG = true: wypisuje (print) kazdy krok. Szukaj linii "blebox-bridge:" w logach aplikacji.
 
local DEBUG = true
 
local function dbg(msg)
    if DEBUG then print("blebox-bridge: " .. msg) end
end
 
-- dout: sciezka w rejestrze, name: nazwa obiektu z OM (zapasowo, jako zmienna globalna)
local BLEBOX_BRIDGE = {
    { id = "ee64c9c7496d", relay = 0, dout = "CLU221062464.DOU6243", name = "x207515563_DOUT_01" },
    { id = "ee64c9c7496d", relay = 1, dout = "CLU221062464.DOU6046", name = "x207515563_DOUT_02" },
}
 
-- Szuka obiektu kilkoma sposobami, bo nie wiem, pod jaka sciezka vclu trzyma lokalny wirtualny CLU.
local function findDout(b)
    local obj = _:get(b.dout)
    if obj then return obj, b.dout end
 
    local short = string.gsub(b.dout, "^CLU%d+%.", "CLU.")
    if short ~= b.dout then
        obj = _:get(short)
        if obj then return obj, short end
    end
 
    if b.name and _G and _G[b.name] then
        return _G[b.name], "global " .. b.name
    end
    return nil, nil
end
 
local function isOn(v)
    return v == 1 or v == true or v == "1"
end
 
local bb = Plugin.getPlugin("@vonxavier/blebox")
dbg("plugin = " .. tostring(bb))
 
if bb then
    local byKey = {}
    dbg("plugin gotowy = " .. tostring(bb:isReady()))
 
    -- UWAGA: nie uzywaj "for _, b in ..." - "_" to rejestr (_:get)
    for i, b in ipairs(BLEBOX_BRIDGE) do
        local dout, how = findDout(b)
        if dout then
            dbg(b.id .. ":" .. b.relay .. " <-> " .. how)
            byKey[b.id .. ":" .. b.relay] = dout
 
            -- DOUT -> BleBox (zmiana z Grentona, aplikacji itd.)
            -- Callback moze dostac wartosc jako argument albo nie - wtedy czytamy getValue().
            dout:onChange(function(v)
                local val = v
                if val == nil then val = dout:getValue() end
                local want = isOn(val) and 1 or 0
                local have = bb:getRelay(b.id, b.relay)
                dbg("DOUT " .. b.dout .. " zmiana: arg=" .. tostring(v) .. ", chce=" .. want .. ", blebox=" .. tostring(have))
                if have ~= want then
                    local ok = bb:setRelay(b.id, b.relay, want)
                    dbg("setRelay -> " .. tostring(ok))
                end
            end)
 
            -- stan poczatkowy, jesli plugin zdazyl juz znalezc urzadzenie
            local current = bb:getRelay(b.id, b.relay)
            dbg("stan poczatkowy BleBox = " .. tostring(current))
            if current ~= nil then
                dout:setValue(current)
            end
        else
            dbg("nie znaleziono obiektu " .. b.dout .. " ani " .. tostring(b.name))
        end
    end
 
    -- BleBox -> DOUT (zmiana w apce BleBox, na urzadzeniu, przez inna integracje)
    EventBus:getShared():on("blebox:changed", function(d)
        dbg("blebox:changed " .. tostring(d.id) .. ":" .. tostring(d.relay) .. " = " .. tostring(d.state))
        local dout = byKey[d.id .. ":" .. d.relay]
        if dout then
            dout:setValue(d.state)
        end
    end)
else
    dbg("plugin @vonxavier/blebox niedostepny (zainstalowany i wlaczony?)")
end
 
