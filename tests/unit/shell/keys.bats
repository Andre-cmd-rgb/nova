#!/usr/bin/env bats

# The volume, brightness and keyboard backlight keys are Hyprland global
# shortcuts that the shell's nova.keys service registers: a name bound in
# data/hypr/keys/media.lua that the service does not register is a key that
# does nothing, and Hyprland says so nowhere.

load ../test_helper

# Every bind media.lua makes, one per line: keys, then what it runs (the
# global shortcut's name, or the command), then its options.
binds() {
  HYPR=$REPO_ROOT/data/hypr lua -e '
    hl = {
      dsp = {
        global = function(name) return { global = name } end,
        exec_cmd = function(command) return { command = command } end,
      },
      bind = function(keys, dispatcher, opts)
        local options = {}
        for key in pairs(opts) do if key ~= "description" then options[#options + 1] = key end end
        table.sort(options)
        print(keys .. "\t" .. (dispatcher.global or dispatcher.command) .. "\t" .. table.concat(options, ","))
      end,
    }
    dofile(os.getenv("HYPR") .. "/lib.lua")
    dofile(os.getenv("HYPR") .. "/keys/media.lua")' </dev/null
}

bound() { binds | cut -f2 | sed -n 's/^nova://p' | sort -u; }

registered() {
  awk '/GlobalShortcut \{/ {inside = 1} inside && /appid: "nova"/ {nova = 1}
    inside && /name: "/ {sub(/.*name: "/, ""); sub(/".*/, ""); name = $0}
    inside && /^  \}/ {if (nova) print name; inside = nova = 0; name = ""}' \
    "$REPO_ROOT/src/shell/plugins/services/keys/Service.qml" | sort -u
}

@test "every key bound to the shell is a shortcut the shell registers" {
  [ "$(bound | wc -l)" -eq 14 ]
  [ "$(bound)" = "$(registered)" ]
}

# Volume up, down and mute, brightness up and down, each with Alt, and
# brightness all the way with Shift, and the keyboard backlight's three;
# Shift + Mute switches the output, a command of its own.
shell_keys() {
  binds | grep -E '^((ALT|SHIFT) \+ )?XF86(Audio(RaiseVolume|LowerVolume)|AudioMute|MonBrightness(Up|Down)|KbdBrightness(Up|Down)|KbdLightOnOff)	' |
    grep -v '^SHIFT + XF86AudioMute	'
}

@test "the volume and brightness keys go to the shell, and Hyprland repeats none of them" {
  [ "$(shell_keys | wc -l)" -eq 14 ]
  [ -z "$(shell_keys | cut -f2 | grep -v '^nova:')" ]
  [ -z "$(shell_keys | cut -f3 | grep repeating)" ]
}

@test "every media key works on the lock screen" {
  local all
  all=$(binds | wc -l)
  [ "$all" -gt 14 ]
  [ "$(binds | cut -f3 | grep -cx locked)" -eq "$all" ]
}
