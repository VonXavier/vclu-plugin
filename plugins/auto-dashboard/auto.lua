-- modules/dashboards/auto.lua
-- Automatyczny dashboard: skanuje rejestr vCLU i sam buduje widgety.
-- Dashboard.dynamic przebudowuje definicję przy każdym żądaniu,
-- więc nowe obiekty (np. po imporcie OM) pojawiają się bez przeładowania.
--
-- Użycie w modules/init.lua (PO załadowaniu om.lua):
--   require("dashboards/auto")

local CFG = {
  id       = "auto",
  name     = "Dom (auto)",
  icon     = "house",
  columns  = 3,
  poll     = 2,
  auth     = "public",        -- "public" albo "pin" (dotyczy przeglądarki w sieci domowej)
  pin      = nil,             -- ustaw, gdy auth = "pin" albo remotePin = true

  -- Aplikacja na Androida pokazuje TYLKO dashboardy z :remote()
  remote       = true,
  remotePin    = false,       -- true = poza domem wymagany PIN dashboardu (ustaw też pin)
  remotePoll   = 5,           -- sekundy, min. 2
  roles        = nil,         -- np. "domownicy"
  -- obiekty (wzorce ścieżek), które mają być w aplikacji tylko do odczytu / wcale:
  remoteReadonly = {},
  remoteHidden   = {},        -- np. { "BRAMA", "SERWIS" }
  -- ścieżki (wzorce Lua) do pominięcia:
  exclude  = { "^_", "%.OnSwitch", "%.Event" },
  -- tag -> tytuł sekcji; obiekty bez tagu trafiają do sekcji po CLU
  groupTitle = {},
  statusUnits = {},           -- np. { ["CLU220000592.ONE6305"] = "°C" }
}

local function slug(s) return (tostring(s):gsub("[^%w]", "_")) end

local function excluded(path)
  for _, p in ipairs(CFG.exclude) do
    if path:find(p) then return true end
  end
  return false
end

-- Rozpoznanie rodzaju widgetu po tym, co obiekt potrafi
local function kindOf(o)
  if type(o) ~= "table" then return nil end
  if o.getPosition and o.open and o.close then return "cover" end
  if o.getBrightness or o.setBrightness then return "dimmer" end
  if o.switchOn and o.switchOff then return "toggle" end
  if o.getValue then return "status" end
  return nil
end

local function groupOf(path, o)
  if o.getTags then
    local ok, tags = pcall(function() return o:getTags() end)
    if ok and type(tags) == "table" and tags[1] then
      return CFG.groupTitle[tags[1]] or tags[1]
    end
  end
  return path:match("^([^.]+)") or "Inne"
end

local function collect()
  local groups, order = {}, {}
  for _, e in ipairs(_registry:list()) do
    local path = e.path
    if path and not excluded(path) then
      local o = _registry:get(path)
      local k = kindOf(o)
      if k then
        local g = groupOf(path, o)
        if not groups[g] then groups[g] = {}; order[#order + 1] = g end
        table.insert(groups[g], { path = path, name = e.name or path, obj = o, kind = k })
      end
    end
  end
  table.sort(order)
  for _, g in ipairs(order) do
    table.sort(groups[g], function(a, b) return a.name < b.name end)
  end
  return groups, order
end

local function matches(list, path)
  for _, p in ipairs(list) do
    if path:find(p, 1, true) or path:find(p) then return true end
  end
  return false
end

-- Opcje widgetu: zawężenie dostępu poza domem (opts.remote)
local function optsFor(w)
  if matches(CFG.remoteHidden, w.path) then return { remote = false } end
  if matches(CFG.remoteReadonly, w.path) then return { remote = "readonly" } end
  return nil
end

local function addWidget(s, w)
  local o, id, label = w.obj, "w_" .. slug(w.path), w.name
  local opts = optsFor(w)

  if w.kind == "toggle" then
    s:toggle(id, label, "lightbulb",
      function() return o:getValue() end,
      function(on) if on then o:switchOn() else o:switchOff() end end, opts)

  elseif w.kind == "dimmer" then
    s:dimmer(id, label, "brightness-high", {
      getValue  = function() return o:getValue() end,
      setValue  = function(v) o:setValue(v) end,
      switchOn  = function() o:switchOn() end,
      switchOff = function() o:switchOff() end,
    }, opts)

  elseif w.kind == "cover" then
    s:cover(id, label, "arrows-expand", {
      getPosition = function() return o:getPosition() end,
      open  = function() o:open() end,
      close = function() o:close() end,
      stop  = function() o:stop() end,
    }, opts)

  else -- status (tylko odczyt)
    s:status(id, label, "activity",
      function() return o:getValue() end,
      CFG.statusUnits[w.path] or "", opts)
  end
end

Dashboard.dynamic(CFG.id, function(b)
  b:name(CFG.name):icon(CFG.icon):columns(CFG.columns):poll(CFG.poll):auth(CFG.auth)
  if CFG.pin then b:pin(CFG.pin) end
  if CFG.remote then
    b:remote({ pin = CFG.remotePin, poll = CFG.remotePoll })
    if CFG.roles then b:roles(CFG.roles) end
  end

  local groups, order = collect()
  for _, g in ipairs(order) do
    local s = b:section(g, "grid")
    for _, w in ipairs(groups[g]) do
      local ok, err = pcall(addWidget, s, w)
      if not ok then Logger:warn("auto-dashboard: " .. w.path .. ": " .. tostring(err)) end
    end
  end
end)
