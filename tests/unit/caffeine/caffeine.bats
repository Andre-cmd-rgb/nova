#!/usr/bin/env bats

load ../test_helper

# Every outside command is a stub that logs its call; the lid lock is a file
# that systemd-run creates and stopping the unit removes, which is what
# systemd-inhibit --list then reports.
setup() {
  setup_scratch
  export HOME="$SCRATCH/home"
  export XDG_RUNTIME_DIR="$SCRATCH/run"
  export NOVA_PCI_DEVICES_PATH="$SCRATCH/pci"
  export NOVA_CAFFEINE_MODEM="$SCRATCH/modem-helper"
  export CALLS="$SCRATCH/calls" LOCK="$SCRATCH/lock"
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$NOVA_PCI_DEVICES_PATH" "$SCRATCH/bin"
  stub systemd-run 'touch "$LOCK"'
  stub systemd-inhibit '[[ -f $LOCK ]] && echo "nova-caffeine 1000 andre 4242 sleep handle-lid-switch Working block"; true'
  stub systemctl 'case "$*" in *stop*) rm -f "$LOCK" ;; *is-active*) [[ -f $LOCK ]] ;; esac'
  stub pkexec 'echo "$2" >"$NOVA_PCI_DEVICES_PATH/0000:08:00.0/power/control"'
  stub nova-hyprland-monitor-laptop 'echo eDP-1'
  stub nova-hw-external-monitors 'exit 1'
  for name in nova-hw-laptop hyprctl nova-shell nova-system-lid-close nova-hyprland-monitor-clamshell nova-notification-send; do
    stub "$name"
  done
  export PATH="$SCRATCH/bin:$PATH"
  SWITCH=$XDG_RUNTIME_DIR/nova/caffeine
  # shellcheck source=/dev/null
  source "$REPO_ROOT/data/caffeine/nova-caffeine"
}

teardown() { teardown_scratch; }

fails() { if "$@"; then return 1; fi; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

add_modem() { # a modem on mhi-pci-generic, its power/control set to $1
  local d=$NOVA_PCI_DEVICES_PATH/0000:08:00.0
  mkdir -p "$d/power" "$SCRATCH/drivers/mhi-pci-generic"
  ln -s "$SCRATCH/drivers/mhi-pci-generic" "$d/driver"
  echo "$1" >"$d/power/control"
}

@test "on, on a laptop: takes the lid lock, flips the switch, tells the shell, and says so" {
  run main on "Rendering"
  [ "$status" -eq 0 ]
  [[ $output == *"closing the lid only turns it off"* ]]
  armed
  [ "$(cat "$SWITCH")" = Rendering ]
  grep -q -- '--what=handle-lid-switch --who=nova-caffeine --why=Rendering' "$CALLS"
  grep -qx "nova-shell -q idle refresh" "$CALLS"
}

@test "on, on a desktop: only the switch; there is no lid to hold" {
  stub nova-hw-laptop 'exit 1'
  run main on
  [ "$status" -eq 0 ]
  [ "$output" = "Caffeine is on: the screen stays on." ]
  armed
  fails grep -q systemd-run "$CALLS"
  [[ $(main status) == "on: Keeping the screen on" ]]
}

@test "on: a lid lock logind never reports is not on, and is undone" {
  stub systemd-inhibit 'true'
  run main on
  [ "$status" -eq 1 ]
  [[ $output == *"NOT on"* ]]
  [ ! -e "$SWITCH" ]
  fails armed
}

@test "off: the lid lock goes, the panel comes back, the switch flips" {
  main on >/dev/null
  : >"$CALLS"
  run main off
  [ "$status" -eq 0 ]
  [[ $output == "Caffeine is off"* ]]
  fails armed
  [ ! -e "$SWITCH" ]
  [ ! -e "$LOCK" ]
  grep -q 'action = "on", monitor = "eDP-1"' "$CALLS"
  grep -qx "nova-shell -q idle refresh" "$CALLS"
}

@test "the modem is kept awake while on, and given back its own setting" {
  add_modem auto
  main on >/dev/null
  [ "$(cat "$NOVA_PCI_DEVICES_PATH/0000:08:00.0/power/control")" = on ]
  # On twice still remembers auto, not the on of the first.
  main on >/dev/null
  main off >/dev/null
  [ "$(cat "$NOVA_PCI_DEVICES_PATH/0000:08:00.0/power/control")" = auto ]
  grep -qx "pkexec $NOVA_CAFFEINE_MODEM on" "$CALLS"
  [ ! -e "$XDG_RUNTIME_DIR/nova/caffeine-modem" ]
}

@test "without a modem nothing asks for root" {
  main on >/dev/null
  main off >/dev/null
  fails grep -q pkexec "$CALLS"
}

@test "off keeps the modem setting it could not put back, for the next try" {
  add_modem auto
  main on >/dev/null
  stub pkexec 'exit 1'
  run main off
  [ "$status" -eq 1 ]
  [ "$(cat "$XDG_RUNTIME_DIR/nova/caffeine-modem")" = auto ]
  [ ! -e "$SWITCH" ]
}

@test "lid close: off it locks as always, on the panel only goes dark" {
  run main close
  grep -qx "nova-system-lid-close " "$CALLS"
  : >"$CALLS"
  main on >/dev/null
  run main close
  fails grep -q nova-system-lid-close "$CALLS"
  grep -q 'action = "off", monitor = "eDP-1"' "$CALLS"
}

@test "lid close, on and docked: the desktop moves to the external display" {
  main on >/dev/null
  stub nova-hw-external-monitors 'exit 0'
  run main close
  grep -qx "nova-hyprland-monitor-clamshell " "$CALLS"
  fails grep -q 'action = "off"' "$CALLS"
}

@test "lid open: the panel comes back, with a reminder while still on" {
  main open
  fails grep -q nova-notification-send "$CALLS"
  main on >/dev/null
  main open
  grep -q 'action = "on", monitor = "eDP-1"' "$CALLS"
  grep -q "nova-notification-send -u low Caffeine is still on" "$CALLS"
}

@test "reconcile: a switch whose lid lock did not survive a restart is undone" {
  add_modem auto
  main on >/dev/null
  rm -f "$LOCK"
  fails armed
  main reconcile
  [ ! -e "$SWITCH" ]
  [ ! -e "$XDG_RUNTIME_DIR/nova/caffeine-modem" ]
  [ "$(cat "$NOVA_PCI_DEVICES_PATH/0000:08:00.0/power/control")" = auto ]
}

@test "reconcile: Caffeine on, or off, is left alone" {
  main reconcile
  fails grep -q nova-shell "$CALLS"
  main on >/dev/null
  main reconcile
  armed
}

@test "toggle and status" {
  main toggle >/dev/null
  armed
  [[ $(main status) == "on: Keeping the screen on"* ]]
  [[ $(main status) == *"lid inhibitor  held"* ]]
  main toggle >/dev/null
  fails armed
  [[ $(main status) == off* ]]
  run main sideways
  [ "$status" -eq 2 ]
}

@test "the modem helper writes only on or auto, and only to the modem" {
  add_modem auto
  mkdir -p "$NOVA_PCI_DEVICES_PATH/0000:00:02.0/power"
  echo auto >"$NOVA_PCI_DEVICES_PATH/0000:00:02.0/power/control"
  "$REPO_ROOT/data/caffeine/nova-caffeine-modem" on
  [ "$(cat "$NOVA_PCI_DEVICES_PATH/0000:08:00.0/power/control")" = on ]
  [ "$(cat "$NOVA_PCI_DEVICES_PATH/0000:00:02.0/power/control")" = auto ]
  run "$REPO_ROOT/data/caffeine/nova-caffeine-modem" 'on; reboot'
  [ "$status" -eq 2 ]
  rm -rf "$NOVA_PCI_DEVICES_PATH/0000:08:00.0"
  run "$REPO_ROOT/data/caffeine/nova-caffeine-modem" auto
  [ "$status" -eq 1 ]
}
