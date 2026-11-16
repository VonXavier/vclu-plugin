# InPost Paczki: instrukcja krok po kroku

Plugin pilnuje Twoich paczek InPost i daje znać Grentonowi, gdy:

- pojawi się **nowa paczka**,
- paczka jest **gotowa do odbioru** w paczkomacie,
- paczka została **odebrana**.

Instrukcja jest dla osoby, która nie zna Lua. Kod trzeba tylko **wkleić** i w kilku
miejscach **wpisać własne dane**. Wszystko, co wpisujesz, oznaczone jest `WKLEJ_...`.

## 1. Co plugin robi, a czego nie

1. Co kilka minut czyta Twojego Gmaila (tylko do odczytu) i szuka maili od InPost.
2. Wyciąga z nich 24-cyfrowe numery przesyłek.
3. Pyta publiczne API InPost o status każdej paczki (bez logowania, bez klucza InPost).
4. Gdy status się zmieni, wysyła sygnał do wskazanych wyjść Grentona.

**Ograniczenia, które warto znać od razu:**

- Plugin potrzebuje maila z numerem przesyłki. InPost nie udostępnia publicznie listy
  paczek wysłanych na Twój numer telefonu.
- Plugin **nie zmienia sam żadnych obiektów vCLU** (to celowe zabezpieczenie vCLU).
  Sygnały do Grentona wysyła krótki moduł, który wkleisz w kroku 7.
- **Liczba paczek nie trafi do Grentona jako liczba.** Wirtualny moduł DOUT8T ma tylko
  wejście analogowe, którego wartości vCLU nie ustawia z kodu. Zamiast liczby dostajesz
  cztery "poziomy": wyjście ON, gdy czeka co najmniej 1, 2, 3 albo 4 paczki.
- Plugin nie zna kodu odbioru paczki ani numeru telefonu. To dane z aplikacji InPost.

## 2. Co będzie potrzebne

- Działający vCLU i dostęp do jego panelu WWW (adres `http://<adres-vclu>:8080`).
- Konto Gmail, na które przychodzą powiadomienia InPost.
- Do Grentona: vCLU skonfigurowany jako **CLU** (z modułami) oraz komputer z
  Grenton Object Managerem w tej samej sieci lokalnej co vCLU.

## 3. Instalacja pluginu

1. W panelu vCLU wejdź w **Plugins**.
2. W sekcji **Repositories** sprawdź, czy jest repozytorium z tym pluginem. Jeśli nie,
   dodaj je (nazwa i adres URL): [`https://github.com/VonXavier/vclu-plugin`](https://github.com/VonXavier/vclu-plugin).
3. W zakładce **Available** znajdź **InPost Paczki** (`@vonxavier/inpost`) i kliknij **Install**.
4. Panel przełączy się na **Installed**. Plugin ma tam zielony znaczek **enabled**.
   Osobne "Enable" nie jest potrzebne.

Samo zainstalowanie nie uruchamia jeszcze śledzenia paczek. To zrobi moduł z kroku 5.

## 4. Dane z Google (Gmail)

Aby vCLU mogło czytać Gmaila, Google wymaga własnych danych dostępowych. Potrzebujesz
trzech wartości: `clientId`, `clientSecret` i `refreshToken`. Robisz to **raz**.

Nazwy przycisków w Google zmieniają się od czasu do czasu. Jeśli czegoś nie widzisz,
szukaj pozycji o podobnej nazwie.

### 4.1 Projekt w Google Cloud

1. Otwórz [Google Cloud Console](https://console.cloud.google.com) i zaloguj się kontem Google z tym Gmailem.
2. Kliknij listę projektów na górnym pasku → **New project** → nazwa np. `vCLU InPost` → **Create**.
3. Upewnij się, że ten projekt jest wybrany.

### 4.2 Włączenie Gmail API

1. Otwórz [Gmail API w Google Cloud](https://console.cloud.google.com/apis/library/gmail.googleapis.com)
2. Kliknij **Enable**. Jeśli widzisz, że API jest już włączone, przejdź dalej.

### 4.3 Ekran zgody OAuth

1. Otwórz [**Google Auth Platform**](https://console.cloud.google.com/auth/overview) (w starszym widoku: **APIs & Services → OAuth consent screen**).
2. Jeśli widzisz **Get started**, kliknij i wpisz nazwę aplikacji (np. `vCLU InPost`)
   oraz swój adres e-mail.
3. Jako odbiorców wybierz **External** (zwykłe konto Gmail).
4. W zakładce [**Audience**](https://console.cloud.google.com/auth/audience) w sekcji **Test users** dodaj swój adres Gmail.
5. **Ważne:** w trybie **Testing** token wygasa po 7 dniach i plugin przestanie czytać
   pocztę. Przełącz aplikację na **In production** (przycisk w zakładce **Audience**).
   Google pokaże ostrzeżenie o niezweryfikowanej aplikacji. To Twoja własna aplikacja,
   więc przy zgodzie wybierz **Advanced → Go to ... (unsafe)**.

### 4.4 Identyfikator klienta

1. W Google Auth Platform otwórz [**Clients**](https://console.cloud.google.com/auth/clients) → **Create client**.
2. Typ aplikacji: **Web application**. Nie wybieraj "Desktop app": OAuth Playground
   z takim klientem kończy się błędem `redirect_uri_mismatch`.
3. Nazwa np. `vCLU InPost`.
4. W sekcji **Authorized redirect URIs** kliknij **Add URI** i wpisz dokładnie
   (bez spacji i bez ukośnika na końcu):

```text
https://developers.google.com/oauthplayground
```

5. Kliknij **Create**. Skopiuj **Client ID** (kończy się na `.apps.googleusercontent.com`)
   i **Client secret**.
6. Zmiany w Google mogą zacząć działać dopiero po kilku minutach. Jeśli w kroku 4.5
   pojawi się błąd, odczekaj chwilę i spróbuj ponownie.

### 4.5 Refresh token

1. Otwórz [Google OAuth 2.0 Playground](https://developers.google.com/oauthplayground)
2. Kliknij **koło zębate** (prawy górny róg) i zaznacz **Use your own OAuth credentials**.
3. Wklej **Client ID** i **Client secret** z kroku 4.4 i zamknij okno ustawień.
4. W polu zakresów w **Step 1** wpisz dokładnie (bez spacji i bez niczego dookoła):

```text
https://www.googleapis.com/auth/gmail.readonly
```

5. Kliknij **Authorize APIs**, wybierz swoje konto i zaakceptuj dostęp.
6. W **Step 2** kliknij **Exchange authorization code for tokens**.
7. Skopiuj wartość **refresh_token**. Nie kopiuj `access_token`, bo ten wygasa po godzinie.

Jeśli `refresh_token` się nie pojawi, wejdź na [stronę uprawnień konta Google](https://myaccount.google.com/permissions),
usuń zgodę dla swojej aplikacji i powtórz kroki 5 i 6.

Masz teraz trzy wartości. **Nie wysyłaj ich nikomu i nie umieszczaj ich w GitHubie.**

## 5. Gdzie w vCLU wpisać dane z Google

Dane wpisujesz w module (pliku z kodem) w edytorze vCLU. Przygotuj kod z kroku 5.2
z już wklejonymi danymi Google. Ścieżki Grentona (`WKLEJ_SCIEZKE_...`) uzupełnisz w kroku 7.

### 5.1 Utwórz plik modułu

1. W panelu vCLU otwórz **Editor**.
2. W drzewie plików po lewej wejdź do katalogu **modules**.
3. Kliknij **New File**, wpisz `inpost.lua` i potwierdź (**Create**).
   Plik ma leżeć bezpośrednio w katalogu `modules`, nie w podkatalogu.
4. Otwórz ten plik. Powinien być pusty.

vCLU wczytuje automatycznie każdy plik `.lua` z katalogu `modules`. Nie trzeba
nigdzie dopisywać jego nazwy.

### 5.2 Wklej kod

Wklej cały poniższy kod do `modules/inpost.lua`. Zamień **tylko trzy teksty**
w sekcji `GMAIL` (zostaw cudzysłowy), czyli `WKLEJ_CLIENT_ID`, `WKLEJ_CLIENT_SECRET`
i `WKLEJ_REFRESH_TOKEN`.

```lua
-- modules/inpost.lua
-- InPost: Gmail -> sledzenie paczek -> sygnaly dla Grentona

-- 1) TU WKLEJ DANE Z GOOGLE (zostaw cudzyslowy)
local GMAIL = {
    clientId     = "WKLEJ_CLIENT_ID",
    clientSecret = "WKLEJ_CLIENT_SECRET",
    refreshToken = "WKLEJ_REFRESH_TOKEN",
}

-- 2) TU WKLEJ SCIEZKI OBIEKTOW DOUT Z "Debug -> Registry"
--    (kolumna Path, np. CLU000000000.DOU0000). Nieuzywane zostaw jako "".
local SCIEZKI = {
    nowa      = "WKLEJ_SCIEZKE_DOUT_1",  -- impuls: nowa paczka
    gotowa    = "WKLEJ_SCIEZKE_DOUT_2",  -- impuls: paczka czeka w paczkomacie
    doreczona = "WKLEJ_SCIEZKE_DOUT_3",  -- impuls: paczka odebrana
    czeka1    = "WKLEJ_SCIEZKE_DOUT_4",  -- stan ON: czeka co najmniej 1 paczka
    czeka2    = "",                      -- stan ON: czekaja co najmniej 2
    czeka3    = "",                      -- stan ON: czekaja co najmniej 3
    czeka4    = "",                      -- stan ON: czekaja co najmniej 4
}

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
    -- paczki:track("TU_NUMER_24_CYFRY")

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
```

Kliknij **Save** (albo Ctrl+S).

### 5.3 Uruchom i sprawdź

1. Kliknij żółty przycisk **Reload Lua Runtime**. Przeładowanie wczytuje na nowo
   wtyczki i moduły, więc po każdej zmianie w pliku używaj tego przycisku.
2. Poczekaj około 5 sekund. Moduł celowo startuje z opóźnieniem, żeby plugin
   na pewno był już wczytany.
3. Otwórz zakładkę **Lua Logs** pod edytorem. Powinien pojawić się wpis
   `[InPost] uruchomiono`.

Jeśli w logu jest `[InPost] plugin @vonxavier/inpost nie jest wczytany`, wróć do kroku 3
i sprawdź, czy plugin jest na liście **Installed** ze znaczkiem **enabled**.

Dopóki w sekcji `SCIEZKI` stoją teksty `WKLEJ_...`, w logu pojawią się ostrzeżenia
`nie znaleziono obiektu`. To normalne przed krokiem 7. Samo śledzenie paczek już działa.

### 5.4 Jak to sprawdzić na prawdziwej paczce

1. W module odkomentuj linię `-- paczki:track("TU_NUMER_24_CYFRY")` (usuń `--`) i wpisz
   numer starej, już odebranej paczki z maila od InPost.
2. **Save** i **Reload Lua Runtime**.
3. W **Lua Logs** zobaczysz `[InPost] nowa paczka ...` i po chwili `... odebrana`.
4. Po teście usuń tę linię albo wstaw z powrotem `--`.

### 5.5 Jak plugin wybiera maile

Domyślnie czyta maile od `inpost.pl` z ostatnich 3 dni, co 5 minut. Jeśli numer
przesyłki przychodzi z maili sklepu, dopisz w sekcji `GMAIL` linię:

```lua
    query = "from:(inpost.pl OR sklep.pl) newer_than:3d",
```

Zamiast `sklep.pl` wpisz domenę sklepu. Plugin szuka dowolnego 24-cyfrowego ciągu
w treści maila, więc jeśli trafi się inny 24-cyfrowy ciąg, też go potraktuje jako paczkę.

Przy pierwszym uruchomieniu plugin zobaczy też maile o paczkach z ostatnich 3 dni,
w tym już odebranych. Dostaniesz wtedy "nową paczkę" i od razu "odebraną". Żeby tego
uniknąć, wpisz w `query` krótszy okres, np. `newer_than:1d`.

## 6. Dane Google są wrażliwe

Plik `modules/inpost.lua` zawiera dane dostępowe do Twojej poczty (tylko do odczytu).
Kopie zapasowe vCLU (zakładka **Backup**) obejmują ten plik, więc nie udostępniaj ich
innym. Dostęp możesz w każdej chwili cofnąć na [stronie uprawnień konta Google](https://myaccount.google.com/permissions).

## 7. Przekazanie danych do Grentona, krok po kroku

Plugin sygnalizuje zdarzenia przez wyjścia cyfrowe **DOUT** wirtualnego modułu vCLU.
Object Manager widzi je jak zwykłe wyjścia Grentona.

Potrzebujesz **co najmniej 4 wolnych wyjść DOUT**:

| Wyjście | Rodzaj | Znaczenie |
|---|---|---|
| 1 | impuls (1 s) | nowa paczka |
| 2 | impuls (1 s) | paczka czeka w paczkomacie |
| 3 | impuls (1 s) | paczka odebrana |
| 4 | stan ON/OFF | czeka co najmniej 1 paczka |
| 5 do 7 (opcjonalnie) | stan ON/OFF | czekają co najmniej 2, 3, 4 paczki |

### 7.1 Sprawdź, czy masz wolne DOUT

1. W panelu vCLU wejdź w **Debug** → zakładka **Registry**.
2. W filtrze typu wybierz **DOUT** (albo wpisz `DOU` w wyszukiwarkę).
3. Każdy wiersz to jeden obiekt. Ścieżka ma postać `CLU123456789.DOU0123`. Cyfry będą u Ciebie inne.
4. **Nie używaj wyjść, które obsługują już inne urządzenia** (np. most do innych wtyczek).

Masz 4 wolne? Pomiń 7.2 i 7.3 i przejdź do 7.4. W kroku 8 sprawdzisz, czy Object Manager widzi te wyjścia.

### 7.2 Brakuje wyjść: dodaj moduł DOUT8T

1. W panelu wejdź w **Grenton** → zakładka **Modules** → **Add Module**.
2. Wybierz typ **DOUT8T** (8 wyjść DOUT, 8 wejść DIN) i zapisz.
3. Zakładka **Modules** jest widoczna tylko wtedy, gdy vCLU ma typ **CLU**. Typ wybiera się
   w kreatorze konfiguracji i po jego zakończeniu nie można go zmienić.
4. Po zmianie modułów kreator każe **zrestartować vCLU** i wykonać **discovery** w Object Managerze.
   Zrób to w kolejności opisanej w 7.3.

### 7.3 Object Manager: odśwież kontroler

1. Uruchom vCLU od nowa (restart usługi lub komputera).
2. W Object Managerze uruchom **CLU Discovery**. Komputer z OM i vCLU muszą być w tej samej sieci,
   a zapora nie może blokować UDP na porcie 1234.
3. Jeśli vCLU nie ma jeszcze w projekcie, dodaj go. Jeśli już jest, odśwież jego konfigurację
   (odczyt modułów kontrolera).
4. Sprawdź, że nowe wyjścia DOUT widać w projekcie.
5. Zapisz projekt i wyślij konfigurację do kontrolera.
6. **Nie edytuj ręcznie plików `om.lua` ani `user.lua`.** Object Manager zapisuje je od nowa
   przy każdej synchronizacji. Własny kod trzymaj w `modules/`, tak jak w kroku 5.

Dokładne nazwy przycisków zależą od wersji Object Managera.

### 7.4 Zapisz ścieżki wyjść

1. Wróć do vCLU: **Debug → Registry**, typ **DOUT**.
2. Dla wyjść 1 do 4 skopiuj pełną ścieżkę z kolumny **Path**, np. `CLU123456789.DOU0123`.
3. Ścieżki zawsze bierz **ze swojego** Registry. Nie przepisuj ich z przykładów.
4. W vCLU ścieżka ma kropkę: `CLU123456789.DOU0123`. Object Manager zapisuje ją ze strzałką
   (`CLU123456789->DOU0123`). Moduł sam zamienia strzałkę na kropkę, więc zadziała każdy zapis.

### 7.5 Wpisz ścieżki do modułu

1. W **Editor** otwórz `modules/inpost.lua`.
2. W sekcji `SCIEZKI` zamień teksty w cudzysłowach:
   - `WKLEJ_SCIEZKE_DOUT_1` → ścieżka wyjścia 1 (nowa paczka),
   - `WKLEJ_SCIEZKE_DOUT_2` → wyjście 2 (czeka w paczkomacie),
   - `WKLEJ_SCIEZKE_DOUT_3` → wyjście 3 (odebrana),
   - `WKLEJ_SCIEZKE_DOUT_4` → wyjście 4 (stan: czeka co najmniej 1).
3. Dla poziomów 2, 3 i 4 wpisz ścieżki kolejnych wolnych wyjść w `czeka2`, `czeka3`, `czeka4`.
   Nieużywane zostaw jako `""`.
4. **Save** i **Reload Lua Runtime**.
5. W **Lua Logs** nie powinno być ostrzeżeń `nie znaleziono obiektu`. Jeśli są, sprawdź
   ścieżkę w tym wpisie: musi być identyczna jak w **Debug → Registry**.

### 7.6 Sprawdź działanie

1. Zrób test z 5.4 (stary numer paczki).
2. Wyjście 1 da impuls 1 s ("nowa paczka"), a po chwili wyjście 3 ("odebrana").
3. Obserwuj te wyjścia w **Debug → Registry** (wartość zmienia się 0 → 1 → 0) albo
   w Object Managerze po podłączeniu automatyki z kroku 8.

### 7.7 Gdy zmieni się liczba paczek

Poziomy (wyjście 4 i opcjonalnie 5 do 7) aktualizują się przy każdej zmianie statusu
oraz po każdym uruchomieniu vCLU, więc po restarcie nie zaczynają od zera.

## 8. Automatyzacje w Object Managerze

Poniżej opis w ogólnej formie. Nazwy menu zależą od wersji Object Managera.

Dla każdego wyjścia DOUT, które podłączyłeś w kroku 7.5, możesz w OM dodać
**zdarzenie** i przypisać do niego akcję. Dostępne zdarzenia wyjścia to między innymi
**OnSwitchOn** (po włączeniu), **OnSwitchOff** (po wyłączeniu) i **OnValueChange** (po zmianie).

| Co chcesz | Wyjście | Zdarzenie | Przykładowa akcja |
|---|---|---|---|
| Wiadomość o nowej paczce | 1 | OnSwitchOn | komunikat na panelu, sygnał, światło |
| Paczka czeka w paczkomacie | 2 | OnSwitchOn | komunikat "Paczka czeka w paczkomacie" |
| Paczka odebrana | 3 | OnSwitchOn | wyłączenie sygnalizacji |
| Są paczki do odbioru | 4 | OnSwitchOn / OnSwitchOff | wskaźnik na panelu włączony/wyłączony |
| Dwie lub więcej paczek | 5 | OnSwitchOn | inny komunikat |

Wyjścia 1 do 3 działają jak impulsy: włączają się na 1 sekundę i same wyłączają, więc
reaguj na **włączenie**, a nie na stan.

## 9. Co robić, gdy coś nie działa

| Objaw | Co sprawdzić |
|---|---|
| W logu: `plugin ... nie jest wczytany` | **Plugins → Installed**: czy jest **InPost Paczki** ze znaczkiem **enabled**. Po instalacji kliknij **Reload Lua Runtime**. |
| Brak wpisu `[InPost] uruchomiono` | Czy plik nazywa się dokładnie `inpost.lua` i leży bezpośrednio w `modules` (nie w podkatalogu), czy zapisałeś go i kliknąłeś **Reload Lua Runtime**. Poczekaj 5 sekund. |
| `nie znaleziono obiektu` | Ścieżka różni się od tej w **Debug → Registry**, albo moduł DOUT8T nie został jeszcze dodany lub wysłany do OM. |
| Błąd `gmail token: invalid_grant` | Refresh token wygasł lub został cofnięty. Sprawdź tryb **In production** (krok 4.3) i wygeneruj token od nowa (4.5). |
| Google: `Błąd 403: access_denied` ("aplikacja nie przeszła weryfikacji") | Aplikacja jest w trybie **Testing**, a konto, którym się logujesz, nie jest na liście **Test users**. Najprościej: w [**Audience**](https://console.cloud.google.com/auth/audience) kliknij **Publish app** (tryb **In production**) i potwierdź. Przy logowaniu wybierz **Advanced → Go to ... (unsafe)**. Alternatywa: dodaj dokładnie ten adres Gmail do **Test users**, ale token wygaśnie po 7 dniach. |
| Google: `Błąd 400: redirect_uri_mismatch` w OAuth Playground | Klient musi być typu **Web application** z adresem `https://developers.google.com/oauthplayground` w **Authorized redirect URIs** (krok 4.4). Po poprawce odczekaj kilka minut. |
| Błąd `gmail token: invalid_client` | `clientId` lub `clientSecret` wpisane z błędem (np. dodatkowa spacja). |
| W logu: `registry overflow` przy czytaniu maili | Błąd starszej wersji pluginu (0.1.0). Zaktualizuj plugin do 0.1.1 lub nowszej (Plugins → Installed → Update, albo odinstaluj i zainstaluj ponownie) i kliknij **Reload Lua Runtime**. |
| Plugin nie znajduje paczek z maili | Zmień `query` (5.5): sprawdź nadawcę maili InPost w swojej skrzynce. |
| Impulsy działają w vCLU, ale OM nic nie robi | Zapisz projekt OM i wyślij go ponownie do kontrolera. Sprawdź, czy zdarzenie jest przypisane do właściwego wyjścia. |
| vCLU nie widać w Object Managerze | Ta sama sieć, UDP 1234 odblokowany, brak osobnych VLAN-ów. |

## 10. Zaawansowane (opcjonalnie)

- Numer paczki możesz dodać ręcznie, publikując go na wbudowanym brokerze MQTT vCLU
  w temacie `vclu/inpost/paczki/add` (treść to sam numer).
- Co ile sekund sprawdzany jest status paczek: `interval` w `inpost:create({...})` (domyślnie 600,
  minimum 60). Częstotliwość czytania Gmaila: `interval` w sekcji `GMAIL` (domyślnie 300).
