#!/usr/bin/env bats

# nova-chrome-energy-saver: Chrome's Energy Saver on when unplugged, written
# into Local State once per profile, never while Chrome runs, never twice.

load ../test_helper

setup() {
  setup_scratch
  export XDG_STATE_HOME="$SCRATCH/state" NOVA_CHROME_LOCAL_STATE="$SCRATCH/Local State"
  mkdir -p "$SCRATCH/bin"
  # Chrome is running when $SCRATCH/running exists.
  printf '#!/bin/bash\n[[ -e %q ]]\n' "$SCRATCH/running" >"$SCRATCH/bin/pgrep"
  chmod +x "$SCRATCH/bin/pgrep"
  export PATH="$SCRATCH/bin:$PATH"
  echo '{"browser":{"enabled_labs_experiments":[]},"performance_tuning":{"battery_saver_mode":{"state":0},"high_efficiency_mode":{"state":0}}}' \
    >"$NOVA_CHROME_LOCAL_STATE"
}

teardown() { teardown_scratch; }

saver() { jq -r '.performance_tuning.battery_saver_mode.state' "$NOVA_CHROME_LOCAL_STATE"; }

@test "turns it on when unplugged, and keeps the rest of Local State" {
  run "$REPO_ROOT/src/cli/bin/nova-chrome-energy-saver"
  [ "$status" -eq 0 ]
  [ "$(saver)" = 2 ]
  [ "$(jq -r '.performance_tuning.high_efficiency_mode.state' "$NOVA_CHROME_LOCAL_STATE")" = 0 ]
  [ "$(jq -c '.browser' "$NOVA_CHROME_LOCAL_STATE")" = '{"enabled_labs_experiments":[]}' ]
  [ -e "$XDG_STATE_HOME/nova/chrome-energy-saver" ]
}

@test "once: a choice made in Chrome afterwards stays" {
  "$REPO_ROOT/src/cli/bin/nova-chrome-energy-saver"
  jq '.performance_tuning.battery_saver_mode.state = 0' "$NOVA_CHROME_LOCAL_STATE" >"$SCRATCH/t" && mv "$SCRATCH/t" "$NOVA_CHROME_LOCAL_STATE"
  run "$REPO_ROOT/src/cli/bin/nova-chrome-energy-saver"
  [ "$status" -eq 0 ]
  [ "$(saver)" = 0 ]
}

@test "not while Chrome runs, and it tries again next time" {
  touch "$SCRATCH/running"
  run "$REPO_ROOT/src/cli/bin/nova-chrome-energy-saver"
  [ "$status" -eq 0 ]
  [ "$(saver)" = 0 ]
  [ ! -e "$XDG_STATE_HOME/nova/chrome-energy-saver" ]
  rm "$SCRATCH/running"
  "$REPO_ROOT/src/cli/bin/nova-chrome-energy-saver"
  [ "$(saver)" = 2 ]
}

@test "not before Chrome has made its Local State" {
  rm "$NOVA_CHROME_LOCAL_STATE"
  run "$REPO_ROOT/src/cli/bin/nova-chrome-energy-saver"
  [ "$status" -eq 0 ]
  [ ! -e "$NOVA_CHROME_LOCAL_STATE" ]
  [ ! -e "$XDG_STATE_HOME/nova/chrome-energy-saver" ]
}

@test "a Local State it cannot read is left as it was" {
  echo 'not json' >"$NOVA_CHROME_LOCAL_STATE"
  run "$REPO_ROOT/src/cli/bin/nova-chrome-energy-saver"
  [ "$status" -ne 0 ]
  [ "$(cat "$NOVA_CHROME_LOCAL_STATE")" = 'not json' ]
  [ ! -e "$XDG_STATE_HOME/nova/chrome-energy-saver" ]
  [ -z "$(ls "$SCRATCH" | grep nova\\.)" ]
}
