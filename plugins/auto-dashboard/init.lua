-- @vonxavier/auto-dashboard
-- Skanuje rejestr i sam buduje dashboard widoczny w aplikacji vclu (Android).
-- Dashboard.dynamic przebudowuje go przy każdym żądaniu, więc nowe obiekty
-- pojawiają się bez restartu.

local plugin = Plugin:new("auto-dashboard", {
  name = "Auto Dashboard",
  version = "0.2.0",
  description = "Automatyczny dashboard dla aplikacji vclu"
})

local DASH_ID = "auto"
local registered = false

local function split(s)
  local out = {}
  for part in tostring(s or ""):gmatch("[^,]+") do
    part = part:gsub("^%s+", ""):gsub("%s+$", "")
    if part ~= "" then out[#out + 1] = part end
  end
  return out
end

local function hasMatch(list, path)
  for _, p in ipairs(list) do
    if path:find(p, 1, true) then return true end
  end
  return false
end

local function truthy(v, default)
  if v == nil or v == "" then return default end
  return v == true or v == "true" or v == 1 or v == "1"
end

local function slug(s) return (tostring(s):gsub("[^%w]", "_")) end

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
    if ok and type(tags) == "table" and tags[1] then return tags[1] end
  end
  return path:match("^([^.]+)") or "Inne"
end

plugin:onInit(function(config)
  config = config or {}
  local reg = _ or _registry
  if not reg or not Dashboard then
    plugin:log("error", "Brak dostępu do rejestru albo Dashboard w sandboxie pluginu")
    return
  end
  if registered then return end   -- jedna rejestracja na proces
  registered = true

  local sensitive = truthy(config.hideSensitive, true)
                    and split(config.sensitiveWords or "BRAMA,GARAZ,ALARM,ZAMEK,DRZWI") or {}
  local showSensors = truthy(config.showSensors, true)
  local columns = tonumber(config.columns) or 3
  local poll = math.max(2, tonumber(config.poll) or 5)
  local hide     = split(config.hide)
  local readonly = split(config.readonly)
  local title    = (config.title and config.title ~= "") and config.title or "Dom"
  local remote   = truthy(config.remote, true)
  local pin      = (config.pin and config.pin ~= "") and tostring(config.pin) or nil
  local roles    = (config.roles and config.roles ~= "") and config.roles or nil

  local function isSensitive(path, name)
    local hay = (path .. " " .. tostring(name or "")):upper()
    for _, w in ipairs(sensitive) do
      if hay:find(w:upper(), 1, true) then return true end
    end
    return false
  end

  local function collect()
    local groups, order = {}, {}
    for _, e in ipairs(reg:list()) do
      local path = e.path
      if path and path:sub(1, 8) ~= "plugins." and not path:find("^_")
         and not path:find("%.On%u") and not hasMatch(hide, path) then
        local o = reg:get(path)
        local k = kindOf(o)
        if k == "status" and not showSensors then k = nil end
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

  local function addWidget(s, w)
    local o, id, label = w.obj, "w_" .. slug(w.path), w.name
    local opts = nil
    if isSensitive(w.path, w.name) then opts = { remote = false }
    elseif hasMatch(readonly, w.path) then opts = { remote = "readonly" } end
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
    else
      s:status(id, label, "activity", function() return o:getValue() end, "", opts)
    end
  end

  Dashboard.dynamic(DASH_ID, function(b)
    b:name(title):icon("house"):columns(columns):poll(2)
    if pin then b:pin(pin) end
    if remote then
      b:remote({ pin = pin ~= nil, poll = poll })
      if roles then b:roles(roles) end
    end
    local groups, order = collect()
    for _, g in ipairs(order) do
      local s = b:section(g, "grid")
      for _, w in ipairs(groups[g]) do
        local ok, err = pcall(addWidget, s, w)
        if not ok then plugin:log("warn", w.path .. ": " .. tostring(err)) end
      end
    end
  end)

  plugin:log("info", "Dashboard '" .. DASH_ID .. "' zarejestrowany (remote=" .. tostring(remote) .. ")")
end)

plugin:onCleanup(function()
  plugin:log("info", "auto-dashboard zatrzymany")
end)

return plugin
