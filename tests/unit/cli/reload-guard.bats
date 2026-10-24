#!/usr/bin/env bats

# nova-hyprland-reload-guard and the pacman hooks around it: during an update
# every running Hyprland stops reloading its config, then reloads once with
# the files all in place. hyprctl is a stub; the sessions are directories.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" HYPRCTL="$SCRATCH/hyprctl"
  export NOVA_HYPRLAND_RELOAD_GUARD_RUN_ROOT="$SCRATCH/run"
  export NOVA_HYPRLAND_RELOAD_GUARD_STATE_DIR="$SCRATCH/state"
  # Logs "<runtime dir> <instance> <command...>"; getoption answers from
  # $SCRATCH/options, as a live Hyprland would, and a session named dead
  # answers nothing.
  cat >"$HYPRCTL" <<'EOF'
#!/bin/bash
[[ $2 != dead ]] || { echo "Couldn't connect"; exit 1; }
echo "$XDG_RUNTIME_DIR ${*:2}" >>"$CALLS"
if [[ $3 == -j && $4 == getoption ]]; then
  printf '{"option": "%s", "bool": %s, "set": false}\n' "$5" "$(grep -oP "(?<=^$5=).*" "$SCRATCH/options" || echo false)"
fi
EOF
  chmod +x "$HYPRCTL"
  : >"$SCRATCH/options"
  mkdir -p "$SCRATCH/run/1000/hypr/abc_1"
}

teardown() { teardown_scratch; }

guard() { "$REPO_ROOT/src/cli/bin/nova-hyprland-reload-guard" "$@"; }

@test "pause: auto-reload off and errors quiet in every session; resume reloads once and puts them back" {
  mkdir -p "$SCRATCH/run/1001/hypr/def_2"
  guard pause
  grep -qx "$SCRATCH/run/1000 abc_1 eval hl.config({ misc = { disable_autoreload = true }, debug = { suppress_errors = true } })" "$CALLS"
  grep -qx "$SCRATCH/run/1001 def_2 eval hl.config({ misc = { disable_autoreload = true }, debug = { suppress_errors = true } })" "$CALLS"
  guard paused
  : >"$CALLS"
  guard resume
  [ "$(grep -c ' reload$' "$CALLS")" -eq 2 ]
  grep -qx "$SCRATCH/run/1000 abc_1 eval hl.config({ misc = { disable_autoreload = false }, debug = { suppress_errors = false } })" "$CALLS"
  # The reload comes before auto-reload is back, so it is the only one.
  [ "$(grep '^[^ ]*/1000 ' "$CALLS" | grep -o 'reload$\|disable_autoreload = false' | paste -sd' ')" = "reload disable_autoreload = false" ]
  fails guard paused
  [ ! -e "$NOVA_HYPRLAND_RELOAD_GUARD_STATE_DIR" ]
}

@test "a second pause keeps what the session had before the first" {
  echo 'debug.suppress_errors=true' >"$SCRATCH/options"
  guard pause
  echo 'misc.disable_autoreload=true' >>"$SCRATCH/options"
  guard pause
  : >"$CALLS"
  guard resume
  grep -qx "$SCRATCH/run/1000 abc_1 eval hl.config({ misc = { disable_autoreload = false }, debug = { suppress_errors = true } })" "$CALLS"
}

@test "a session that is gone is passed over, and resume with nothing paused does nothing" {
  mkdir -p "$SCRATCH/run/1000/hypr/dead"
  guard pause
  [ -e "$NOVA_HYPRLAND_RELOAD_GUARD_STATE_DIR/abc_1" ]
  [ ! -e "$NOVA_HYPRLAND_RELOAD_GUARD_STATE_DIR/dead" ]
  guard resume
  : >"$CALLS"
  guard resume
  [ ! -s "$CALLS" ]
}

hook() { sed -n "s/^$2 = //p" "$REPO_ROOT/data/hypr/hooks/$1"; }

@test "the hooks: paused before any update to Nova's files, resumed after Nova's other hooks" {
  local name file
  for name in 00-nova-hyprland-pause.hook 99-nova-hyprland-resume.hook; do
    [ "$(hook "$name" Type)" = Path ]
    [ "$(hook "$name" Operation | paste -sd' ')" = "Install Upgrade Remove" ]
    # Hyprland reads the defaults and the themes; alpm's * crosses slashes.
    for file in usr/share/nova/default/hypr/bootstrap.lua usr/share/nova/default/hypr/bindings/utilities.lua \
      usr/share/nova/themes/nord/hyprland.lua; do
      # shellcheck disable=SC2053
      [[ $file == $(hook "$name" Target) ]]
    done
  done
  [ "$(hook 00-nova-hyprland-pause.hook When)" = PreTransaction ]
  [ "$(hook 00-nova-hyprland-pause.hook Exec)" = "/usr/lib/nova/bin/nova-hyprland-reload-guard pause" ]
  [ "$(hook 99-nova-hyprland-resume.hook When)" = PostTransaction ]
  [ "$(hook 99-nova-hyprland-resume.hook Exec)" = "/usr/lib/nova/bin/nova-hyprland-reload-guard resume" ]
  # Last among Nova's hooks, so the reload sees what they wrote.
  [ "$(cd "$REPO_ROOT" && find data -name '*.hook' -printf '%f\n' | sort | tail -1)" = 99-nova-hyprland-resume.hook ]
}
