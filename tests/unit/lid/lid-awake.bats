#!/usr/bin/env bats

load ../test_helper

# Every outside command is a stub that logs its call; the lid lock is a file
# that systemd-run creates and stopping the unit removes, which is what
# systemd-inhibit --list then reports.
setup() {
  setup_scratch
  export HOME="$SCRATCH/home"
  export XDG_STATE_HOME="$HOME/.local/state"
  export NOVA_PCI_DEVICES_PATH="$SCRATCH/pci"
  export NOVA_LID_AWAKE_MODEM="$SCRATCH/modem-helper"
  export CALLS="$SCRATCH/calls" LOCK="$SCRATCH/lock"
  mkdir -p "$HOME/.local/state/nova/indicators" "$NOVA_PCI_DEVICES_PATH" "$SCRATCH/bin"
  stub systemd-run 'touch "$LOCK"'
  stub systemd-inhibit '[[ -f $LOCK ]] && echo "nova-lid-awake 1000 andre 4242 sleep handle-lid-switch Working block"; true'
  stub systemctl 'case "$*" in *stop*) rm -f "$LOCK" ;; *is-active*) [[ -f $LOCK ]] ;; esac'
  stub nova-toggle-idle 'case $1 in on) touch "$HOME/.local/state/nova/indicators/stay-awake" ;; off) rm -f "$HOME/.local/state/nova/indicators/stay-awake" ;; esac'
  stub pkexec 'echo "$2" >"$NOVA_PCI_DEVICES_PATH/0000:08:00.0/power/control"'
  stub nova-hyprland-monitor-laptop 'echo eDP-1'
  stub nova-hw-external-monitors 'exit 1'
  for name in hyprctl nova-shell nova-system-lid-close nova-hyprland-monitor-clamshell nova-notification-send; do stub "$name"; done
  export PATH="$SCRATCH/bin:$PATH"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/data/lid/nova-lid-awake"
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

@test "on: takes the lid lock, turns on Stay Awake, and says so only once logind has it" {
  run main on "Rendering"
  [ "$status" -eq 0 ]
  [[ $output == *"only turns the screen off"* ]]
  armed
  [ -f "$HOME/.local/state/nova/indicators/stay-awake" ]
  [ "$(cat "$XDG_STATE_HOME/nova/lid-awake/armed")" = Rendering ]
  grep -q -- '--what=handle-lid-switch --who=nova-lid-awake --why=Rendering' "$CALLS"
}

@test "on: a lock logind never reports is not armed, and is undone" {
  stub systemd-inhibit 'true'
  run main on
  [ "$status" -eq 1 ]
  [[ $output == *"NOT armed"* ]]
  [ ! -e "$XDG_STATE_HOME/nova/lid-awake/armed" ]
  [ ! -e "$HOME/.local/state/nova/indicators/stay-awake" ]
}

@test "off: puts Stay Awake back the way it was" {
  main on >/dev/null
  main off >/dev/null
  fails armed
  [ ! -e "$HOME/.local/state/nova/indicators/stay-awake" ]
  [ ! -e "$LOCK" ]
  # Already on before: left on.
  touch "$HOME/.local/state/nova/indicators/stay-awake"
  main on >/dev/null
  main off >/dev/null
  [ -f "$HOME/.local/state/nova/indicators/stay-awake" ]
}

@test "the modem is kept awake while armed, and given back its own setting" {
  add_modem auto
  main on >/dev/null
  [ "$(cat "$NOVA_PCI_DEVICES_PATH/0000:08:00.0/power/control")" = on ]
  main off >/dev/null
  [ "$(cat "$NOVA_PCI_DEVICES_PATH/0000:08:00.0/power/control")" = auto ]
  grep -qx "pkexec $NOVA_LID_AWAKE_MODEM on" "$CALLS"
}

@test "without a modem nothing asks for root" {
  main on >/dev/null
  main off >/dev/null
  fails grep -q pkexec "$CALLS"
}

@test "lid close: unarmed it locks as always, armed the screen only goes dark" {
  run main close
  grep -qx "nova-system-lid-close " "$CALLS"
  : >"$CALLS"
  main on >/dev/null
  run main close
  fails grep -q nova-system-lid-close "$CALLS"
  grep -q 'action = "off", monitor = "eDP-1"' "$CALLS"
}

@test "lid close, armed and docked: the desktop moves to the external display" {
  main on >/dev/null
  stub nova-hw-external-monitors 'exit 0'
  run main close
  grep -qx "nova-hyprland-monitor-clamshell " "$CALLS"
  fails grep -q 'action = "off"' "$CALLS"
}

@test "lid open: the screen comes back, with a reminder while still armed" {
  main open
  fails grep -q nova-notification-send "$CALLS"
  main on >/dev/null
  main open
  grep -q 'action = "on", monitor = "eDP-1"' "$CALLS"
  grep -q "nova-notification-send -u low Lid awake is still on" "$CALLS"
}

@test "reconcile: a hold that did not survive a restart is undone" {
  main on >/dev/null
  rm -f "$LOCK"
  fails armed
  [ -f "$HOME/.local/state/nova/indicators/stay-awake" ]
  main reconcile
  [ ! -e "$HOME/.local/state/nova/indicators/stay-awake" ]
  [ ! -e "$XDG_STATE_HOME/nova/lid-awake/prev-stay-awake" ]
}

@test "reconcile: a live hold, or none, is left alone" {
  main reconcile
  fails grep -q nova-toggle-idle "$CALLS"
  main on >/dev/null
  main reconcile
  armed
}

@test "release keeps what it could not put back, for the next try" {
  main on >/dev/null
  stub nova-toggle-idle 'exit 1'
  run main off
  [ "$status" -eq 1 ]
  [ -f "$XDG_STATE_HOME/nova/lid-awake/prev-stay-awake" ]
  [ ! -e "$XDG_STATE_HOME/nova/lid-awake/armed" ]
}

@test "toggle and status" {
  main toggle >/dev/null
  armed
  [[ $(main status) == "on: Working with the lid closed"* ]]
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
  "$REPO_ROOT/data/lid/nova-lid-awake-modem" on
  [ "$(cat "$NOVA_PCI_DEVICES_PATH/0000:08:00.0/power/control")" = on ]
  [ "$(cat "$NOVA_PCI_DEVICES_PATH/0000:00:02.0/power/control")" = auto ]
  run "$REPO_ROOT/data/lid/nova-lid-awake-modem" 'on; reboot'
  [ "$status" -eq 2 ]
  rm -rf "$NOVA_PCI_DEVICES_PATH/0000:08:00.0"
  run "$REPO_ROOT/data/lid/nova-lid-awake-modem" auto
  [ "$status" -eq 1 ]
}
