-- modules/inpost.lua
-- InPost: Gmail -> sledzenie paczek -> sygnaly dla Grentona

-- 1) TU WKLEJ DANE Z GOOGLE (zostaw cudzyslowy)
local GMAIL = {
    clientId     = "2.pps.googleusercontent.com", -- w tym cudzysłowiu wprowadzasz clientID z google
    clientSecret = "D1BR8_KJH",  -- w tym cudzysłowiu wprowadzasz sekretny klucz z google
    refreshToken = "aL2ka8rTXXVTAwwxD6nA",
    query = "from:(inpost.pl OR allegromail.pl) newer_than:3d",
}

-- 2) TU WKLEJ SCIEZKI OBIEKTOW DOUT Z "Debug -> Registry"
--    (kolumna Path, np. CLU000000000.DOU0000). Nieuzywane zostaw jako "".
local SCIEZKI = {
    nowa      = "CLU22104.DOU701",  -- impuls: nowa paczka
    gotowa    = "CLU22104.DOU526",  -- impuls: paczka czeka w paczkomacie
    doreczona = "CLU22104.DOU861",  -- impuls: paczka odebrana
    czeka1    = "CLU22104.DOU719",  -- stan ON: czeka co najmniej 1 paczka
    czeka2    = "CLU22104.DOU903",  -- stan ON: czekaja co najmniej 2
    czeka3    = "",                      -- stan ON: czekaja co najmniej 3
    czeka4    = "",                      -- stan ON: czekaja co najmniej 4
}

-- Dalej nic nie zmieniaj.

-- Dalej nic nie zmieniaj.

-- Dalej nic nie zmieniaj.


local IMPULS_MS = 1000  -- dlugosc impulsu (1 s)

local function log(poziom, tekst)
    Logger:getShared()[poziom](Logger:getShared(), "[InPost] " .. tekst)
end

-- Start z 5-sekundowym opoznieniem: plugin na pewno bedzie juz wczytany.
EventBus:getShared():setTimeout(function()
    local inpost = Plugin.getPlugin("@vonxavier/inpost")
    if not inpost then
        log("warn", "plugin @vonxavier/inpost nie jest wczytany (Plugins -> Installed, ma byc enabled)")
        return
    end

    local paczki = inpost:create({ id = "paczki", gmail = GMAIL })

    -- Test bez czekania na maila: odkomentuj, wpisz 24-cyfrowy numer
    -- starej paczki, zapisz i przeladuj. Po tescie usun te linie.
    -- paczki:track("123456789654108435294979")

    
-- Dalej nic nie zmieniaj.

-- Dalej nic nie zmieniaj.

-- Dalej nic nie zmieniaj.


    local function obiekt(nazwa)
        local sciezka = SCIEZKI[nazwa]
        if sciezka == nil or sciezka == "" then return nil end
        sciezka = sciezka:gsub("%s", ""):gsub("%-%>", ".")  -- zapis z OM "CLU->DOU" na "CLU.DOU"
        local ok, o = pcall(function() return _:get(sciezka) end)
        if not ok or o == nil then
            log("warn", "nie znaleziono obiektu " .. sciezka .. " (" .. nazwa .. "), sprawdz w Debug -> Registry")
            return nil
        end
        return o
    end

    local nowa, gotowa, doreczona = obiekt("nowa"), obiekt("gotowa"), obiekt("doreczona")
    local poziomy = { obiekt("czeka1"), obiekt("czeka2"), obiekt("czeka3"), obiekt("czeka4") }

    local function impuls(o)
        if o then o:switchOn(IMPULS_MS) end
    end

    local function odswiez()
        local n = paczki:readyCount()
        for i = 1, 4 do
            if poziomy[i] then poziomy[i]:setValue(n >= i and 1 or 0) end
        end
    end

    paczki:on("new", function(p)
        log("info", "nowa paczka " .. p.number .. ": " .. p.label)
        impuls(nowa)
    end)
    paczki:on("ready", function(p)
        log("info", "paczka " .. p.number .. " czeka na odbior")
        impuls(gotowa)
        odswiez()
    end)
    paczki:on("delivered", function(p)
        log("info", "paczka " .. p.number .. " odebrana")
        impuls(doreczona)
        odswiez()
    end)
    paczki:on("status", function() odswiez() end)

    odswiez()  -- stan po restarcie
    log("info", "uruchomiono")
end, 5000)
