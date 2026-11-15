#!/usr/bin/env bats

# nova-airdrop-apply, the root half of `nova airdrop bell on` and `off`: the
# doorbell is enabled and started for the user who asked (pkexec names them)
# and for nobody else. systemctl is a stub that logs.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls"
  mkdir -p "$SCRATCH/bin"
  printf '#!/bin/bash\necho "systemctl $*" >>"$CALLS"\n' >"$SCRATCH/bin/systemctl"
  chmod +x "$SCRATCH/bin/systemctl"
  export PATH="$SCRATCH/bin:$PATH"
  apply="$REPO_ROOT/src/airdrop/bin/nova-airdrop-apply"
}

@test "bell-on enables and starts the doorbell of whoever asked" {
  PKEXEC_UID=1000 run "$apply" bell-on
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "systemctl enable --now --quiet nova-airdrop-bell@1000.service" ]
}

@test "bell-off disables and stops it" {
  PKEXEC_UID=1000 run "$apply" bell-off
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "systemctl disable --now --quiet nova-airdrop-bell@1000.service" ]
}

@test "not through pkexec, or for root, or with a word more, nothing is touched" {
  run "$apply" bell-on
  [ "$status" -eq 2 ]
  PKEXEC_UID=0 run "$apply" bell-on
  [ "$status" -eq 2 ]
  PKEXEC_UID=1000 run "$apply" bell-on --now
  [ "$status" -eq 2 ]
  PKEXEC_UID=1000 run "$apply" ring
  [ "$status" -eq 2 ]
  [ ! -s "$CALLS" ]
}
