-- The global `nova`: Nova's helpers for its Hyprland config, and for yours in
-- ~/.config/hypr. `o` is the same table, under the name older configs use.
--
--   nova.bind(keys, description, action [, options])
--   nova.window(match, rules)
--   nova.launch(command)            the command as an app of its own
--   nova.launch_on_start(command)   that, once the session has started
--   nova.exec_on_start(command)     the command as is, once the session has started

local function setting(name, default)
  local value = os.getenv(name)
  if value == nil or value == "" then return default end
  return value
end

local home = os.getenv("HOME")

nova = {
  home = home,
  path = setting("NOVA_PATH", "/usr/share/nova"),
  lib = setting("NOVA_LIB", "/usr/lib/nova"),
  -- Nova's tools keep a user's state in ~/.local/state/nova whatever
  -- XDG_STATE_HOME says, so the config reads it from there too.
  state = home .. "/.local/state/nova",
}
o = nova

-- A value as one shell word.
function nova.quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function nova.launch(command)
  return "uwsm-app -- " .. command
end

-- What a key runs, from one of the shorthands nova.bind takes.
local function command(action)
  if type(action) ~= "table" then return action end
  if action.nova then return "nova-launch-" .. action.nova end
  if action.launch then
    if action.focus then
      return "nova-launch-or-focus " .. nova.quote(action.focus) .. " " .. nova.quote(nova.launch(action.launch))
    end
    return nova.launch(action.launch)
  end
  if action.tui then
    return (action.focus and "nova-launch-or-focus-tui " or "nova-launch-tui ") .. nova.quote(action.tui)
  end
  return action
end

-- Binds keys ("SUPER + SHIFT + B") to an action: a dispatcher (hl.dsp.*), a
-- Lua function, a shell command, or a shorthand:
--   { nova = "browser" }               nova-launch-browser
--   { launch = "app" }                 app, as an app of its own
--   { launch = "app", focus = "re" }   the window whose class matches re, else app
--   { tui = "btop" [, focus = true] }  btop in a terminal [or its window, if open]
-- The description is what SUPER + K lists. Returns the bind's handle.
function nova.bind(keys, description, action, options)
  local opts = {}
  for key, value in pairs(options or {}) do opts[key] = value end
  opts.description = description

  local dispatcher = command(action)
  if type(dispatcher) == "string" then dispatcher = hl.dsp.exec_cmd(dispatcher) end
  return hl.bind(keys, dispatcher, opts)
end

-- A key that turns one of Nova's toggles (nova-toggle-<name>) on or off.
function nova.bind_toggle(keys, description, toggle, options)
  return nova.bind(keys, description, "nova-toggle-" .. toggle, options)
end

-- Binds that exist only while a layer of `namespace` is on screen: made by
-- make(), which returns their handles, as the first such layer opens, and
-- removed as the last closes. Removed by handle, since unbinding a key would
-- take a binding of the same key in your config with it.
function nova.bind_while_layer(namespace, make)
  local open, handles = 0, {}
  hl.on("layer.opened", function(layer)
    if layer.namespace ~= namespace then return end
    open = open + 1
    if open == 1 then handles = make() end
  end)
  hl.on("layer.closed", function(layer)
    if layer.namespace ~= namespace or open == 0 then return end
    open = open - 1
    if open == 0 then
      for _, handle in ipairs(handles) do handle:unbind() end
      handles = {}
    end
  end)
end

-- A window rule. `match` is a class pattern, or a table of what to match
-- ({ class = ..., title = ..., tag = ... }).
function nova.window(match, rules)
  local rule = {}
  for key, value in pairs(rules) do rule[key] = value end
  if type(match) == "string" then
    rule.match = { class = match }
  else
    rule.match = {}
    for key, value in pairs(match) do rule.match[key] = value end
  end
  return hl.window_rule(rule)
end

function nova.exec_on_start(command)
  hl.on("hyprland.start", function() hl.exec_cmd(command) end)
end

function nova.launch_on_start(command)
  nova.exec_on_start(nova.launch(command))
end

-- Runs a Lua file when it exists. Errors inside it surface as usual.
function nova.run_if_present(path)
  local file = io.open(path)
  if not file then return end
  file:close()
  dofile(path)
end

-- The *.lua files in each directory, sorted, from one process: Lua cannot list
-- a directory itself. Returns { [directory] = { path, ... } }.
function nova.lua_files(directories)
  local found = {}
  local words = {}
  for _, directory in ipairs(directories) do
    found[directory] = {}
    words[#words + 1] = nova.quote(directory)
  end

  local find = io.popen("exec find " .. table.concat(words, " ") .. " -maxdepth 1 -type f -name '*.lua' 2>/dev/null")
  if find then
    for path in find:lines() do
      local list = found[path:match("^(.*)/[^/]*$")]
      if list then list[#list + 1] = path end
    end
    find:close()
  end

  for _, list in pairs(found) do table.sort(list) end
  return found
end
