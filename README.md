# BleBox plugin (vCLU) v0.1.1

Lokalna obsługa urządzeń BleBox z API `switchBox` (switchBox, switchBoxD, ...). Bez chmury, bez zmiany firmware.

## Co robi

- Skanuje podsieć po HTTP (`GET /api/device/state`) i rozpoznaje urządzenia po polu `type == "switchBox"`.
- **Tożsamość urządzenia = `id`** (np. `ee64c9c7496d`), a nie IP. Ostatni IP jest zapamiętany w KV. Gdy urządzenie przestaje odpowiadać (3 błędy z rzędu), plugin skanuje ponownie i znajduje je pod nowym adresem.
- Liczba przekaźników pochodzi z `GET /api/relay/state`, więc jeden kod obsługuje switchBox i switchBoxD.
- Polling stanu co `interval` sekund, sterowanie przez `POST /api/relay/set`.
- Każdy przekaźnik to `plugin:control` o nazwie `relay_<id>_<n>`.
- Most do OM: przekaźnik <-> wolny DOUT z modułu wirtualnego (wizard vCLU, np. RELAY4).

## Instalacja

1. Skopiuj katalog do `plugins/<namespace>--blebox/` (pliki: `plugin.json`, `init.lua`, `README.md`).
2. Dodaj wpis do `.vclu.json` (id pluginu dostosuj do swojego namespace):

```json
{
  "id": "@twoj-namespace/blebox",
  "version": "0.1.1",
  "enabled": true,
  "config": {
    "subnet": "192.168.1",
    "interval": 2,
    "bindings": "ee64c9c7496d:0=CLU.DOU5048;ee64c9c7496d:1=CLU.DOU4458"
  }
}
```

3. Wolne DOUT-y wybierz z modułu wirtualnego z wizarda (ścieżki `CLU.DOU....` widać w panelu → Urządzenia). Format `bindings`: `id:przekaźnik=ścieżka`, wpisy rozdzielone `;`.

## Konfiguracja

| Klucz | Domyślnie | Opis |
|---|---|---|
| `subnet` | `192.168.1` | trzy pierwsze oktety skanowanej sieci |
| `rangeFrom` / `rangeTo` | `1` / `254` | zakres ostatniego oktetu |
| `hosts` | puste | ręczne IP (po przecinku), sprawdzane przed skanem |
| `interval` | `2` | odpytywanie stanu w sekundach |
| `enableBridge` | `true` | most do DOUT |
| `bindings` | puste | powiązania przekaźnik -> DOUT |
| `rescanCooldown` | `30` | minimalny odstęp między skanami (s) |
| `scanConcurrency` | `10` | równoległe zapytania podczas skanu |

## Użycie w user.lua

```lua
local bb = Plugin.getPlugin("blebox")
if bb and bb:isReady() then
    -- kontrolka przekaźnika 0 urządzenia ee64c9c7496d
    expose(bb:get("relay_ee64c9c7496d_0"), "switch", {name = "Lampka"})

    bb:setRelay("ee64c9c7496d", 0, 1)     -- włącz
    print(bb:getRelay("ee64c9c7496d", 0)) -- stan
end

EventBus:getShared():on("blebox:changed", function(d)
    -- d.id, d.relay, d.state
end)
```

## Plan testów

1. Włącz plugin, w logach powinno być `Skan podsieci ...` i `BleBox ee64c9c7496d (switchBoxD) @ ..., przekazniki: 2`.
2. Przełącz przekaźnik w apce BleBox i sprawdź, czy zmienia się obiekt `plugins.<ns>.blebox.dev_<id>` (do 2 s).
3. Przełącz powiązany DOUT w OM i sprawdź, czy przekaźnik klika.
4. Zmień IP urządzenia (restart routera lub nowa dzierżawa DHCP) i sprawdź, czy plugin odnajduje je sam.

## Znane niewiadome v0.1.1

- **Most do DOUT:** nie wiem, czy sandbox pozwala pluginowi wołać `onChange` i `setValue` na obiektach spoza swojego namespace (rejestr jest do odczytu, ale wywołanie metody to co innego). Jeśli w logach pojawią się błędy, ustaw `enableBridge: false` i zrób most w `user.lua` na podstawie eventu `blebox:changed` i `bb:setRelay()`.
- **Skan:** brak informacji o limitach zapytań HTTP. Jeśli skan zalewa logi błędami, zmniejsz `rangeTo` albo podaj `hosts`.
- **Kolejność ładowania:** jeśli DOUT z `om.lua` nie istnieje w chwili startu pluginu, most podpina się przy kolejnym pollu.
- Obsługiwane tylko API typu `switchBox`. Rolety (`shutterBox`), światła (`wLightBox`) i czujniki to kolejne wersje.
- Nie wspiera BleBox z hasłem (Basic Auth).
