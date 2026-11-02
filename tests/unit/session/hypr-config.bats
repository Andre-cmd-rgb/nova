#!/usr/bin/env bats

# Nova's Hyprland config loader (data/hypr): bootstrap.lua, lib.lua and
# toggles.lua, against a stand-in for Hyprland's Lua API that prints what the
# config asks for.

load ../test_helper

setup() {
  setup_scratch
  mkdir -p "$SCRATCH/nova/default" "$SCRATCH/home/.config/hypr"
  ln -s "$REPO_ROOT/data/hypr" "$SCRATCH/nova/default/hypr"
  TOGGLES=$SCRATCH/home/.local/state/nova/toggles/hypr
  LAYOUTS=$SCRATCH/home/.local/state/nova/workspace-layouts
}

teardown() { teardown_scratch; }

# Runs a Lua chunk after a stand-in hl that prints each call.
hypr() { # lua
  HOME=$SCRATCH/home NOVA_PATH=$SCRATCH/nova lua -e '
    local function show(v)
      if type(v) ~= "table" then return tostring(v) end
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys)
      local parts = {}
      for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. show(v[k]) end
      return "{" .. table.concat(parts, ",") .. "}"
    end
    hl = setmetatable({}, { __index = function(_, name)
      return function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = show((select(i, ...))) end
        print(name .. " " .. table.concat(parts, " "))
        return { unbind = function() print("unbind") end }
      end
    end })
    hl.dsp = { exec_cmd = function(command) return command end }
    dofile(os.getenv("NOVA_PATH") .. "/default/hypr/bootstrap.lua")
  ' -e "$1" </dev/null
}

@test "toggles run in name order, before the workspace layouts" {
  write_file "$TOGGLES/window-no-gaps.lua" 'hl.config({ general = { gaps_in = 0 } })'
  write_file "$TOGGLES/display-settings.lua" 'hl.monitor({ output = "eDP-1" })'
  write_file "$TOGGLES/notes.txt" 'hl.config({ never = true })'
  write_file "$LAYOUTS/2.lua" 'hl.workspace_rule({ workspace = "2", layout = "scrolling" })'
  run hypr 'require("default.hypr.toggles")'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "monitor {output=eDP-1}" ]
  [ "${lines[1]}" = "config {general={gaps_in=0}}" ]
  [ "${lines[2]}" = "workspace_rule {layout=scrolling,workspace=2}" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "a disabled device's name is only ever data" {
  write_file "$TOGGLES/touchpad-disabled-name" 'ELAN067A:00 04F3:3197 Touchpad'
  write_file "$TOGGLES/touchscreen-disabled-name" '") os.execute("touch '"$SCRATCH"'/ran") --'
  run hypr 'require("default.hypr.toggles")'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "device {enabled=false,name=ELAN067A:00 04F3:3197 Touchpad}" ]
  [ "${lines[1]}" = 'device {enabled=false,name=") os.execute("touch '"$SCRATCH"'/ran") --}' ]
  [ ! -e "$SCRATCH/ran" ]
}

@test "toggles come from ~/.local/state, where Nova's tools write them, whatever XDG_STATE_HOME says" {
  write_file "$TOGGLES/window-no-gaps.lua" 'hl.config({ general = { gaps_in = 0 } })'
  XDG_STATE_HOME=$SCRATCH/elsewhere run hypr 'require("default.hypr.toggles")'
  [ "$status" -eq 0 ]
  [ "$output" = "config {general={gaps_in=0}}" ]
}

@test "no toggles, no layouts: nothing, and no error" {
  run hypr 'require("default.hypr.toggles")'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "your modules and Nova's are found, ahead of Lua's own" {
  write_file "$SCRATCH/home/.config/hypr/mine.lua" 'mine = true'
  run hypr '
    require("hypr.mine")
    print(mine, package.searchpath("default.hypr.lib", package.path))'
  [ "$status" -eq 0 ]
  [ "$output" = "true	$SCRATCH/nova/default/hypr/lib.lua" ]
}

@test "nova.bind copies its options, so binds can share one table" {
  run hypr '
    require("default.hypr.lib")
    local shared = { locked = true }
    nova.bind("A", "First", "a", shared)
    nova.bind("B", "Second", "b", shared)
    print(shared.description)'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "bind A a {description=First,locked=true}" ]
  [ "${lines[1]}" = "bind B b {description=Second,locked=true}" ]
  [ "${lines[2]}" = "nil" ]
}

@test "nova.bind's shorthands" {
  run hypr '
    require("default.hypr.lib")
    nova.bind("A", nil, { nova = "browser" })
    nova.bind("B", nil, { launch = "app" })
    nova.bind("C", nil, { launch = "it'"'"'s", focus = "^it$" })
    nova.bind("D", nil, { tui = "btop" })
    nova.bind("E", nil, { tui = "btop", focus = true })'
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "bind A nova-launch-browser {}" ]
  [ "${lines[1]}" = "bind B uwsm-app -- app {}" ]
  [ "${lines[2]}" = "bind C nova-launch-or-focus '^it\$' 'uwsm-app -- it'\\''s' {}" ]
  [ "${lines[3]}" = "bind D nova-launch-tui 'btop' {}" ]
  [ "${lines[4]}" = "bind E nova-launch-or-focus-tui 'btop' {}" ]
}

@test "o is nova, for configs written before it was named" {
  run hypr 'require("default.hypr.lib") print(o == nova)'
  [ "$output" = "true" ]
}

# Escape for dictation and the region picker's keys live while their layer is
# up: slurp opens one per display, and the keys go when the last one closes.
# The closing layer is still listed, unmapped, as its event fires.
@test "keys bound while a layer is up go with the last of its layers" {
  run hypr '
    require("default.hypr.lib")
    local handlers, layers = { ["layer.opened"] = {}, ["layer.closed"] = {} }, {}
    hl.on = function(event, fn) table.insert(handlers[event], fn) end
    hl.get_layers = function(filter)
      local found = {}
      for _, layer in pairs(layers) do
        if layer.namespace == filter.namespace then found[#found + 1] = layer end
      end
      return found
    end
    local function open(address, namespace)
      layers[address] = { address = address, namespace = namespace, mapped = true }
      for _, fn in ipairs(handlers["layer.opened"]) do fn(layers[address]) end
    end
    local function close(address)
      layers[address].mapped = false
      for _, fn in ipairs(handlers["layer.closed"]) do fn(layers[address]) end
      layers[address] = nil
    end
    nova.bind_while_layer("selection", function() return { nova.bind("RETURN", "Pick", "pick") } end)
    open("0x1", "selection")
    open("0x2", "selection")
    open("0x3", "other")
    print("closing")
    close("0x1")
    close("0x3")
    print("closing the last")
    close("0x2")
    print("one closes unseen")
    open("0x4", "selection")
    layers["0x4"] = nil
    open("0x5", "selection")
    close("0x5")'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'bind RETURN pick {description=Pick}\nclosing\nclosing the last\nunbind\none closes unseen\nbind RETURN pick {description=Pick}\nunbind')" ]
}
