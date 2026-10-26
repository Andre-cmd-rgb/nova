#!/usr/bin/env bats

# The Hyprland half of a hardware profile (data/hypr/hardware/), with the
# window rules it changes, against a stand-in for Hyprland's Lua API that
# records what the config asks for.

load ../test_helper

setup() {
  setup_scratch
  mkdir -p "$SCRATCH/nova/default"
  ln -s "$REPO_ROOT/data/hypr" "$SCRATCH/nova/default/hypr"
}

teardown() { teardown_scratch; }

# Runs Nova's helpers, a profile (or none), then its window rules, as nova.lua
# does; prints the last opacity rule and the render options: Hyprland applies
# a window's matching rules in order, so the last opacity rule that matches
# every window is the one each window has.
rules() { # [profile]
  NOVA_PATH=$SCRATCH/nova HOME=$SCRATCH PROFILE=${1:-} lua -e '
    package.path = os.getenv("NOVA_PATH") .. "/?.lua;" .. package.path
    local opacity, render = "none", {}
    hl = {
      window_rule = function(rule)
        if rule.opacity then opacity = rule.opacity .. " for " .. (rule.match.class or rule.match.tag or "?") end
      end,
      config = function(c) for k, v in pairs(c.render or {}) do render[k] = v end end,
      layer_rule = function() end, bind = function() end, on = function() end, env = function() end,
      monitor = function() end, exec_cmd = function() end, dsp = { exec_cmd = function() end },
    }
    require("default.hypr.helpers")
    if os.getenv("PROFILE") ~= "" then require("default.hypr.hardware." .. os.getenv("PROFILE")) end
    require("default.hypr.windows")
    print("opacity " .. opacity)
    local names = {}
    for k, v in pairs(render) do names[#names + 1] = k .. "=" .. tostring(v) end
    table.sort(names)
    print("render " .. table.concat(names, " "))' </dev/null
}

@test "hypr: windows are a little see-through on a machine with no profile" {
  run rules
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "opacity 0.985 0.96 for default-opacity" ]
  [ "${lines[1]}" = "render " ]
}

@test "hypr: on a Raspberry Pi 5 every window is opaque, the apps' own opacities too" {
  run rules raspberry-pi-5
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "opacity 1 1 for .*" ]
}

@test "hypr: a Raspberry Pi 5 renders a late frame at once, into a third buffer" {
  run rules raspberry-pi-5
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "render new_render_scheduling=true" ]
}

@test "hypr: the ThinkPad P1 keeps the see-through windows" {
  run rules thinkpad-p1-gen4i
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "opacity 0.985 0.96 for default-opacity" ]
  [ "${lines[1]}" = "render direct_scanout=1" ]
}
