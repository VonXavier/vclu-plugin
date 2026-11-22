# Auto Dashboard

Po instalacji sam buduje dashboard ze wszystkich obiektów w rejestrze vCLU
(światła, ściemniacze, rolety, czujniki) i udostępnia go w aplikacji vclu na Androida.

## Wymagania
- vCLU sparowany z chmurą (cloud.vclu.pl), konto zalogowane w aplikacji.

## Instalacja
1. Zainstaluj plugin w vCLU (strona Pluginy) albo skopiuj katalog do `plugins/`.
2. Gotowe. Dashboard `auto` pojawia się w aplikacji. Nowe obiekty dochodzą same.

## Konfiguracja (opcjonalna)
Pluginy → Auto Dashboard → zębate koło:
- Nazwa, liczba kolumn, odświeżanie poza domem.
- PIN poza domem (zalecane) i role z chmury.
- Ukrywanie wrażliwych obiektów poza domem (domyślnie włączone: BRAMA, GARAZ, ALARM, ZAMEK, DRZWI).
- `hide` — całkowite ukrycie obiektów, `readonly` — tylko odczyt poza domem.
- Pokazywanie czujników i odczytów.

## Bezpieczeństwo
Domyślnie każdy domownik z dostępem do dashboardu może sterować wszystkim, co
w nim jest. Ustaw `pin` i ukryj wrażliwe obiekty (`hide`).
