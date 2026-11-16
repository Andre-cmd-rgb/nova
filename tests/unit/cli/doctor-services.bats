#!/usr/bin/env bats

# nova-doctor-services, with systemd and the notifications stubbed: which
# failed units it says, in what words, and that it says each failure once.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" HOME="$SCRATCH/home" XDG_STATE_HOME="$SCRATCH/state"
  export NOVA_BOOT_ID="$SCRATCH/boot_id"
  echo 1111 >"$NOVA_BOOT_ID"
  mkdir -p "$SCRATCH/bin" "$HOME"
  # list-units answers from $SCRATCH/<scope>-failed, a unit a line; show
  # from $SCRATCH/transient (the transient units) and $SCRATCH/invocations
  # ("<unit> <id>").
  stub systemctl 'scope=$1; shift
    case $1 in
      list-units) cat "$SCRATCH/${scope#--}-failed" 2>/dev/null ;;
      show)
        case $2 in
          --property=Transient) if grep -qx -- "${!#}" "$SCRATCH/transient" 2>/dev/null; then echo yes; else echo no; fi ;;
          --property=InvocationID) awk -v u="${!#}" '"'"'$1 == u { print $2 }'"'"' "$SCRATCH/invocations" 2>/dev/null ;;
        esac ;;
    esac'
  stub nova-notification-send
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

failing() { # scope unit...: those units failed, each with an invocation of its own
  local scope=$1 unit
  shift
  for unit; do
    printf '%s loaded failed failed A unit\n' "$unit" >>"$SCRATCH/$scope-failed"
    echo "$unit inv-$unit-$RANDOM" >>"$SCRATCH/invocations"
  done
}

told() { grep -c '^nova-notification-send' "$CALLS" 2>/dev/null || true; }

services() { "$REPO_ROOT/src/cli/bin/nova-doctor-services"; }

@test "nothing failed: nothing said" {
  run services
  [ "$status" -eq 0 ]
  [ "$(told)" = 0 ]
}

@test "a Nova service that failed is said in plain words, with where to look" {
  failing system nova-powerd.service
  run services
  [ "$status" -eq 0 ]
  grep -qx "nova-notification-send -u normal -g 󰀦 Nova's power manager stopped Settings → Updates → Check for Problems has more. --exec nova-shell shell summon nova.settings {\"page\":\"updates\"}" "$CALLS"
}

@test "the same failure is said once, at every run and every login of the boot" {
  failing system nova-powerd.service
  services
  services
  services
  [ "$(told)" = 1 ]
}

@test "the next boot says what still fails, and a new failure of the unit is said again" {
  failing system nova-undervolt.service
  services
  echo 2222 >"$NOVA_BOOT_ID"
  services
  [ "$(told)" = 2 ]
  # Started again, and failed again: another invocation.
  sed -i 's/^nova-undervolt.service .*/nova-undervolt.service inv-again/' "$SCRATCH/invocations"
  services
  [ "$(told)" = 3 ]
}

@test "two at once, the system's and yours, are one notification" {
  failing system nova-powerd.service
  failing user nova-sleep-lock.service
  services
  [ "$(told)" = 1 ]
  grep -q "Nova's power manager and the lock before sleep stopped" "$CALLS"
}

@test "only Nova's own units, and not those that say how they went themselves" {
  failing system NetworkManager-wait-online.service nova-airdrop@1000.service
  failing user nova-update.service nova-caffeine-inhibit.service
  printf '%s\n' nova-update.service nova-caffeine-inhibit.service >"$SCRATCH/transient"
  services
  [ "$(told)" = 0 ]
}

@test "a notification that could not be sent is said at the next run" {
  failing system nova-battery-limit.service
  stub nova-notification-send 'exit 1'
  services
  stub nova-notification-send
  services
  [ "$(told)" = 2 ]
  grep -q "The battery's charge limit stopped" "$CALLS"
  services
  [ "$(told)" = 2 ]
}

@test "a unit Nova has no words for yet is still said" {
  failing user nova-something-new.service
  services
  grep -q "Nova's service nova-something-new stopped" "$CALLS"
}
