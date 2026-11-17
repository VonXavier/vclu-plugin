# BleBox plugin (vCLU) v0.3.0

Fabryka obiektów dla urządzeń BleBox z API `switchBox` (switchBox, switchBoxD) i `gateBox` (sterownik bramy) po lokalnym HTTP. Bez chmury i bez zmiany firmware. Działa tak jak `@vclu/tasmota-switch`: plugin nie ma własnej konfiguracji, a urządzenia tworzysz w kodzie przez `create()`. Dzięki temu możesz mieć dowolnie wiele urządzeń.

- znajduje urządzenie po **Identyfikatorze urządzenia** (z aplikacji BleBox), więc adres IP nie jest potrzebny, a zmiana adresu przez DHCP niczego nie psuje,
- jeden obiekt = jeden przekaźnik (switchBoxD ma dwa: `relay = 0` i `relay = 1`),
- **gateBox**: obiekt bramy z jedną akcją `trigger()` (impuls jak z pilota) i zabezpieczeniami przed przypadkowym otwarciem (patrz niżej),
- stan odświeża co 2 s, a zmiany z aplikacji BleBox trafiają do vclu,
- obiekt działa z `expose()` (HA, HomeKit) i można go połączyć z DOUT-em z Object Managera (most).

## Szybki start

1. **Zainstaluj plugin** z repozytorium w panelu vclu. Konfiguracja nie jest potrzebna (`"config": {}`).
2. **Sprawdź Identyfikator urządzenia** w aplikacji BleBox (Szczegóły, aktualizacja i pomoc → *Identyfikator urządzenia*), np. `ee64c9c7496d`.
3. **Dodaj plik w `modules/`**, np. `blebox-bridge.lua`, z `examples/blebox-bridge.lua` i wpisz swoje urządzenia (nie używaj `user.lua`, bo to plik OM nadpisywany przy synchronizacji).
4. **Przeładuj Lua**. W logu pojawi się `Created: ...`, a po chwili `BleBox <id> online @ <adres>`.

Jeśli Twoja sieć to nie `192.168.1.x`, dodaj w module `bb:setSubnet("192.168.0")` (adres jest potrzebny tylko do znalezienia urządzeń).

## Użycie

```lua
local bb = Plugin.getPlugin("@vonxavier/blebox")

-- jeden przekaźnik (switchBox) albo wybrany przekaźnik switchBoxD
local lampa = bb:create({ deviceId = "ee64c9c7496d", relay = 0, name = "Lampa" })

lampa:on()
lampa:off()
lampa:toggle()
lampa:on(function(ok, err) print(ok) end)   -- opcjonalny callback

if lampa:isOn() then print("włączona") end
lampa:onChange(function(new, old) print(old, "->", new) end)

expose(lampa, "switch", { name = "Lampa" })   -- HA / HomeKit
```

Przy pierwszym odczycie stanu po starcie `onChange` dostaje `old = nil`.

## Most do Object Managera (DOUT)

Plugin nie może sam zmieniać obiektów vclu (zabezpieczenie sandboxa), dlatego most jest w Twoim module. Przykład w `examples/blebox-bridge.lua`:

```lua
bridge(lampa, "CLU221062464->DOU6243")
```

DOUT dodajesz w wizardzie vclu (moduł wirtualny, np. RELAY4) i synchronizujesz z OM. Id kopiujesz z OM, zapis ze strzałką działa. Zmiana DOUT w OM (lub w aplikacji) steruje BleBoxem, a zmiana w BleBoxie ustawia DOUT. Gdy komenda się nie powiedzie, DOUT wraca do prawdziwego stanu.

## Brama (gateBox)

`gateBox` to sterownik bramy lub drzwi, który wysyła **impuls** na wyjście bramy (jak pilot). Obiekt bramy nie ma stanu on/off, ma jedną akcję: `trigger()`.

```lua
local brama = bb:createGate({ deviceId = "aa48fafe697f", name = "Brama" })

brama:trigger()                                  -- jeden impuls (komenda "p")
brama:trigger(function(ok, err) print(ok, err) end)

brama:getPosition()   -- 0 zamknięta, 100 otwarta, 50 pośrednia lub nieznana
brama:isOnline()
brama:onChange(function(new, old) print(old, "->", new) end)
```

**Pozycja bramy:** gateBox zna ją tylko wtedy, gdy ma podłączone krańcówki do wejść IN1 i IN2. Bez nich zawsze zgłasza `50` (nieznana), więc nie traktuj tego jako stanu. Stan bramy możesz brać z osobnego czujnika (np. kontaktron w Zigbee2MQTT).

**Zabezpieczenia** (domyślnie włączone, bo błędny impuls otwiera lub zamyka bramę):

| Zabezpieczenie | Domyślnie | Działanie |
|---|---|---|
| uzbrajanie po starcie (`armDelay`) | 10 s | po utworzeniu obiektu komendy są ignorowane, więc przywrócenie stanu DOUT-a przy starcie vclu nie otworzy bramy |
| odstęp między impulsami (`cooldown`) | 5 s | podwójne kliknięcie nie wyśle drugiego impulsu |
| brak ponowień | zawsze | gdy komenda się nie powiedzie (timeout), nie wiadomo, czy impuls poszedł, więc plugin go nie powtarza. W logu pojawia się ostrzeżenie |
| odmowa przy offline | zawsze | gdy urządzenie nie odpowiada na odpytywanie, impuls nie jest wysyłany |
| jedna komenda naraz | zawsze | dopóki poprzednia trwa, kolejne są odrzucane |

Pominięta komenda jest zapisana w logu (`impuls pominiety (...)`), a `trigger()` zwraca `false` (callback dostaje `false` i powód).

### Most do DOUT dla bramy

W OM brama działa jak przycisk: DOUT z konfiguracją **Signal 0.8 s**. Most reaguje tylko na włączenie DOUT-a (0 → 1), a powrót do 0 po 0.8 s ignoruje, więc jedno naciśnięcie to jeden impuls. Stan do DOUT nie wraca (bramy nie ma jak odczytać).

```lua
local brama = bb:createGate({ deviceId = "aa48fafe697f", name = "Brama" })
bridgeGate(brama, "CLU221062464->DOU0144")
```

Pełny przykład z `bridgeGate()` jest w `examples/blebox-bridge.lua`.

### Opcje `createGate()`

| Opcja | Domyślnie | Opis |
|---|---|---|
| `deviceId` | | Identyfikator urządzenia z aplikacji BleBox (zalecane) |
| `name` | `BleBox gate <id>` | nazwa wyświetlana |
| `id` | `blebox_gate_<deviceId>` | stały identyfikator dla `expose()` |
| `cooldown` | `5` | minimalny odstęp między impulsami (s) |
| `armDelay` | `10` | ile sekund po utworzeniu ignorować komendy |
| `pollInterval` | `5` | odpytywanie pozycji i dostępności (s) |
| `ip`, `subnet`, `polling` | | jak w `create()` |

`expose()` dla bramy wystawia ją na zewnątrz (HA, HomeKit): „włącz” wysyła impuls, „wyłącz” nic nie robi. Używaj tego świadomie, bo to otwieranie bramy spoza vclu.

## Opcje `create()`

| Opcja | Domyślnie | Opis |
|---|---|---|
| `deviceId` | | Identyfikator urządzenia z aplikacji BleBox (zalecane) |
| `relay` | `0` | numer przekaźnika |
| `name` | `BleBox <id> #<relay>` | nazwa wyświetlana |
| `id` | `blebox_<deviceId>_<relay>` | stały identyfikator dla `expose()` (po pierwszym `expose()` nie zmieniaj) |
| `ip` | | podpowiedź adresu. Bez `deviceId` urządzenie nie przetrwa zmiany IP |
| `subnet` | `192.168.1` | podsieć do wyszukiwania dla tego urządzenia |
| `polling` | `true` | odpytywanie stanu |
| `pollInterval` | `2` | interwał w sekundach |

Wymagane jest `deviceId` albo `ip`. `bb:create("ee64c9c7496d")` to skrót dla samego `deviceId`.

## API

Obiekt (jeden przekaźnik): `on([cb])`, `off([cb])`, `toggle([cb])`, `refresh()`, `isOn()`, `isOnline()`, `getValue()`, `getState()`, `getId()`, `getDeviceId()`, `getRelay()`, `onChange(cb)` (zwraca funkcję wyrejestrowującą), `setName()`, `setId()`, `setIp()`, `setPolling(enabled, interval)`. Oraz interfejs `expose()`: `get`, `set`, `switchOn`, `switchOff`, `on_event`.

Obiekt bramy: `trigger([cb])`, `getPosition()`, `isOnline()`, `getState()`, `getId()`, `getDeviceId()`, `refresh()`, `onChange(cb)`, `setName()`, `setId()`, `setIp()`, `setPolling(enabled, interval)`.

Plugin: `bb:create(opts)`, `bb:createGate(opts)`, `bb:setSubnet("192.168.0")`, `bb:scan([subnet])` (ręczny skan, wynik w logu), `bb:getDevices()`, `bb:getDiscovered()`.

## Jak to działa

- Skan podsieci (`GET /api/device/state` po adresach `.1`–`.254`) odpala się tylko wtedy, gdy urządzenie nie ma znanego adresu albo przestało odpowiadać (3 błędy z rzędu). Ostatni adres jest zapamiętany, więc zwykły start jest szybki.
- Co 60 s plugin sprawdza, czy pod adresem nadal jest to samo urządzenie (po id), żeby nie sterować cudzym BleBoxem po zmianie adresu.
- Jedno urządzenie = jedno odpytywanie, niezależnie od liczby przekaźników.

## Sprawdzanie w logu

```
sudo journalctl -u vclu -f | grep -i blebox
```

| Objaw w logu | Przyczyna i rozwiązanie |
|---|---|
| `skipping @vonxavier/blebox: not configured` | Wpis pluginu w `.vclu.json` nie ma bloku `config`. Ta wersja ma `"config": {}` w `plugin.json`, więc po aktualizacji powinno przejść. Jeśli nie, dopisz do wpisu `"config": {}` przy zatrzymanym vclu. |
| `blebox-bridge: plugin @vonxavier/blebox niedostepny` | Plugin nie jest zainstalowany albo został pominięty (wiersz wyżej). |
| `Skan 192.168.1.x (...) zakonczony, znaleziono: 0` | Zła podsieć (`bb:setSubnet(...)`), albo vclu i BleBox są w różnych sieciach. |
| `nie znaleziono DOUT ...` | Nieprawidłowe id DOUT-a. Sprawdź w OM i czy moduł wirtualny jest w wizardzie i zsynchronizowany. |
| `Znaleziono BleBox <id> ...` | Skan znalazł urządzenie. Użyj tego id w `create({ deviceId = ... })` (przełączniki) albo `createGate({ deviceId = ... })` (gateBox). |

Nie znasz Identyfikatora? Wywołaj w module `bb:scan()` i zajrzyj do logu.

## Zmiany w 0.3.0

- obsługa **gateBox**: `bb:createGate()` i obiekt bramy z `trigger()`,
- skan podsieci znajduje teraz też gateBox (`type: gateBox`), nie tylko switchBox,
- zabezpieczenia impulsu: uzbrajanie po starcie, odstęp między impulsami, brak ponowień, odmowa przy offline,
- `examples/blebox-bridge.lua` ma `bridgeGate()` (DOUT jako przycisk, tylko narastające zbocze),
- przełączniki działają jak w 0.2.0 (bez zmian w API).

## Zmiany względem 0.1.x

- plugin nie ma już własnej konfiguracji (`subnet`, `bindings`...): urządzenia konfiguruje się w kodzie przez `create()`,
- zniknęły obiekty `status`/`dev_*` i zdarzenie `blebox:changed`: zamiast nich jest `onChange()` na obiekcie,
- most w `modules/` trzeba zastąpić nową wersją z `examples/blebox-bridge.lua`,
- blok `config` dopisany ręcznie w `.vclu.json` można zostawić (jest ignorowany).

## Ograniczenia

- Obsługiwane API: `switchBox` i `gateBox`. Rolety (`shutterBox`), światła (`wLightBox`) i czujniki to kolejne wersje.
- Brama: tylko komenda „primary” (impuls). Komendy otwórz/zamknij wymagają krańcówek (bez nich urządzenie zwraca błąd 409), więc nie są wystawione.
- Brama: pozycja (`getPosition()`) ma sens tylko z podłączonymi krańcówkami.
- Brak obsługi BleBox z hasłem (Basic Auth).
- Nowe urządzenie trzeba dodać w kodzie (`create()`), plugin nie dodaje ich sam.
