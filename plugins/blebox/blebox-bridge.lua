-- BleBox (plugin @vonxavier/blebox) + most do DOUT z Object Managera
--
-- Gdzie: nowy plik clu/modules/blebox-bridge.lua (edytor Lua w panelu).
--        NIE user.lua - to plik OM, nadpisywany przy synchronizacji.
-- Wynik: DOUT (modul wirtualny z wizarda) jest w OM jak zwykly przekaznik Grentona.
--        Zmiana z Grentona / aplikacji idzie do BleBoxa, a zmiana w BleBoxie do DOUT.
--
-- Konfiguracja urzadzen jest tutaj, w kodzie (plugin nie ma wlasnej konfiguracji).
--   deviceId - "Identyfikator urzadzenia" z aplikacji BleBox (plugin tez wypisuje go w logu po skanie)
--   relay    - numer przekaznika: switchBox ma 0, switchBoxD ma 0 i 1
--   DOUT     - id z Object Managera, np. "CLU221062464->DOU6243" (zapis ze strzalka tez dziala)
--
-- Brama (gateBox) to osobny rodzaj: createGate() + bridgeGate(). DOUT dziala jak przycisk:
-- narastajace zbocze (0 -> 1) = jeden impuls. Powrot do 0 (Signal 0.8 s w OM) jest ignorowany.

local bb = Plugin.getPlugin("@vonxavier/blebox")

if not bb then
    print("blebox-bridge: plugin @vonxavier/blebox niedostepny (zainstalowany i wlaczony?)")
else
    -- Tylko jesli siec nie jest 192.168.1.x (adres jest potrzebny jedynie do znalezienia urzadzen):
    -- bb:setSubnet("192.168.0")

    -- ---------------------------------------------------------------- most (nie trzeba edytowac)

    local function isOn(v)
        return v == 1 or v == true or v == "1"
    end

    -- OM podaje id jako CLU123->DOU456, rejestr uzywa kropki
    local function findDout(doutId)
        local path = string.gsub(doutId, "%s*%->%s*", ".")
        local obj = _:get(path)
        if obj then return obj end
        -- lokalny wirtualny CLU moze byc w rejestrze jako CLU.DOU456
        local short = string.gsub(path, "^CLU%d+%.", "CLU.")
        return _:get(short)
    end

    local function bridge(sw, doutId)
        local dout = findDout(doutId)
        if not dout then
            print("blebox-bridge: nie znaleziono DOUT " .. doutId .. " (sprawdz id w Object Managerze)")
            return
        end

        -- DOUT -> BleBox (zmiana z Grentona, aplikacji itd.)
        dout:onChange(function(v)
            local val = v
            if val == nil then val = dout:getValue() end
            local want = isOn(val) and 1 or 0
            if sw:getValue() == want then return end
            -- gdy komenda sie nie uda, DOUT wraca do prawdziwego stanu
            local function failed(ok)
                if not ok then dout:setValue(sw:getValue()) end
            end
            if want == 1 then sw:on(failed) else sw:off(failed) end
        end)

        -- BleBox -> DOUT (zmiana w apce BleBox, na urzadzeniu, przy starcie vclu)
        sw:onChange(function(newValue)
            dout:setValue(newValue)
        end)
    end

    -- Brama: DOUT jako przycisk (np. DOUT z Signal 0.8 s w OM).
    -- Tylko wlaczenie DOUT-a wysyla impuls; wylaczenie jest ignorowane. Brak stanu zwrotnego do DOUT.
    -- Zabezpieczenia (uzbrajanie po starcie, odstep miedzy impulsami, brak ponowien) sa w pluginie.
    local function bridgeGate(gate, doutId)
        local dout = findDout(doutId)
        if not dout then
            print("blebox-bridge: nie znaleziono DOUT " .. doutId .. " (sprawdz id w Object Managerze)")
            return
        end
        dout:onChange(function(v)
            local val = v
            if val == nil then val = dout:getValue() end
            if isOn(val) then
                gate:trigger()
            end
        end)
    end

    -- ---------------------------------------------------------------- twoje urzadzenia

    -- switchBoxD (id ee6496d): dwa przekazniki
    local lampa = bb:create({ deviceId = "ee6496d", relay = 0, name = "Lampa" })
    bridge(lampa, "CLU22164->DOU43")

    local lampa2 = bb:create({ deviceId = "ee6496d", relay = 1, name = "Lampa 2" })
    bridge(lampa2, "CLU22104->DOU66")

    -- gateBox (id aa48f): brama sterowana impulsem
    -- opcje: cooldown (s miedzy impulsami, domyslnie 5), armDelay (s ignorowania po starcie, domyslnie 10)
    local brama = bb:createGate({ deviceId = "aa497f", name = "Brama" })
    bridgeGate(brama, "CLU22164->DOU01")

    -- pojedynczy switchBox (jeden przekaznik, relay = 0): -- konfiguracja identyczna jak dla SwichtBoxD
    -- local gniazdo = bb:create({ deviceId = "IDENTYFIKATOR-Z-APLIKACJI", name = "Gniazdo" })
    -- bridge(gniazdo, "CLU22164->DOU....")

    -- Opcjonalnie: wystaw w HA / HomeKit (brama: swiadomie, bo to otwieranie bramy z zewnatrz)
    -- expose(lampa, "switch", { name = "Lampa" })
end
