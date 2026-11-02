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
    require("default.hypr.lib")
    if os.getenv("PROFILE") ~= "" then require("default.hypr.hardware." .. os.getenv("PROFILE")) end
    require("default.hypr.rules")
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

# Nova runs every display at 8 bits per channel, and HDR needs 10: a display
# switched to HDR by a fullscreen video only showed Hyprland's warning.
@test "hypr: a fullscreen window never switches a display to HDR" {
  BEHAVIOR=$REPO_ROOT/data/hypr/behavior.lua run lua -e '
    local render = {}
    hl = { config = function(c) for k, v in pairs(c.render or {}) do render[k] = v end end }
    dofile(os.getenv("BEHAVIOR"))
    print("cm_auto_hdr=" .. tostring(render.cm_auto_hdr))' </dev/null
  [ "$status" -eq 0 ]
  [ "$output" = "cm_auto_hdr=0" ]
}

# data/hypr/gpu.lua against a fake /sys/bus/pci/devices: one graphics card per
# argument, vendor:device:boot_vga (- for no boot_vga file), and a network card,
# which it must pass over. Prints the four facts.
gpu() { # card...
  local n=0 card dir
  for card in "$@" network; do
    dir=$SCRATCH/sys/bus/pci/devices/0000:0$n:00.0
    mkdir -p "$dir"
    n=$((n + 1))
    if [[ $card == network ]]; then
      printf '0x028000\n' >"$dir/class"; printf '0x8086\n' >"$dir/vendor"; printf '0x2725\n' >"$dir/device"
      continue
    fi
    IFS=: read -r vendor device boot <<<"$card"
    printf '0x030000\n' >"$dir/class"
    printf '%s\n' "$vendor" >"$dir/vendor"
    printf '%s\n' "$device" >"$dir/device"
    if [[ $boot != - ]]; then printf '%s\n' "$boot" >"$dir/boot_vga"; fi
  done
  FAKE=$SCRATCH GPU=$REPO_ROOT/data/hypr/gpu.lua lua -e '
    local fake, open, popen = os.getenv("FAKE"), io.open, io.popen
    io.open = function(path, mode) return open(path:gsub("^/sys/", fake .. "/sys/"), mode) end
    io.popen = function(command, mode) return popen(command:gsub(" /sys/", " " .. fake .. "/sys/"), mode) end
    local gpu = dofile(os.getenv("GPU"))
    print(gpu.nvidia, gpu.gsp, gpu.legacy, gpu.nvidia_display)' </dev/null
}

@test "gpu: the ThinkPad P1, an Ampere card beside the iGPU that drives the display" {
  run gpu 0x8086:0x9a60:1 0x10de:0x25b8:0
  [ "$output" = "true	true	false	false" ]
}

@test "gpu: a desktop whose NVIDIA card drives the display" {
  run gpu 0x10de:0x2684:1
  [ "$output" = "true	true	false	true" ]
}

@test "gpu: a Pascal card is legacy, and a Kepler one neither" {
  run gpu 0x10de:0x1c03:1
  [ "$output" = "true	false	true	true" ]
  rm -rf "$SCRATCH/sys"
  run gpu 0x10de:0x0fc6:1
  [ "$output" = "true	false	false	true" ]
}

@test "gpu: with no card claiming the boot screen, NVIDIA's is taken to drive the display" {
  run gpu 0x8086:0x9a60:- 0x10de:0x25b8:-
  [ "$output" = "true	true	false	true" ]
}

@test "gpu: no NVIDIA card, nothing NVIDIA (an AMD desktop, a Raspberry Pi with no PCI cards)" {
  run gpu 0x1002:0x73bf:1
  [ "$output" = "false	false	false	false" ]
  rm -rf "$SCRATCH/sys"
  run gpu
  [ "$output" = "false	false	false	false" ]
}
