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
  write_file "$TOGGLES/touchpad-disabled-name" '") os.execute("touch '"$SCRATCH"'/ran") --'
  run hypr 'require("default.hypr.toggles")'
  [ "$status" -eq 0 ]
  [ "$output" = 'device {enabled=false,name=") os.execute("touch '"$SCRATCH"'/ran") --}' ]
  [ ! -e "$SCRATCH/ran" ]
}

@test "toggles come from XDG_STATE_HOME when it is set, where Nova's tools write them" {
  write_file "$SCRATCH/elsewhere/nova/toggles/hypr/window-no-gaps.lua" 'hl.config({ general = { gaps_in = 0 } })'
  write_file "$TOGGLES/window-no-gaps.lua" 'hl.config({ general = { gaps_in = 8 } })'
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
  [ "${lines[1]}" = "bind B nova-launch -- app {}" ]
  [ "${lines[2]}" = "bind C nova-launch-or-focus '^it\$' 'nova-launch -- it'\\''s' {}" ]
  [ "${lines[3]}" = "bind D nova-launch-tui 'btop' {}" ]
  [ "${lines[4]}" = "bind E nova-launch-or-focus-tui 'btop' {}" ]
}

@test "SUPER + C, V and X: the shortcut pressed, let go 50 ms later; Insert's in a terminal" {
  run hypr '
    hl.dsp.send_key_state = function(k) return "key " .. k.mods .. "+" .. k.key .. " " .. k.state end
    hl.dispatch = function(what) print(what) end
    hl.timer = function(f, when) print("after " .. when.timeout .. " " .. when.type) f() end
    local keys, active = {}, nil
    hl.bind = function(combo, action) keys[combo] = action end
    hl.get_active_window = function() return active end
    require("default.hypr.lib")
    require("default.hypr.keys.clipboard")
    for _, window in ipairs({ false, { tags = { "browser" } }, { tags = { "terminal*" } }, { tags = { "terminal" } } }) do
      active = window or nil
      for _, combo in ipairs({ "SUPER + C", "SUPER + V", "SUPER + X" }) do keys[combo]() end
    end
    print(keys["SUPER + CTRL + V"])'
  [ "$status" -eq 0 ]
  plain=$'key CTRL+C down\nafter 50 oneshot\nkey CTRL+C up\nkey CTRL+V down\nafter 50 oneshot\nkey CTRL+V up\nkey CTRL+X down\nafter 50 oneshot\nkey CTRL+X up'
  terminal=$'key CTRL+Insert down\nafter 50 oneshot\nkey CTRL+Insert up\nkey SHIFT+Insert down\nafter 50 oneshot\nkey SHIFT+Insert up\nkey CTRL+X down\nafter 50 oneshot\nkey CTRL+X up'
  [ "$output" = "$plain"$'\n'"$plain"$'\n'"$terminal"$'\n'"$terminal"$'\nnova-shell shell toggle nova.clipboard' ]
}

# PRINT goes to the shell's screen picker, which freezes the screen as the key
# goes down; without the shell's backgrounds on screen (it is restarting, or
# stopped), to the command, which picks with slurp.
@test "PRINT is the shell's while it is there, and the command's without it" {
  run hypr '
    local keys, layers = {}, {}
    hl.bind = function(combo, action) keys[combo] = action end
    hl.dsp.global = function(name) return "global " .. name end
    hl.get_layers = function(filter)
      local found = {}
      for _, layer in ipairs(layers) do
        if layer.namespace == filter.namespace then found[#found + 1] = layer end
      end
      return found
    end
    require("default.hypr.lib")
    require("default.hypr.keys.desktop")
    keys["PRINT"]()
    layers = { { namespace = "nova-background", mapped = false } }
    keys["PRINT"]()
    layers = { { namespace = "nova-bar", mapped = true }, { namespace = "nova-background", mapped = true } }
    keys["PRINT"]()'
  [ "$status" -eq 0 ]
  [ "$(grep -e '^dispatch' <<<"$output")" = $'dispatch nova-capture-screenshot\ndispatch nova-capture-screenshot\ndispatch global nova:screenshot' ]
}

@test "o is nova, for configs written before it was named" {
  run hypr 'require("default.hypr.lib") print(o == nova)'
  [ "$output" = "true" ]
}

# input.lua: three fingers sideways switch workspaces with Hyprland's own
# swipe, which follows the fingers (a Lua function would run only once they
# lift), and it stops at the last workspace rather than making one. Four
# fingers do nothing, and the direction is Hyprland's, the Mac's.
@test "three fingers sideways swipe between workspaces, and no new one is made past the last" {
  run hypr 'require("default.hypr.lib") require("default.hypr.input")'
  [ "$status" -eq 0 ]
  [ "$(grep '^gesture ' <<<"$output")" = "gesture {action=workspace,direction=horizontal,fingers=3}" ]
  [[ $output == *"gestures={workspace_swipe_create_new=false}"* ]]
  [[ $output != *workspace_swipe_invert* ]]
}

# rules.lua: the shell's windows float in the middle, by their class alone:
# Quick Look and the Calculator size themselves (to what Quick Look shows, to
# the Calculator's keys), and the file picker is titled as the app asks, so
# the rule names no title and gives no size, the floating-window tag's
# 875x600 included.
@test "the shell's windows float in the middle of the screen at the size they ask for" {
  run hypr 'require("default.hypr.lib") require("default.hypr.rules")'
  [ "$status" -eq 0 ]
  rule=$(grep -F 'org\.quickshell' <<<"$output")
  [ "$(wc -l <<<"$rule")" -eq 1 ]
  [[ $rule == *'center=true,float=true,match={class=^org\.quickshell$}'* ]]
  [[ $rule != *title=* && $rule != *size=* && $rule != *floating-window* ]]
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

# The session's start (autostart.lua), with the displays Hyprland came up with,
# each name:scale or name:scale:off: prints what it sets and runs, in order.
# With SHRINKS set, Hyprland is Nova's, which has xwayland.scale.
session_start() { # display...
  DISPLAYS="$*" HOME=$SCRATCH/home NOVA_PATH=$SCRATCH/nova lua -e '
    local displays = {}
    for word in os.getenv("DISPLAYS"):gmatch("%S+") do
      local name, scale, off = word:match("^([^:]+):([^:]+):?(.*)$")
      displays[#displays + 1] = { name = name, scale = tonumber(scale), enabled = off ~= "off" }
    end
    local start
    hl = {
      on = function(event, callback) if event == "hyprland.start" then start = callback end end,
      get_monitors = function()
        if os.getenv("BROKEN") then error("no monitors today") end
        return displays
      end,
      get_config = function(key)
        if key == "xwayland.scale" and os.getenv("SHRINKS") then return 0 end
      end,
      config = function(values) print("config xwayland.scale=" .. tostring(values.xwayland.scale)) end,
      env = function(name, value) print("env " .. name .. "=" .. value) end,
      exec_cmd = function(command) print("exec " .. command) end,
    }
    dofile(os.getenv("NOVA_PATH") .. "/default/hypr/bootstrap.lua")
    require("default.hypr.lib")
    require("default.hypr.autostart")
    start()' </dev/null
}

# Java reads its scale from J2D_UISCALE alone; the other X11 toolkits read the
# X server's, which nova-hyprland-x11-scale tells. GDK_SCALE is not set: GTK
# would take it over the X server's, and draw its text twice as large.
@test "start: Java gets the built-in panel's scale before anything is started with the environment, and GTK no GDK_SCALE" {
  unset GDK_SCALE J2D_UISCALE NOVA_X11_SCALE
  run session_start eDP-1:2 DP-1:1
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "env J2D_UISCALE=2" ]
  [[ ${lines[1]} == "exec systemctl --user import-environment "* ]]
  [ "${lines[3]}" = "exec timeout -k 2 15 nova-theme refresh; exec nova-launch-shell" ]
  [[ $output != *GDK_SCALE* ]]
}

@test "start: the scale is rounded, set only from 2, and the largest display's without a panel on" {
  unset GDK_SCALE J2D_UISCALE NOVA_X11_SCALE
  run session_start eDP-1:1.6
  [ "${lines[0]}" = "env J2D_UISCALE=2" ]
  run session_start eDP-1:1.5 DP-1:3
  [ "${lines[0]}" = "env J2D_UISCALE=2" ]
  run session_start eDP-1:1.25 DP-1:2
  [[ $output != *J2D_UISCALE* ]]
  run session_start DP-1:1 HDMI-A-1:1.5
  [ "${lines[0]}" = "env J2D_UISCALE=2" ]
  run session_start eDP-1:2:off DP-1:1
  [[ $output != *J2D_UISCALE* ]]
  run session_start DP-1:1
  [[ $output != *J2D_UISCALE* ]]
  run session_start
  [[ $output != *J2D_UISCALE* ]]
}

@test "start: NOVA_X11_SCALE is the scale, a J2D_UISCALE or GDK_SCALE of yours is kept, and a failure finding the scale costs nothing else" {
  unset GDK_SCALE J2D_UISCALE
  NOVA_X11_SCALE=3 run session_start eDP-1:2
  [ "${lines[0]}" = "env J2D_UISCALE=3" ]
  NOVA_X11_SCALE=1 run session_start eDP-1:2
  [[ $output != *J2D_UISCALE* ]]
  # Not a whole number from 1 to 9: the displays' then.
  NOVA_X11_SCALE=1.5 run session_start eDP-1:2
  [ "${lines[0]}" = "env J2D_UISCALE=2" ]
  unset NOVA_X11_SCALE
  J2D_UISCALE=1 run session_start eDP-1:2
  [[ $output != *"env J2D_UISCALE"* ]]
  GDK_SCALE=1 run session_start eDP-1:2
  [[ $output != *"env J2D_UISCALE"* ]]
  [[ $output != *"env GDK_SCALE"* ]]
  [[ $output == *"; exec nova-launch-shell"* ]]
  BROKEN=1 run session_start eDP-1:2
  [ "$status" -eq 0 ]
  [[ $output != *"env J2D_UISCALE"* ]]
  [[ $output == *"; exec nova-launch-shell"* ]]
}

# Nova's Hyprland shrinks X11 windows on displays of a lower scale, so they
# draw at the largest display's, rounded up, and Hyprland is told it first.
@test "start: with Nova's Hyprland the scale is the largest display's rounded up, and xwayland.scale is set to it" {
  unset GDK_SCALE J2D_UISCALE NOVA_X11_SCALE
  export SHRINKS=1
  run session_start eDP-1:2 DP-1:1.5
  [ "${lines[0]}" = "config xwayland.scale=2" ]
  [ "${lines[1]}" = "env J2D_UISCALE=2" ]
  run session_start eDP-1:1 DP-1:1.5
  [ "${lines[0]}" = "config xwayland.scale=2" ]
  run session_start eDP-1:1.25
  [ "${lines[0]}" = "config xwayland.scale=2" ]
  run session_start eDP-1:2:off DP-1:3
  [ "${lines[0]}" = "config xwayland.scale=3" ]
  run session_start eDP-1:1 DP-1:1.0000001
  [ "${lines[0]}" = "config xwayland.scale=1" ]
  [[ $output != *J2D_UISCALE* ]]
  run session_start
  [ "${lines[0]}" = "config xwayland.scale=1" ]
  NOVA_X11_SCALE=3 run session_start eDP-1:2
  [ "${lines[0]}" = "config xwayland.scale=3" ]
  # A J2D_UISCALE of yours is Java's alone; a GDK_SCALE of yours leaves X11 to you.
  J2D_UISCALE=1 run session_start eDP-1:2 DP-1:1.5
  [ "${lines[0]}" = "config xwayland.scale=2" ]
  [[ $output != *"env J2D_UISCALE"* ]]
  GDK_SCALE=2 run session_start eDP-1:2 DP-1:1.5
  [[ $output != *xwayland* ]]
  [[ $output != *"env J2D_UISCALE"* ]]
}

# What the session's environment holds reaches the shell and the greeter,
# which have to show at login whatever the desktop portal does. With
# GTK_USE_PORTAL, GTK 3 (Qt's GTK theme starts it in both) waits on the portal
# with no time limit; nova-launch gives it to apps alone. Only comments may
# name it here.
@test "GTK_USE_PORTAL is set nowhere in data/: apps alone get it, from nova-launch" {
  # All of data/: the session's environment also comes from uwsm's env.d,
  # some of it a model's (data/hardware/uwsm).
  run grep -rnE 'GTK_USE_PORTAL' "$REPO_ROOT/data"
  [ -z "$(grep -vE '^[^:]+:[0-9]+:[[:space:]]*(--|#)' <<<"$output")" ]
}

# env.lua: the scale nova-hyprland-x11-scale last chose survives a reload, on
# a Hyprland that has the option.
@test "a reload keeps xwayland.scale from the runtime directory, only on Nova's Hyprland" {
  run_env() {
    XDG_RUNTIME_DIR=$SCRATCH/run HOME=$SCRATCH/home NOVA_PATH=$SCRATCH/nova lua -e '
      hl = setmetatable({
        get_config = function(key) if key == "xwayland.scale" and os.getenv("SHRINKS") then return 0 end end,
        config = function(values)
          if values.xwayland and values.xwayland.scale then print("xwayland.scale=" .. values.xwayland.scale) end
        end,
      }, { __index = function() return function() end end })
      dofile(os.getenv("NOVA_PATH") .. "/default/hypr/bootstrap.lua")
      require("default.hypr.lib")
      require("default.hypr.env")' </dev/null
  }
  mkdir -p "$SCRATCH/run/nova"
  run run_env
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  echo 2 >"$SCRATCH/run/nova/x11-scale"
  SHRINKS=1 run run_env
  [ "$status" -eq 0 ]
  [ "$output" = "xwayland.scale=2" ]
  run run_env
  [ -z "$output" ]
  echo 'nonsense' >"$SCRATCH/run/nova/x11-scale"
  SHRINKS=1 run run_env
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
