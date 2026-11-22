To moduł w modules/dashboards/, bo tak autor vCLU zaleca trzymać dashboardy, a nie jeszcze plugin w pełnym sensie.

Jak działa

Skanuje _registry:list() i rozpoznaje rodzaj widgetu po tym, co obiekt potrafi:
rolety → cover
ściemniacze → dimmer
wyjścia z switchOn/switchOff → toggle
reszta z getValue → status (tylko odczyt)
Sekcje tworzy według pierwszego tagu obiektu, a bez tagu według CLU.
Używa Dashboard.dynamic, który przebudowuje definicję przy każdym żądaniu. Nowe obiekty po imporcie OM pojawiają się bez przeładowania Lua.
Błąd jednego widgetu trafia do loga i nie psuje reszty.

Instalacja

Wgraj plik do modules/dashboards/auto.lua.
Dodaj require("dashboards/auto") w modules/init.lua, po załadowaniu om.lua.
Dashboard pojawi się pod /d/auto.
