# Shelly (vCLU)

Wtyczka do vCLU, która łączy **Shelly Gen2 / Gen3 / Gen4** (np. Plug M Gen3, Plus 1PM, Plus 2PM) z Grentonem.
Działa lokalnie w Twojej sieci, bez chmury Shelly.

Co dostajesz:
- sterowanie włącz / wyłącz z Grentona (tak jak lampy BleBox),
- pomiary: moc (W), energia (Wh), napięcie (V), prąd (A) i temperatura (°C),
- opcjonalnie: pomiary jako **cechy użytkownika** na CLU, do skryptów Grentona i aplikacji myGrenton.

Wersja 0.1.0. Połączenie z Shelly: HTTP (MQTT jest planowane).

---

## Czego potrzebujesz

- [ ] vCLU działające w tej samej sieci co Shelly (ta sama podsieć, np. `192.168.1.x`)
- [ ] Shelly **Gen2 lub nowsze** (Plug M Gen3, Plus, Pro, Mini Gen3 i podobne). Starsze Gen1 (np. Shelly 1, Shelly 2.5) nie działają z tą wersją
- [ ] Shelly podłączone do Wi-Fi i dodane w aplikacji Shelly
- [ ] **Bez hasła** na Shelly (patrz krok 1)
- [ ] Object Manager, jeśli chcesz wysyłać pomiary do Grentona

---

## Krok 1. Przygotuj Shelly

1. Otwórz aplikację **Shelly**, wejdź w swoje urządzenie, potem w **Ustawienia** (ikona zębatki) i **Informacje o urządzeniu**.
2. Zapisz **ID urządzenia**, np. `907069747f40`. To jedyne, czego wtyczka potrzebuje. Adres IP nie jest potrzebny, wtyczka sama znajdzie urządzenie w sieci i śledzi jego zmianę adresu.
3. Sprawdź, że urządzenie **nie ma hasła** (w ustawieniach urządzenia, zakładka z ikoną tarczy). Wtyczka v0.1 nie obsługuje haseł. Jeśli hasło jest, wyłącz je.
4. Opcjonalnie: w zakładce **Sieci** możesz wyłączyć **Chmurę**. Wtyczka jej nie potrzebuje, ale nie musisz tego robić.

---

## Krok 2. Zainstaluj wtyczkę w vCLU

Wtyczka to folder `shelly` z trzema plikami: `plugin.json`, `init.lua` i `README.md`.

1. Wgraj folder `shelly` do katalogu wtyczek vCLU (tam, gdzie masz też `blebox`).
2. Uruchom ponownie vCLU albo przeładuj wtyczki.
3. W panelu vCLU, w **Debug → Logs**, wyszukaj `Shelly`. Powinna być linia `Shelly factory ready`.

---

## Krok 3. Dodaj swoje Shelly

1. W panelu vCLU otwórz **Edytor** i utwórz plik `modules/shelly.lua`.
2. Wklej do niego zawartość pliku `shelly.lua`, który dostałeś razem z wtyczką.
3. Znajdź tabelę `DEVICES` i wpisz swoje dane:

```lua
local DEVICES = {
    {
        deviceId = "907069747f40",     -- ID z aplikacji Shelly (krok 1)
        channel  = 0,                  -- zostaw 0, chyba że Shelly ma kilka przekaźników
        name     = "Gniazdo Shelly",   -- nazwa widoczna w Grentonie
    },
}
```

4. Zapisz plik i kliknij **Reload**.

> Plik `shelly.lua` ładuje się sam, bo leży bezpośrednio w `modules/`. Nie musisz niczego dopisywać do `init.lua`.

### Sprawdź, czy działa

1. W **Debug → Logs** wyszukaj `Shelly`. Za kilka sekund powinna być linia:
   `Shelly 907069747f40 online @ 192.168.1.33`
2. W **Registry** pojawi się obiekt o nazwie, którą wpisałeś w `name`.
3. Przełącz go (z Grentona albo z panelu vCLU). Gniazdo powinno kliknąć, a dioda zmienić kolor.

Jeśli w logach jest `Znaleziono Shelly ...`, ale nie ma `online`, sprawdź, czy `deviceId` jest wpisane tak samo jak w aplikacji.

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

## Kiedy coś nie działa

| Objaw | Co zrobić |
|---|---|
| W logach nie ma `online` | Sprawdź `deviceId` (te same znaki co w aplikacji Shelly), czy Shelly ma Wi-Fi i czy jest w tej samej podsieci co vCLU. Jeśli podsieć jest inna niż `192.168.1`, odkomentuj w `shelly.lua` linię `sh:setSubnet("192.168.0")` i wpisz swoją |
| W logach: `ma wlaczone haslo` | Wyłącz hasło w Shelly (krok 1) |
| `transport ... nieobslugiwany` | Wersja 0.1 obsługuje tylko `http`, usuń opcję `transport` |
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
| `ip` | - | podpowiedź adresu |
| `subnet` | `192.168.1` | podsieć do skanowania (3 pierwsze oktety) |
| `polling`, `pollInterval` | `true`, `2` s | odpytywanie stanu |
| `transport` | `"http"` | v0.1 obsługuje tylko `http` |

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

### Wymagania i ograniczenia v0.1

- Shelly Gen2 lub nowszy (RPC). Gen1 (`/relay/0`) nie jest obsługiwany.
- Urządzenie bez hasła (`auth_en = false`).
- Obsługiwany komponent `switch`. Rolety, światła i wejścia dojdą później.
- Plugin nie zmienia stanu obiektów vCLU, więc most do Grentona robi się w `modules/shelly.lua` (patrz kroki wyżej).
