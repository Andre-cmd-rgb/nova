#!/usr/bin/env bats

# nova-previewer, Quick Look's front on D-Bus, as Files calls it (client.py)
# on a session bus of its own, with a fake nova-shell in place of the shell.
# The window itself is the shell's and is tested in tests/qml.

load ../test_helper

setup() {
  setup_scratch
  python3 -c 'import gi' 2>/dev/null || skip "needs python-gobject"
  command -v dbus-run-session >/dev/null || skip "needs dbus-run-session"
  export SHELL_LOG=$SCRATCH/shell.log
  mkdir -p "$SCRATCH/bin" "$SCRATCH/files"
  cat >"$SCRATCH/bin/nova-shell" <<'EOF'
#!/bin/bash
printf '%s\t' "$@" >>"$SHELL_LOG"
echo >>"$SHELL_LOG"
[[ -z ${SHELL_FAILS:-} ]]
EOF
  chmod +x "$SCRATCH/bin/nova-shell"
  export NOVA_PREVIEW_SHELL=$SCRATCH/bin/nova-shell
  export NOVA_PREVIEW_IDLE_SECONDS=2
}

teardown() { teardown_scratch; }

# The bus, the service file that has D-Bus start the front, and the client.
run_client() { # [env...]
  local services=$SCRATCH/dbus/dbus-1/services
  mkdir -p "$services"
  printf '[D-BUS Service]\nName=org.gnome.NautilusPreviewer\nExec=/usr/bin/python3 -B -I %s\n' \
    "$REPO_ROOT/src/preview/nova-previewer" >"$services/org.gnome.NautilusPreviewer.service"
  XDG_DATA_DIRS=$SCRATCH/dbus run dbus-run-session -- python3 -B -I "$BATS_TEST_DIRNAME/client.py" "$SCRATCH/files"
  echo "$output"
}

@test "Files' calls: shown, replaced in place, closed, navigated; quits when idle" {
  run_client
  [ "$status" -eq 0 ]
  [[ $output == *DONE* ]]
  [[ $output != *FAIL* ]]
}

@test "a shell that is not there takes the preview away again" {
  export SHELL_FAILS=1
  local services=$SCRATCH/dbus/dbus-1/services
  mkdir -p "$services"
  printf '[D-BUS Service]\nName=org.gnome.NautilusPreviewer\nExec=/usr/bin/python3 -B -I %s\n' \
    "$REPO_ROOT/src/preview/nova-previewer" >"$services/org.gnome.NautilusPreviewer.service"
  run env XDG_DATA_DIRS="$SCRATCH/dbus" dbus-run-session -- bash -c '
    gdbus call --session --dest org.gnome.NautilusPreviewer --object-path /org/gnome/NautilusPreviewer \
      --method org.gnome.NautilusPreviewer2.ShowFile "file:///etc/hostname" "" false "" >/dev/null
    sleep 1
    gdbus call --session --dest org.gnome.NautilusPreviewer --object-path /org/gnome/NautilusPreviewer \
      --method org.freedesktop.DBus.Properties.Get org.gnome.NautilusPreviewer2 Visible'
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"<false>"* ]]
}
