#!/usr/bin/env bats

# nova-system-shutdown, nova-system-reboot and nova-recovery: what holds a shutdown up is
# said before any window closes, and each step hands on the restart. logind,
# systemd and the notifications are stubs.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls"
  mkdir -p "$SCRATCH/bin"
  # What logind holds, from a file: none to start with.
  echo '{"type":"a(ssssuu)","data":[[]]}' >"$SCRATCH/inhibitors"
  # And whether the boot loader can be told to open its menu: it can.
  echo 's "yes"' >"$SCRATCH/menu"
  stub busctl 'if [[ $* == *CanRebootToBootLoaderMenu* ]]; then cat "$SCRATCH/menu"; else cat "$SCRATCH/inhibitors"; fi'
  stub systemd-run
  stub nova-notification-send
  stub nova-hyprland-window-close-all
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

# nova-recovery is the boot's, and finds nova-system-shutdown on the PATH:
# this one's, not one installed.
bin() {
  case $1 in
    nova-recovery)
      ln -sf "$REPO_ROOT/src/cli/bin/nova-system-shutdown" "$SCRATCH/bin/"
      "$REPO_ROOT/data/boot/bin/$1" "${@:2}"
      ;;
    *) "$REPO_ROOT/src/cli/bin/$1" "${@:2}" ;;
  esac
}

@test "nothing holding it up, the rest runs in the user's systemd" {
  run bin nova-system-shutdown
  [ "$status" -eq 0 ]
  grep -q "^systemd-run .*/nova-system-shutdown --inhibit$" "$CALLS"
  fails grep -q nova-notification-send "$CALLS"
}

@test "a restart hands --restart on to the next step" {
  run bin nova-system-reboot
  [ "$status" -eq 0 ]
  grep -q "^systemd-run .*/nova-system-shutdown --restart --inhibit$" "$CALLS"
}

@test "a restart to recovery hands --recovery on, where the boot loader can open its menu" {
  run bin nova-recovery
  [ "$status" -eq 0 ]
  grep -q "^systemd-run .*/nova-system-shutdown --recovery --inhibit$" "$CALLS"
}

@test "a boot loader that cannot open its menu is said before any window closes" {
  echo 's "na"' >"$SCRATCH/menu"
  run bin nova-recovery
  [ "$status" -eq 1 ]
  grep -qx "nova-notification-send -u critical -g 󰁯 The boot menu cannot be opened from here Restart, then press any key in the first second to open it." "$CALLS"
  fails grep -q "systemd-run\|window-close-all" "$CALLS"
}

@test "an update holding shutdowns up is said before any window closes" {
  echo '{"type":"a(ssssuu)","data":[[["handle-lid-switch","nova-caffeine","Keeping the screen on","block",1000,2928],["shutdown","nova update","Installing Nova v1.0.1","block",0,4242],["sleep","Nova","Shutting down","delay",1000,1]]]}' >"$SCRATCH/inhibitors"
  run bin nova-system-reboot
  [ "$status" -eq 1 ]
  grep -qx "nova-notification-send -u critical -g 󰐥 The computer will not restart yet nova update: Installing Nova v1.0.1" "$CALLS"
  fails grep -q "systemd-run\|window-close-all" "$CALLS"
}

@test "an inhibitor that only delays, or holds up something else, holds nothing up" {
  echo '{"type":"a(ssssuu)","data":[[["shutdown:sleep","NetworkManager","Saving state","delay",0,7],["handle-lid-switch","nova-caffeine","Keeping the screen on","block",1000,2928]]]}' >"$SCRATCH/inhibitors"
  run bin nova-system-shutdown
  [ "$status" -eq 0 ]
  grep -q "^systemd-run " "$CALLS"
}

@test "the last step powers off, or restarts" {
  stub nova-osd
  stub systemctl
  stub sleep
  run bin nova-system-shutdown --restart --inhibited
  [ "$status" -eq 0 ]
  grep -qx "systemctl reboot --no-wall" "$CALLS"
  run bin nova-system-shutdown --inhibited
  grep -qx "systemctl poweroff --no-wall" "$CALLS"
  run bin nova-system-shutdown --recovery --inhibited
  grep -qx "systemctl reboot --no-wall --boot-loader-menu=10" "$CALLS"
}
