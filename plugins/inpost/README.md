# BleBox plugin (vCLU) v0.2.0

Fabryka obiektów dla urządzeń BleBox z API `switchBox` (switchBox, switchBoxD) po lokalnym HTTP. Bez chmury i bez zmiany firmware. Działa tak jak `@vclu/tasmota-switch`: plugin nie ma własnej konfiguracji, a urządzenia tworzysz w kodzie przez `create()`. Dzięki temu możesz mieć dowolnie wiele urządzeń.

- znajduje urządzenie po **Identyfikatorze urządzenia** (z aplikacji BleBox), więc adres IP nie jest potrzebny, a zmiana adresu przez DHCP niczego nie psuje,
- jeden obiekt = jeden przekaźnik (switchBoxD ma dwa: `relay = 0` i `relay = 1`),
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

Plugin: `bb:create(opts)`, `bb:setSubnet("192.168.0")`, `bb:scan([subnet])` (ręczny skan, wynik w logu), `bb:getDevices()`, `bb:getDiscovered()`.

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
| `Znaleziono BleBox <id> ...` | Skan znalazł urządzenie. Użyj tego id w `create({ deviceId = ... })`. |

Nie znasz Identyfikatora? Wywołaj w module `bb:scan()` i zajrzyj do logu.

## Zmiany względem 0.1.x

- plugin nie ma już własnej konfiguracji (`subnet`, `bindings`...): urządzenia konfiguruje się w kodzie przez `create()`,
- zniknęły obiekty `status`/`dev_*` i zdarzenie `blebox:changed`: zamiast nich jest `onChange()` na obiekcie,
- most w `modules/` trzeba zastąpić nową wersją z `examples/blebox-bridge.lua`,
- blok `config` dopisany ręcznie w `.vclu.json` można zostawić (jest ignorowany).

## Ograniczenia

- Obsługiwane tylko API typu `switchBox`. Rolety (`shutterBox`), światła (`wLightBox`) i czujniki to kolejne wersje.
- Brak obsługi BleBox z hasłem (Basic Auth).
- Nowe urządzenie trzeba dodać w kodzie (`create()`), plugin nie dodaje ich sam.
