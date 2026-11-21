# Shelly (vCLU)

Wtyczka do vCLU, która łączy **Shelly Gen2 / Gen3 / Gen4** (np. Plug M Gen3, Plus 1PM, Plus 2PM) z Grentonem.
Działa lokalnie w Twojej sieci, bez chmury Shelly.

Co dostajesz:
- sterowanie włącz / wyłącz z Grentona przez wirtualny **DOUT** w vCLU (w Object Managerze wygląda jak zwykły przekaźnik),
- pomiary: moc (W), energia (Wh), napięcie (V), prąd (A) i temperatura (°C),
- opcjonalnie: pomiary jako **cechy użytkownika** na CLU, do skryptów Grentona i aplikacji myGrenton.

Wersja 0.2.0. Połączenie z Shelly: **HTTP** (domyślnie) albo **MQTT** (krok 5).

---

## Czego potrzebujesz

- [ ] vCLU działające w tej samej sieci co Shelly (ta sama podsieć, np. `192.168.1.x`)
- [ ] Shelly **Gen2 lub nowsze** (Plug M Gen3, Plus, Pro, Mini Gen3 i podobne). Starsze Gen1 (np. Shelly 1, Shelly 2.5) nie działają z tą wersją
- [ ] Shelly podłączone do Wi-Fi i dodane w aplikacji Shelly
- [ ] **Bez hasła** na Shelly (patrz krok 1)
- [ ] Wolny **DOUT** w vCLU (tryb *CLU with I/O*), do którego przypiszesz Shelly (krok 3)
- [ ] Object Manager, jeśli chcesz wysyłać pomiary do Grentona

---

## Krok 1. Przygotuj Shelly

1. Otwórz aplikację **Shelly**, wejdź w swoje urządzenie, potem w **Ustawienia** (ikona zębatki) i **Informacje o urządzeniu**.
2. Zapisz **ID urządzenia**, np. `907069747f40`. To jedyne, czego wtyczka potrzebuje. Adres IP nie jest potrzebny, wtyczka sama znajdzie urządzenie w sieci i śledzi jego zmianę adresu.
3. Sprawdź, że urządzenie **nie ma hasła** (w ustawieniach urządzenia, zakładka z ikoną tarczy). Wtyczka nie obsługuje haseł Shelly w połączeniu przez HTTP, więc jeśli hasło jest, wyłącz je.
4. Opcjonalnie: w zakładce **Sieci** możesz wyłączyć **Chmurę**. Wtyczka jej nie potrzebuje, ale nie musisz tego robić.

---

## Krok 2. Zainstaluj wtyczkę w vCLU

Wtyczka to folder `shelly` z trzema plikami: `plugin.json`, `init.lua` i `README.md`.

1. Wgraj folder `shelly` do katalogu wtyczek vCLU (tam, gdzie masz też `blebox`).
2. Uruchom ponownie vCLU albo przeładuj wtyczki.
3. W panelu vCLU, w **Debug → Logs**, wyszukaj `Shelly`. Powinna być linia `Shelly factory ready`.

---

## Krok 3. Dodaj Shelly i przypisz je do Grentona (DOUT)

Grenton widzi urządzenia vCLU jako moduły wejść/wyjść. Żeby gniazdko Shelly było dla Grentona zwykłym przekaźnikiem, przypisujemy je do jednego **lokalnego DOUT** z vCLU. Wtyczka pilnuje obu kierunków: stan Shelly trafia do DOUT, a komenda z Grentona do Shelly.

### 3.1. Wybierz DOUT

DOUT to wirtualne wyjście, które tworzysz w kreatorze vCLU w kroku **Moduły** (np. moduł `RELAY4` ma 4 wyjścia, a `DOUT8T` ma 8). Każdy wolny DOUT możesz przypisać do jednego Shelly.

1. W panelu vCLU otwórz **Registry** i znajdź swoje wyjścia. Mają identyfikator w rodzaju `CLU.DOU5048` oraz nazwę z kreatora, np. `CLU.DOUT8T_1_DOU1`.
2. Zapisz ID wolnego wyjścia. Możesz użyć identyfikatora albo nazwy, obie działają.
3. W Object Managerze ten sam DOUT znajdziesz pod modułem vCLU. To jego będziesz używać w Grentonie (przyciski, sceny, skrypty), tak jak zwykłego przekaźnika.

> Nie masz wolnego DOUT? Dodaj moduł w kreatorze vCLU albo użyj DOUT, którego jeszcze do niczego nie przypisałeś.

### 3.2. Dodaj Shelly w pliku

1. W panelu vCLU otwórz **Edytor** i utwórz plik `modules/shelly.lua`.
2. Wklej do niego zawartość pliku `shelly.lua`, który dostałeś razem z wtyczką.
3. Znajdź tabelę `DEVICES` i wpisz swoje dane:

```lua
local DEVICES = {
    {
        deviceId = "907069747f40",     -- ID z aplikacji Shelly (krok 1)
        channel  = 0,                  -- zostaw 0, chyba że Shelly ma kilka przekaźników
        name     = "Gniazdo Shelly",   -- nazwa
        dout     = "CLU.DOU5048",      -- DOUT z kroku 3.1 (to tutaj wpisujesz przypisanie do Grentona)
    },
}
```

4. Zapisz plik i kliknij **Reload**.

> Plik `shelly.lua` ładuje się sam, bo leży bezpośrednio w `modules/`. Nie musisz niczego dopisywać do `init.lua`.

### 3.3. Sprawdź, czy działa

1. W **Debug → Logs** wyszukaj `Shelly`. Za kilka sekund powinna być linia:
   `Shelly 907069747f40 online @ 192.168.1.33`
2. Wciśnij przycisk na gniazdku Shelly. DOUT w Object Managerze powinien zmienić stan.
3. Przełącz DOUT w Grentonie (z Object Managera albo ze skryptu). Gniazdko powinno kliknąć, a dioda zmienić kolor.

Jeśli komenda do Shelly się nie uda (np. gniazdko jest odłączone), DOUT sam wraca do prawdziwego stanu.

Jeśli w logach jest `Znaleziono Shelly ...`, ale nie ma `online`, sprawdź, czy `deviceId` jest wpisane tak samo jak w aplikacji. Komunikat `nie znaleziono DOUT` oznacza, że ID w polu `dout` nie zgadza się z tym z Registry.

### Home Assistant i HomeKit (opcjonalnie)

`shelly.lua` wywołuje też `expose()`. To wystawia obiekt do **Home Assistant, HomeKit i MQTT**, a nie do Grentona (dla Grentona służy DOUT). Jeśli ich nie używasz, nic nie musisz robić.

---

## Krok 4 (opcjonalny). Pomiary w Grentonie jako cechy użytkownika

Dzięki temu moc, energię i inne pomiary zobaczysz w Object Managerze, w skryptach Grentona i w aplikacji myGrenton.

Zasada jest prosta: w Object Managerze tworzysz na CLU **cechę użytkownika** (zwykłe pole z liczbą), a wtyczka sama wpisuje do niej aktualny pomiar.

### 4.1. Wybierz pomiary

| Pomiar | Nazwa w pliku | Jednostka |
|---|---|---|
| Moc | `moc` | W |
| Energia (licznik całkowity) | `energia` | Wh |
| Napięcie | `napiecie` | V |
| Prąd | `prad` | A |
| Temperatura | `temperatura` | °C |

Na początek wystarczą `moc` i `energia`.

### 4.2. Utwórz cechy w Object Managerze

Dla każdego wybranego pomiaru:

1. W Object Managerze rozwiń swój **CLU**.
2. Otwórz **Cechy użytkownika** i dodaj nową cechę.
3. Wpisz:
   - **nazwa**: `shelly_gniazdo_moc` (początek `shelly_gniazdo` wymyślasz sam, na końcu jest nazwa pomiaru z tabeli),
   - **typ**: `NUMBER`,
   - **wartość początkowa**: `0`.
4. Powtórz dla kolejnych, np. `shelly_gniazdo_energia`.
5. **Wyślij konfigurację do CLU.**

> Nazwa cechy może mieć tylko litery, cyfry i znak `_`. Bez spacji i polskich znaków. Prefiks `shelly_` przypomina, że wartość przychodzi z wtyczki i nie należy jej zmieniać w Grentonie.

### 4.3. Podaj wtyczce numer CLU

1. W panelu vCLU otwórz **Registry** i znajdź numer swojego CLU, np. `CLU221000290`.
2. W pliku `modules/shelly.lua` zmień tę linię na swój numer:

```lua
local CLU = CLU221000290   -- ZMIEN na numer swojego CLU
```

### 4.4. Powiedz, co wysyłać

W tabeli `DEVICES` dopisz dwie linie:

```lua
local DEVICES = {
    {
        deviceId = "907069747f40",
        channel  = 0,
        name     = "Gniazdo Shelly",
        grenton  = "shelly_gniazdo",        -- początek nazwy cech z kroku 4.2
        features = { "moc", "energia" },    -- które pomiary wysyłać
    },
}
```

Wtyczka dokleja `_` i nazwę pomiaru, więc dla powyższego wpisu zapisze do cech `shelly_gniazdo_moc` i `shelly_gniazdo_energia`. Nazwy cech w Object Managerze muszą się z tym zgadzać co do litery.

Zapisz plik i kliknij **Reload**.

### 4.5. Sprawdź

1. Włącz coś w gniazdku, np. czajnik albo lampkę.
2. W Object Managerze odczytaj cechę `shelly_gniazdo_moc` na CLU. Powinna pokazywać pobieraną moc.
3. To samo zobaczysz w aplikacji myGrenton, jeśli dodasz cechę do widżetu.

### Dobrze wiedzieć

- **Kiedy cecha się odświeża:** wtyczka zapisuje pomiary, gdy moc zmieni się o co najmniej 1 W, oraz co 5 minut. Wartości dla napięcia i temperatury też są wysyłane w tych momentach.
- **Skrypty Grentona:** w Object Managerze nie da się podpiąć skryptu pod zmianę cechy. Skrypt przeczyta nową wartość dopiero wtedy, gdy sam się uruchomi (przycisk, zegar). Aplikacja myGrenton pokazuje nową wartość od razu.
- **Po restarcie CLU** cecha wraca do wartości początkowej z Object Managera i zostanie uzupełniona przy następnym zapisie (maksymalnie po 5 minutach).
- **Kilka Shelly:** dopisz kolejny blok w `DEVICES` z innym `grenton`, np. `shelly_pralka`, i utwórz dla niego osobne cechy.
- Nie wysyłasz pomiarów do Grentona? Po prostu pomiń ten krok i nie wpisuj `grenton` ani `features`.

---

## Krok 5 (opcjonalny). Połączenie przez MQTT zamiast HTTP

Domyślnie wtyczka co 2 sekundy pyta Shelly o stan przez HTTP. Przez **MQTT** to Shelly samo wysyła zmiany do brokera, więc:
- zmiany (np. wciśnięcie przycisku na gniazdku) widać od razu, bez odpytywania,
- wtyczka nie musi znać ani szukać adresu IP Shelly,
- jest mniej ruchu w sieci.

Wymaga **brokera MQTT**, do którego podłączone jest vCLU. Shelly musi łączyć się z tym samym brokerem.

### 5.1. Sprawdź, z jakim brokerem łączy się vCLU

1. W panelu vCLU wejdź w **Integracje → MQTT**.
2. Zapisz **adres** i **port** brokera (zwykle `1883`) oraz **login i hasło**, jeśli broker ich wymaga. Status u góry powinien pokazywać, że vCLU jest połączone.

### 5.2. Ustaw MQTT w Shelly

1. W aplikacji **Shelly** otwórz urządzenie, potem **Ustawienia** i zakładkę **Sieci** (ikona globu). Rozwiń **MQTT**.
2. Zaznacz **Włączyć**.
3. W polu z adresem serwera wpisz adres brokera z kroku 5.1 razem z portem, np. `192.168.1.10:1883`.
4. Jeśli broker wymaga logowania, wpisz **nazwę użytkownika** i **hasło**.
5. Zostaw zaznaczone **Powiadomienia o stanie RPC przez MQTT**. Pozostałe pola (identyfikator klienta, prefiks tematu) zostaw domyślne.
6. Kliknij **Zapisz**. Shelly poprosi o **ponowne uruchomienie** urządzenia (w ustawieniach urządzenia jest pozycja **Ponowne uruchomienie**). Wykonaj je.
7. Po restarcie wróć do zakładki MQTT. Czerwony komunikat **Urządzenie jest odłączone** powinien zniknąć.

### 5.3. Przełącz wtyczkę na MQTT

W pliku `modules/shelly.lua` dopisz jedną linię przy urządzeniu:

```lua
    {
        deviceId  = "907069747f40",
        name      = "Gniazdo Shelly",
        transport = "mqtt",           -- tu włączasz MQTT
        dout      = "CLU.DOU5048",
    },
```

Zapisz plik i kliknij **Reload**.

> Zmieniłeś w Shelly prefiks tematu MQTT? Dopisz go w polu `topic`, np. `topic = "moj/prefiks"`. Bez zmiany prefiksu nie wpisuj nic, wtyczka rozpozna urządzenie sama.

### 5.4. Sprawdź

1. W **Debug → Logs** wyszukaj `Shelly`. Powinny pojawić się linie `temat MQTT shellyplugmg3-907069747f40` i `Shelly 907069747f40 online`.
2. Wciśnij przycisk na gniazdku. DOUT w Object Managerze powinien zmienić stan od razu.
3. Przełącz DOUT w Grentonie. Gniazdko powinno kliknąć.

> Nie możesz używać HTTP i MQTT naraz dla tego samego Shelly. Chcesz wrócić do HTTP? Usuń linię `transport` i kliknij **Reload**.

---

## Kiedy coś nie działa

| Objaw | Co zrobić |
|---|---|
| W logach nie ma `online` | Sprawdź `deviceId` (te same znaki co w aplikacji Shelly), czy Shelly ma Wi-Fi i czy jest w tej samej podsieci co vCLU. Jeśli podsieć jest inna niż `192.168.1`, odkomentuj w `shelly.lua` linię `sh:setSubnet("192.168.0")` i wpisz swoją |
| W logach: `ma wlaczone haslo` | Wyłącz hasło w Shelly (krok 1) |
| `nieznany transport` | W polu `transport` wpisz `"http"` albo `"mqtt"` |
| MQTT: w logach nie ma `temat MQTT` | Shelly nie jest połączone z brokerem. Sprawdź w Shelly zakładkę MQTT (adres, port, login, brak komunikatu o odłączeniu) i czy to ten sam broker co w vCLU (**Integracje → MQTT**) |
| MQTT: jest `online`, ale komenda kończy się `timeout` | Sprawdź w Shelly, czy RPC przez MQTT nie zostało wyłączone, i czy broker przepuszcza tematy z prefiksem Shelly |
| MQTT: urządzenie wciąż `offline` po restarcie Shelly | Poczekaj kilkanaście sekund na ponowne połączenie z brokerem. Jeśli to nie pomaga, zrestartuj Shelly jeszcze raz |
| W logach: `nie znaleziono DOUT` | Sprawdź ID w **Registry** i wpisz je w polu `dout` dokładnie tak, jak jest w panelu (np. `CLU.DOU5048`) |
| DOUT w Grentonie nie reaguje na Shelly | Sprawdź, czy w logach Shelly jest `online`, i czy ten sam DOUT nie jest przypisany do innego urządzenia |
| `Znaleziono Shelly` w logach | To dobrze. Skopiuj `deviceId` z tej linii do `DEVICES` |
| Cecha w Object Managerze się nie zmienia | Sprawdź numer CLU w `shelly.lua`, nazwę cechy (litera po literze), czy cecha jest typu `NUMBER` i czy konfiguracja została wysłana do CLU. W logach vCLU szukaj ostrzeżeń `CLU_REMOTE` |
| W logach: `nie ustawiono CLU` | Numer CLU w `local CLU = ...` jest błędny albo CLU nie jest zaimportowane do vCLU |
| Napięcie i temperatura się nie zmieniają | To normalne, są wysyłane przy zmianie mocy lub co 5 minut |

---

## Dla zaawansowanych

### Opcje `create()`

```lua
local sh = Plugin.getPlugin("@vonxavier/shelly")
local gniazdo = sh:create({ deviceId = "907069747f40", channel = 0, name = "Gniazdo" })
```

| opcja | domyślnie | opis |
|---|---|---|
| `deviceId` | - | ID urządzenia (zalecane). Może być też pełne `shellyplugmg3-907069747f40` |
| `channel` | `0` | numer kanału (`switch:N`), np. 0 i 1 w Shelly Plus 2PM |
| `name` | - | nazwa wyświetlana |
| `id` | `shelly_<deviceId>_<channel>` | stały identyfikator dla `expose()` |
| `ip` | - | podpowiedź adresu (tylko transport `http`) |
| `subnet` | `192.168.1` | podsieć do skanowania (3 pierwsze oktety) |
| `polling`, `pollInterval` | `true`, `2` s | odpytywanie stanu (tylko transport `http`) |
| `transport` | `"http"` | `"http"` albo `"mqtt"` |
| `topic` | id Shelly | prefiks tematu MQTT, tylko gdy go zmieniłeś w Shelly (transport `mqtt`) |

### Sterowanie i zdarzenia

```lua
gniazdo:on()
gniazdo:off()
gniazdo:toggle()
gniazdo:onChange(function(new, old) print(new) end)
gniazdo:onMeasure(function(m) print(m.power, m.voltage) end)
```

### Pomiary

`getPower()` (W), `getVoltage()` (V), `getCurrent()` (A), `getFrequency()` (Hz),
`getEnergy()` (Wh, licznik całkowity), `getTemperature()` (°C).

### Funkcje pluginu

`plugin:setSubnet("192.168.0")`, `plugin:scan()`, `plugin:getDevices()`, `plugin:getDiscovered()`.

### Wymagania i ograniczenia v0.2

- Shelly Gen2 lub nowszy (RPC). Gen1 (`/relay/0`) nie jest obsługiwany.
- Transport `http`: urządzenie bez hasła (`auth_en = false`). Transport `mqtt`: broker MQTT wspólny dla vCLU i Shelly.
- Obsługiwany komponent `switch`. Rolety, światła i wejścia dojdą później.
- Plugin sam nie zmienia stanu obiektów vCLU, więc przypisanie do DOUT (most do Grentona) robi się w `modules/shelly.lua` (krok 3).
