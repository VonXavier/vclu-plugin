# InPost Paczki

Fabryka obiektów, które śledzą paczki InPost przez publiczne API śledzenia
(ShipX). Nie trzeba klucza ani konta. Plugin pilnuje statusów i wywołuje
zdarzenia, a co z nimi zrobić (Grenton, alarm, powiadomienie), decydujesz w swoim module.

API śledzenia wymaga numeru przesyłki, a InPost nie ma publicznego API, które
samo wykryje paczkę wysłaną na Twój numer. Numer trafia do pluginu na trzy
sposoby: z maili z Gmaila (niżej), przez `track()` / `numbers` w `create` albo
przez MQTT na wbudowanym brokerze vCLU (temat `vclu/inpost/<id>/add`, treść to numer).

## Użycie

Plugin niczego nie ustawia sam: wtyczki nie zmieniają obiektów vCLU. Wskaźnik
robisz w swoim module (`user.lua` albo `modules/`), tak jak w pluginie RCE:

```lua
local inpost = Plugin.getPlugin("@vonxavier/inpost")

local paczki = inpost:create({
    id = "paczki",
    numbers = { "520000000000000000000000" },
})

-- ile paczek czeka w paczkomacie
local czeka = VirtualNumber:new("paczki_czeka")
local function odswiez() czeka:setValue(paczki:readyCount()) end
paczki:on("ready", odswiez)
paczki:on("delivered", odswiez)
odswiez()   -- po restarcie stan z KV jest już po create(), przed on()

-- nowa paczka: pierwszy status, jaki widzimy
paczki:on("new", function(p)
    print("Nowa paczka " .. p.number .. ": " .. p.label)
end)

-- kolejna paczka w locie
paczki:track("520000000000000000000001")
```

Żeby wskaźnik był widoczny w Grentonie, wystaw go przez `expose()` albo ustaw
wolny DOUT z modułu wirtualnego w `onChange`/zdarzeniu, jak w moście z
innymi pluginami (`dout:setValue(...)` w callbacku `on()`). Nazwy obiektów
w przykładach są przykładowe.

## Numery z Gmaila

Plugin co kilka minut szuka w Gmailu maili od InPost, wyciąga z nich 24-cyfrowe
numery przesyłek i zaczyna je śledzić. Czyta pocztę tylko do odczytu
(`gmail.readonly`), a id przetworzonych maili trzyma w KV, żeby nie czytać ich drugi raz.

```lua
local paczki = inpost:create({
    id = "paczki",
    gmail = {
        clientId = "....apps.googleusercontent.com",
        clientSecret = "...",
        refreshToken = "...",
        query = "from:inpost.pl newer_than:3d",  -- opcjonalnie
        interval = 300,                           -- opcjonalnie, sekundy
    },
})
```

Maile ze sklepów, które podają numer InPost, złapiesz własnym `query`, np.
`from:(inpost.pl OR sklep.pl) newer_than:3d`. Paczki już doręczone, o których
są stare maile z ostatnich dni, ogłoszą `new` i zaraz `delivered`, więc na początek
zawęź `newer_than`.

### Jednorazowa konfiguracja Google

1. W [Google Cloud Console](https://console.cloud.google.com) utwórz projekt i włącz **Gmail API**.
2. **Ekran zgody OAuth**: typ *External*, dodaj siebie jako użytkownika testowego.
   Potem przełącz aplikację na **In production**. Aplikacja w trybie *Testing*
   dostaje refresh token ważny tylko 7 dni, a w trybie produkcyjnym do użytku
   osobistego wystarczy kliknąć „Advanced → Go to app" przy zgodzie.
3. **Dane logowania → Utwórz → Identyfikator klienta OAuth**, typ *Aplikacja
   komputerowa*. Skopiuj `clientId` i `clientSecret`.
4. Refresh token wygenerujesz w [OAuth Playground](https://developers.google.com/oauthplayground):
   w ustawieniach (ikona koła zębatego) zaznacz *Use your own OAuth credentials*
   i wklej swoje dane, w kroku 1 wybierz zakres
   `https://www.googleapis.com/auth/gmail.readonly`, zaloguj się,
   a w kroku 2 kliknij *Exchange authorization code for tokens*.
   Skopiuj `refresh_token`.

Dane trzymaj w `modules/`, nie w repozytorium.

## Zdarzenia

| Zdarzenie | Kiedy | Argumenty |
|---|---|---|
| `new` | śledzona paczka dostała pierwszy status | `parcel` |
| `status` | status się zmienił | `parcel`, `previous` |
| `ready` | status `ready_to_pickup` | `parcel` |
| `delivered` | status `delivered` | `parcel` |

`parcel` to `{ number, status, label, machine }`. `on()` zwraca funkcję
wyrejestrowującą callback.

## API

| Metoda | Opis |
|---|---|
| `track(numer)`, `untrack(numer)` | dodaje albo usuwa paczkę; `false` dla pustego albo powtórzonego numeru |
| `on(event, fn)` | zdarzenia j.w. |
| `count()`, `readyCount()` | ile paczek śledzimy, ile czeka na odbiór |
| `list()`, `getState()` | lista paczek i stan |
| `sensor()` | sensor z liczbą paczek do odbioru (`<id>_ready`), do `expose()` |
| `refresh()`, `refreshMail()` | odpytuje InPost albo Gmaila od razu |

Opcje `create`: `id` (domyślnie `"inpost"`), `numbers`, `interval` w sekundach
(domyślnie 600, minimum 60), `polling` (`false` wyłącza pobieranie, do testów),
`gmail` (patrz wyżej).

## Publikacja w repozytorium

Wpis do `plugins.json` (obok pozostałych pluginów w repo, id bez namespace,
tak jak w repo autora):

```json
{
  "id": "inpost",
  "name": "InPost Paczki",
  "version": "0.1.0",
  "description": "Powiadomienia o paczkach InPost: nowa, gotowa do odbioru, doręczona",
  "author": "vonxavier",
  "path": "plugins/inpost",
  "tags": ["inpost", "parcels", "factory"],
  "requires": { "vclu": ">=1.0.0" },
  "tag": "inpost-v0.1.0"
}
```

## Jak to działa

- Co `interval` plugin pyta o każdą śledzoną paczkę.
- Numery i ostatnie statusy leżą w KV wtyczki, więc po restarcie vCLU nie ogłasza
  drugi raz tego, co już było.
- Paczka w statusie końcowym (doręczona, zwrot, anulowana) znika z listy przy
  następnym obiegu.
