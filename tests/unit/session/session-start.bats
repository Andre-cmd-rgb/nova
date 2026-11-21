#!/usr/bin/env bats

# nova-session-start: uwsm starts the desktop with nothing of its own on the
# console greetd hands the session; and packaging/nova/nova.install moves the
# boot autologin line the installer wrote over to it, leaving a changed one
# alone.

load ../test_helper

setup() {
  setup_scratch
  mkdir -p "$SCRATCH/bin"
  export PATH="$SCRATCH/bin:$PATH"
  export NOVA_GREETD_CONFIG=$SCRATCH/config.toml
}

teardown() { teardown_scratch; }

@test "uwsm starts Hyprland's session, and nothing it says reaches the console" {
  cat >"$SCRATCH/bin/uwsm" <<STUB
#!/bin/bash
echo "\$*" >"$SCRATCH/args"
echo "Starting wayland-session-envelope@hyprland.desktop.target..."
echo "PID 910 exited with RC 129" >&2
STUB
  chmod +x "$SCRATCH/bin/uwsm"
  run "$REPO_ROOT/data/session/bin/nova-session-start"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$SCRATCH/args")" = "start -e -D Hyprland hyprland.desktop" ]
}

@test "the session's end is uwsm's: its exit status comes back" {
  printf '#!/bin/bash\nexit 3\n' >"$SCRATCH/bin/uwsm"
  chmod +x "$SCRATCH/bin/uwsm"
  run "$REPO_ROOT/data/session/bin/nova-session-start"
  [ "$status" -eq 3 ]
}

@test "greetd's template and the greeter start the session through it" {
  grep -qx 'command = "env NOVA_LOGIN=autologin /usr/lib/nova/bin/nova-session-start"' "$REPO_ROOT/data/session/greetd/config.toml"
  grep -q 'Greetd.launch(\["/usr/lib/nova/bin/nova-session-start"\], \["NOVA_LOGIN=password"\]' "$REPO_ROOT/src/shell/greeter.qml"
}

rc14_config() {
  cat >"$NOVA_GREETD_CONFIG" <<'TOML'
[initial_session]
command = "env NOVA_LOGIN=autologin UWSM_SILENT_START=1 uwsm start -e -D Hyprland hyprland.desktop"
user = "andre"

[default_session]
command = "/usr/lib/nova/bin/nova-greeter-session"
TOML
}

upgrade() {
  # shellcheck source=/dev/null
  (source "$REPO_ROOT/packaging/nova/nova.install" && post_upgrade 1.0.0rc.15-1 1.0.0rc.14-1)
}

@test "an upgrade moves the installer's autologin line to what a new install writes" {
  rc14_config
  chmod 640 "$NOVA_GREETD_CONFIG"
  upgrade
  [ "$(grep '^command' "$NOVA_GREETD_CONFIG" | head -1)" = "$(grep '^command = "env NOVA_LOGIN=autologin' "$REPO_ROOT/data/session/greetd/config.toml")" ]
  grep -qx 'user = "andre"' "$NOVA_GREETD_CONFIG"
  grep -qx 'command = "/usr/lib/nova/bin/nova-greeter-session"' "$NOVA_GREETD_CONFIG"
  [ "$(stat -c %a "$NOVA_GREETD_CONFIG")" = 640 ]
  [ -z "$(find "$SCRATCH" -name 'config.toml.*')" ]
}

@test "a second upgrade changes nothing more" {
  rc14_config
  upgrade
  cp "$NOVA_GREETD_CONFIG" "$SCRATCH/once"
  upgrade
  cmp "$SCRATCH/once" "$NOVA_GREETD_CONFIG"
}

@test "an autologin command changed by hand is left alone" {
  printf '[initial_session]\ncommand = "env NOVA_LOGIN=autologin UWSM_SILENT_START=1 uwsm start -e -D Hyprland hyprland.desktop --mine"\n' >"$NOVA_GREETD_CONFIG"
  cp "$NOVA_GREETD_CONFIG" "$SCRATCH/before"
  upgrade
  cmp "$SCRATCH/before" "$NOVA_GREETD_CONFIG"
}

@test "no greetd config, nothing to do" {
  run upgrade
  [ "$status" -eq 0 ]
  [ ! -e "$NOVA_GREETD_CONFIG" ]
}
