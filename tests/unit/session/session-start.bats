#!/usr/bin/env bats

# nova-session-start: uwsm starts the desktop with nothing of its own on the
# console greetd hands the session. The boot autologin line that names it is
# nova-update-apply's to rewrite, both ways (nova.install runs it): its tests
# are in tests/unit/cli/update-apply.bats, on a scratch root.

load ../test_helper

setup() {
  setup_scratch
  mkdir -p "$SCRATCH/bin"
  export PATH="$SCRATCH/bin:$PATH"
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
