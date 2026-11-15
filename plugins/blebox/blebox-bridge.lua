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

    -- ---------------------------------------------------------------- twoje urzadzenia

    local lampa = bb:create({ deviceId = "ee64c9c7496d", relay = 0, name = "Lampa" })
    bridge(lampa, "CLU221062464->DOU6243")

    -- switchBoxD ma drugi przekaznik:
    -- local lampa2 = bb:create({ deviceId = "ee64c9c7496d", relay = 1, name = "Lampa 2" })
    -- bridge(lampa2, "CLU221062464->DOU....")

    -- pojedynczy switchBox (jeden przekaznik, relay = 0):
    -- local gniazdo = bb:create({ deviceId = "IDENTYFIKATOR-Z-APLIKACJI", name = "Gniazdo" })
    -- bridge(gniazdo, "CLU221062464->DOU....")

    -- Opcjonalnie: wystaw w HA / HomeKit
    -- expose(lampa, "switch", { name = "Lampa" })
end
