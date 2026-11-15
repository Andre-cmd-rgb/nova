#!/usr/bin/env bats

# packaging/nova/nova.install: an upgrade quiets the boot autologin's uwsm in a
# greetd config the installer wrote, and leaves a changed one alone; an
# upgrade from before printing came starts it.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_GREETD_CONFIG=$SCRATCH/config.toml
  # shellcheck source=/dev/null
  source "$REPO_ROOT/packaging/nova/nova.install"
}

teardown() { teardown_scratch; }

beta5_config() {
  write_file "$NOVA_GREETD_CONFIG" '[initial_session]
command = "env NOVA_LOGIN=autologin uwsm start -e -D Hyprland hyprland.desktop"
user = "andre"
'
}

@test "the installer's autologin line ends as a new install writes it" {
  beta5_config
  quiet_session_start
  [ "$(grep '^command' "$NOVA_GREETD_CONFIG")" = "$(grep '^command = "env NOVA_LOGIN=autologin' "$REPO_ROOT/data/session/greetd/config.toml")" ]
  grep -qx 'user = "andre"' "$NOVA_GREETD_CONFIG"
}

@test "a second upgrade changes nothing more" {
  beta5_config
  quiet_session_start
  cp "$NOVA_GREETD_CONFIG" "$SCRATCH/once"
  quiet_session_start
  cmp "$SCRATCH/once" "$NOVA_GREETD_CONFIG"
}

@test "an autologin command changed by hand is left alone" {
  write_file "$NOVA_GREETD_CONFIG" '[initial_session]
command = "my-session"
'
  cp "$NOVA_GREETD_CONFIG" "$SCRATCH/before"
  quiet_session_start
  cmp "$SCRATCH/before" "$NOVA_GREETD_CONFIG"
}

@test "no greetd config, nothing to do" {
  run quiet_session_start
  [ "$status" -eq 0 ]
  [ ! -e "$NOVA_GREETD_CONFIG" ]
}

@test "printing starts once, on the upgrade from before it came" {
  systemctl() { echo "systemctl $*" >>"$SCRATCH/calls"; }
  findmnt() { echo btrfs; }
  start_printing 1.0.0beta.9
  grep -qx 'systemctl try-restart systemd-resolved.service' "$SCRATCH/calls"
  grep -qx 'systemctl enable --now avahi-daemon.service cups.socket' "$SCRATCH/calls"
  grep -qx 'systemctl enable --now btrfs-scrub@-.timer' "$SCRATCH/calls"
  [ "$(head -n 1 "$SCRATCH/calls")" = 'systemctl try-restart systemd-resolved.service' ]
  rm "$SCRATCH/calls"
  start_printing 1.0.0beta.10
  start_printing 1.0.0
  start_printing ''
  [ ! -e "$SCRATCH/calls" ]
}
