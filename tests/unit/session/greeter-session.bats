#!/usr/bin/env bats

# data/session/bin/nova-greeter-session: who the greeter greets, and the
# hardware environment its Hyprland starts with.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_GREETD_CONFIG=$SCRATCH/config.toml
  export NOVA_UWSM_ENV_DIR=$SCRATCH/env.d
  # shellcheck source=/dev/null
  source "$REPO_ROOT/data/session/bin/nova-greeter-session"
}

teardown() {
  teardown_scratch
}

@test "greeted_user reads the autologin user, not the greeter's" {
  write_file "$NOVA_GREETD_CONFIG" '[initial_session]
command = "env NOVA_LOGIN=autologin uwsm start hyprland.desktop"
user = "andre"

[default_session]
user = "greeter"
'
  run greeted_user
  [ "$status" -eq 0 ]
  [ "$output" = andre ]
}

@test "greeted_user accepts a value without spaces around =" {
  write_file "$NOVA_GREETD_CONFIG" '[initial_session]
user="andre"
'
  run greeted_user
  [ "$output" = andre ]
}

@test "greeted_user is empty without an autologin user or a config" {
  write_file "$NOVA_GREETD_CONFIG" '[default_session]
user = "greeter"
'
  run greeted_user
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  rm "$NOVA_GREETD_CONFIG"
  run greeted_user
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "hardware_env takes the hardware files, not the session's own" {
  write_file "$NOVA_UWSM_ENV_DIR/10-nova" 'export NOVA_TEST_SESSION=1'
  write_file "$NOVA_UWSM_ENV_DIR/20-nova-some-model" 'export NOVA_TEST_HARDWARE=1'
  hardware_env
  [ "${NOVA_TEST_HARDWARE:-}" = 1 ]
  [ -z "${NOVA_TEST_SESSION:-}" ]
}

@test "hardware_env survives a failing file and an empty directory" {
  write_file "$NOVA_UWSM_ENV_DIR/20-nova-broken" 'false
export NOVA_TEST_AFTER=1'
  run bash -c 'set -euo pipefail; source "$1"; hardware_env; echo "after=${NOVA_TEST_AFTER:-}"' _ \
    "$REPO_ROOT/data/session/bin/nova-greeter-session"
  [ "$status" -eq 0 ]
  [ "$output" = after=1 ]
  rm -r "$NOVA_UWSM_ENV_DIR"
  run bash -c 'set -euo pipefail; source "$1"; hardware_env; echo finished' _ \
    "$REPO_ROOT/data/session/bin/nova-greeter-session"
  [ "$status" -eq 0 ]
  [ "$output" = finished ]
}

@test "the P1 hardware file parses under the greeter's strict bash" {
  mkdir -p "$NOVA_UWSM_ENV_DIR"
  cp "$REPO_ROOT/data/hardware/uwsm/20-nova-thinkpad-p1-gen4i" "$NOVA_UWSM_ENV_DIR/"
  run bash -c 'set -euo pipefail; source "$1"; hardware_env; echo finished' _ \
    "$REPO_ROOT/data/session/bin/nova-greeter-session"
  [ "$status" -eq 0 ]
  [ "$output" = finished ]
}
