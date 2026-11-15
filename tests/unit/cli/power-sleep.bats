#!/usr/bin/env bats

# nova power lid, hibernate and button, their root half, and the lid-close
# handler that darkens the panel when a plugged-in lid only locks. logind,
# systemd, pkexec and Hyprland are stubs.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" XDG_CONFIG_HOME="$SCRATCH/config"
  export NOVA_POWER_SLEEP_APPLY="$REPO_ROOT/src/power/bin/nova-power-sleep-apply"
  export NOVA_LID_DROPIN="$SCRATCH/etc/logind.conf.d/20-nova-lid.conf"
  export NOVA_HIBERNATE_DROPIN="$SCRATCH/etc/sleep.conf.d/20-nova-hibernate.conf"
  mkdir -p "$SCRATCH/bin"
  stub pkexec '"$@"'
  stub systemctl
  # logind: the lid's actions and whether it can hibernate, from files.
  stub busctl 'case $* in
  *HandleLidSwitchExternalPower) echo "s \"$(<"$SCRATCH/lid-ac")\"" ;;
  *HandleLidSwitch) echo "s \"$(<"$SCRATCH/lid")\"" ;;
  *CanHibernate) echo "s \"$(<"$SCRATCH/can-hibernate")\"" ;;
esac'
  printf '' >"$SCRATCH/lid-ac"
  echo sleep >"$SCRATCH/lid"
  echo yes >"$SCRATCH/can-hibernate"
  stub systemd-analyze 'cat "$SCRATCH/sleep.conf"'
  printf '# /usr/lib/systemd/sleep.conf.d/10-nova.conf\n[Sleep]\nHibernateDelaySec=2h\nHibernateOnACPower=no\n' >"$SCRATCH/sleep.conf"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

cli() { "$REPO_ROOT/src/cli/bin/nova-power-$1" "${@:2}"; }

@test "lid: what logind does plugged in, as on battery when it says nothing of its own" {
  run cli lid
  [ "$output" = sleep ]
  echo lock >"$SCRATCH/lid-ac"
  run cli lid
  [ "$output" = lock ]
  echo suspend-then-hibernate >"$SCRATCH/lid-ac"
  run cli lid
  [ "$output" = sleep ]
  echo ignore >"$SCRATCH/lid-ac"
  run cli lid
  [ "$output" = ignore ]
}

@test "lid lock: a logind drop-in, logind reloaded; lid sleep takes it away" {
  run cli lid lock
  [ "$status" -eq 0 ]
  grep -qx 'HandleLidSwitchExternalPower=lock' "$NOVA_LID_DROPIN"
  [ "$(stat -c %a "$NOVA_LID_DROPIN")" = 644 ]
  grep -qx "pkexec $NOVA_POWER_SLEEP_APPLY lid lock" "$CALLS"
  grep -qx 'systemctl reload systemd-logind' "$CALLS"
  run cli lid sleep
  [ "$status" -eq 0 ]
  [ ! -e "$NOVA_LID_DROPIN" ]
}

@test "lid takes sleep or lock, nothing else" {
  for bad in ignore poweroff ''; do
    run cli lid "$bad"
    [ "$status" -eq 2 ]
  done
  run cli lid lock now
  [ "$status" -eq 2 ]
  [ ! -e "$NOVA_LID_DROPIN" ]
  fails grep -q pkexec "$CALLS"
}

@test "hibernate: the last word of the merged sleep configuration" {
  run cli hibernate
  [ "$output" = 2h ]
  printf '# /etc/systemd/sleep.conf.d/20-nova-hibernate.conf\n[Sleep]\nHibernateDelaySec=4h\n' >>"$SCRATCH/sleep.conf"
  run cli hibernate
  [ "$output" = 4h ]
  printf '[Sleep]\nAllowSuspendThenHibernate=no\n' >>"$SCRATCH/sleep.conf"
  run cli hibernate
  [ "$output" = never ]
}

@test "hibernate: hours write a drop-in, never another, and Nova's 2h none" {
  run cli hibernate 4h
  [ "$status" -eq 0 ]
  grep -qx 'HibernateDelaySec=4h' "$NOVA_HIBERNATE_DROPIN"
  run cli hibernate never
  grep -qx 'AllowSuspendThenHibernate=no' "$NOVA_HIBERNATE_DROPIN"
  fails grep -q HibernateDelaySec "$NOVA_HIBERNATE_DROPIN"
  run cli hibernate 2h
  [ ! -e "$NOVA_HIBERNATE_DROPIN" ]
  fails grep -q 'systemctl reload' "$CALLS"
}

@test "hibernate takes 1h to 24h or never, and fails where it cannot hibernate" {
  for bad in 0h 25h 1 1.5h 90m forever; do
    run cli hibernate "$bad"
    [ "$status" -eq 2 ]
    run "$NOVA_POWER_SLEEP_APPLY" hibernate "$bad"
    [ "$status" -eq 2 ]
  done
  [ ! -e "$NOVA_HIBERNATE_DROPIN" ]
  echo na >"$SCRATCH/can-hibernate"
  run cli hibernate
  [ "$status" -eq 1 ]
  run cli hibernate 4h
  [ "$status" -eq 1 ]
  [ ! -e "$NOVA_HIBERNATE_DROPIN" ]
}

@test "button: the menu until sleep or off is chosen, and back" {
  run cli button
  [ "$output" = menu ]
  cli button sleep
  run cli button
  [ "$output" = sleep ]
  cli button off
  run cli button
  [ "$output" = off ]
  cli button menu
  [ ! -e "$XDG_CONFIG_HOME/nova/power-button" ]
  echo nonsense >"$XDG_CONFIG_HOME/nova/power-button"
  run cli button
  [ "$output" = menu ]
  run cli button reboot
  [ "$status" -eq 2 ]
}

@test "button press does what is chosen" {
  stub nova-menu
  stub nova-system-shutdown
  cli button press
  grep -qx 'nova-menu toggle system' "$CALLS"
  cli button sleep
  cli button press
  grep -qx 'systemctl sleep' "$CALLS"
  cli button off
  cli button press
  grep -qx 'nova-system-shutdown ' "$CALLS"
}

# The lid-close handler, its world stubbed: the lid shut, no external display,
# the lock secure, the internal panel eDP-1.
lid_close() {
  stub nova-hw-laptop-closed
  stub nova-hw-external-monitors 'exit 1'
  stub nova-system-lock
  stub nova-hyprland-monitor-clamshell
  stub nova-hyprland-monitor-laptop 'echo eDP-1'
  stub nova-shell 'echo "{\"secure\":true}"'
  stub hyprctl
  stub nova-power-lid "echo $1"
  mkdir -p "$SCRATCH/supply/AC"
  echo Mains >"$SCRATCH/supply/AC/type"
  echo "$2" >"$SCRATCH/supply/AC/online"
  NOVA_POWER_SUPPLY="$SCRATCH/supply" "$REPO_ROOT/src/cli/bin/nova-system-lid-close"
}

@test "lid close, plugged in and set to lock: locked, then the panel dark" {
  lid_close lock 1
  grep -qx 'nova-system-lock ' "$CALLS"
  grep -qx 'hyprctl dispatch hl.dsp.dpms({ action = "off", monitor = "eDP-1" })' "$CALLS"
  [ "$(grep -o '^nova-system-lock\|^nova-shell\|^hyprctl' "$CALLS" | paste -sd ' ')" = "nova-system-lock nova-shell hyprctl" ]
}

@test "lid close that will sleep leaves the panel to the sleep" {
  lid_close lock 0
  grep -qx 'nova-system-lock ' "$CALLS"
  fails grep -q hyprctl "$CALLS"
  : >"$CALLS"
  lid_close sleep 1
  fails grep -q hyprctl "$CALLS"
}
