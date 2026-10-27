#!/usr/bin/env bats

# The volume and brightness keys are Hyprland global shortcuts that the
# shell's nova.keys service registers: a name bound in
# data/hypr/bindings/media.lua that the service does not register is a key
# that does nothing, and Hyprland says so nowhere.

load ../test_helper

bound() {
  grep -oE 'hl\.dsp\.global\("nova:[a-z-]+"\)' "$REPO_ROOT/data/hypr/bindings/media.lua" |
    sed -E 's/.*nova:([a-z-]+).*/\1/' | sort -u
}

registered() {
  awk '/GlobalShortcut \{/ {inside = 1} inside && /appid: "nova"/ {nova = 1}
    inside && /name: "/ {sub(/.*name: "/, ""); sub(/".*/, ""); name = $0}
    inside && /^  \}/ {if (nova) print name; inside = nova = 0; name = ""}' \
    "$REPO_ROOT/src/shell/plugins/services/keys/Service.qml" | sort -u
}

@test "every key bound to the shell is a shortcut the shell registers" {
  [ "$(bound | wc -l)" -eq 11 ]
  [ "$(bound)" = "$(registered)" ]
}

# Volume up, down and mute, brightness up and down, each with Alt, and
# brightness all the way with Shift; Shift + Mute switches the output, a
# command of its own.
shell_keys() {
  grep -E '^o\.bind\("((ALT|SHIFT) \+ )?XF86(Audio(RaiseVolume|LowerVolume)|AudioMute|MonBrightness(Up|Down))"' \
    "$REPO_ROOT/data/hypr/bindings/media.lua" | grep -v '^o\.bind("SHIFT + XF86AudioMute"'
}

@test "the volume and brightness keys go to the shell, which repeats them" {
  [ "$(shell_keys | wc -l)" -eq 11 ]
  [ -z "$(shell_keys | grep -v 'hl\.dsp\.global(')" ]
  [ -z "$(shell_keys | grep 'repeating')" ]
}
