# BleBox plugin (vCLU) v0.1.1

Lokalna obsługa urządzeń BleBox z API `switchBox` (switchBox, switchBoxD, ...). Bez chmury, bez zmiany firmware.

## Co robi

- Skanuje podsieć po HTTP (`GET /api/device/state`) i rozpoznaje urządzenia po `type == "switchBox"`.
- **Tożsamość urządzenia = `id`** (np. `ee64c9c7496d`), a nie IP. Ostatni IP jest zapamiętany w KV. Gdy urządzenie przestaje odpowiadać (3 błędy z rzędu), plugin skanuje ponownie i znajduje je pod nowym adresem.
- Liczba przekaźników pochodzi z `GET /api/relay/state`, więc jeden kod obsługuje switchBox i switchBoxD.
- Polling stanu co `interval` sekund, sterowanie przez `POST /api/relay/set`.
- Każdy przekaźnik to `plugin:control` o nazwie `relay_<id>_<n>`.
- Zmiany stanu emituje jako zdarzenie `blebox:changed` (`{id, relay, state}`).

Plugin **nie zmienia obiektów vclu** (to celowe zabezpieczenie sandboxa). Połączenie z DOUT w Object Managerze robi się w `user.lua`, patrz niżej.

## Instalacja

1. Dodaj repozytorium z pluginami w vclu (repo musi mieć w katalogu głównym `plugins.json`).
2. Włącz plugin `@vonxavier/blebox` w `.vclu.json`:

```json
{
  "id": "@vonxavier/blebox",
  "version": "0.1.1",
  "enabled": true,
  "config": {
    "subnet": "192.168.1"
  }
}
```

## Konfiguracja

| Klucz | Domyślnie | Opis |
|---|---|---|
| `subnet` | `192.168.1` | trzy pierwsze oktety skanowanej sieci |
| `rangeFrom` / `rangeTo` | `1` / `254` | zakres ostatniego oktetu |
| `hosts` | puste | ręczne IP (po przecinku), sprawdzane przed skanem |
| `interval` | `2` | odpytywanie stanu w sekundach |
| `rescanCooldown` | `30` | minimalny odstęp między skanami (s) |
| `scanConcurrency` | `10` | równoległe zapytania podczas skanu |

## Public API

```lua
local bb = Plugin.getPlugin("@vonxavier/blebox")

bb:isReady()
bb:getRelay("ee64c9c7496d", 0)       -- 0 / 1 albo nil
bb:setRelay("ee64c9c7496d", 0, 1)    -- włącz
bb:rescan()                          -- wymuś skan
bb:refresh()                         -- odpytaj od razu
bb:getData()                         -- wszystkie znane urządzenia
```

Zdarzenie:

```lua
EventBus:getShared():on("blebox:changed", function(d)
    -- d.id, d.relay, d.state
end)
```

## Most do OM (DOUT z modułu wirtualnego)

W wizardzie dodaj moduł wirtualny (np. RELAY4) i wybierz wolne DOUT-y. Potem w `user.lua` użyj przykładu z `examples/blebox-bridge.lua`: zmiana DOUT (Grenton, aplikacja) idzie do BleBoxa przez `bb:setRelay()`, a zdarzenie `blebox:changed` ustawia DOUT.

## Plan testów

1. Włącz plugin, w logach powinno być `Skan podsieci ...` i `BleBox ee64c9c7496d (switchBoxD) @ ..., przekazniki: 2`.
2. Przełącz przekaźnik w apce BleBox i sprawdź, czy zmienia się obiekt `dev_<id>` w rejestrze (do 2 s) i czy przychodzi `blebox:changed`.
3. Dodaj most z `user.lua` i przełącz powiązany DOUT w OM, przekaźnik powinien kliknąć.
4. Zmień IP urządzenia (restart routera lub nowa dzierżawa DHCP) i sprawdź, czy plugin odnajduje je sam.

## Znane ograniczenia v0.1.1

- Obsługiwane tylko API typu `switchBox`. Rolety (`shutterBox`), światła (`wLightBox`) i czujniki to kolejne wersje.
- Brak obsługi BleBox z hasłem (Basic Auth).
- Skan nie ma znanych limitów zapytań HTTP w vclu. Jeśli zalewa logi, zawęź `rangeTo` albo podaj `hosts`.
- Jeśli `user.lua` załaduje się, zanim plugin znajdzie urządzenie, stan początkowy dojdzie przez `blebox:changed` przy pierwszym wykryciu.
