#!/usr/bin/env bats

# nova-previewer, Quick Look's front on D-Bus, as Files calls it (client)
# on a session bus of its own, with a fake nova-shell in place of the shell.
# The window itself is the shell's and is tested in tests/qml; what a file is
# described as, the previewer's Rust tests (cargo test) try against GIO.

load ../test_helper

# The previewer is built once for these, as `cargo test` builds only its
# tests.
setup_file() {
  if command -v cargo >/dev/null; then
    (cd "$REPO_ROOT" && cargo build --quiet --package nova-previewer)
  fi
}

setup() {
  setup_scratch
  command -v dbus-run-session >/dev/null || skip "needs dbus-run-session"
  PREVIEWER=${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/nova-previewer
  [[ -x $PREVIEWER ]] || skip "needs cargo, to build nova-previewer"
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
  # GIO would start GVfs on the test's bus, and its FUSE helper reaches for
  # the real runtime folder: local files are all these tests read.
  export GIO_USE_VFS=local
  # The service file that has D-Bus start the front, as Nova's does.
  local services=$SCRATCH/dbus/dbus-1/services
  mkdir -p "$services"
  sed "s#^Exec=.*#Exec=$PREVIEWER#" "$REPO_ROOT/src/preview/org.gnome.NautilusPreviewer.service" \
    >"$services/org.gnome.NautilusPreviewer.service"
}

teardown() { teardown_scratch; }

@test "Files' calls: shown, replaced in place, closed, navigated; quits when idle" {
  XDG_DATA_DIRS=$SCRATCH/dbus run dbus-run-session -- "$BATS_TEST_DIRNAME/client" "$SCRATCH/files"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *DONE* ]]
  [[ $output != *FAIL* ]]
  [ "$(grep -c "^ok " <<<"$output")" -eq 17 ]
}

@test "a shell that is not there takes the preview away again" {
  export SHELL_FAILS=1
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

@test "the shell's own calls, as it makes them with gdbus: a direction, and a window closed" {
  run env XDG_DATA_DIRS="$SCRATCH/dbus" dbus-run-session -- bash -c '
    call() { gdbus call --session --dest org.gnome.NautilusPreviewer --object-path /org/gnome/NautilusPreviewer "$@"; }
    gdbus monitor --session --dest org.gnome.NautilusPreviewer >"$SCRATCH/signals" & monitor=$!
    call --method org.gnome.NautilusPreviewer2.ShowFile "file:///etc/hostname" "" false "" >/dev/null
    sleep 0.3
    call --method org.nova.Previewer.Select 5 >/dev/null
    call --method org.nova.Previewer.Closed 1 >/dev/null
    call --method org.freedesktop.DBus.Properties.Get org.gnome.NautilusPreviewer2 Visible
    sleep 0.3
    kill $monitor'
  echo "$output"
  cat "$SCRATCH/signals"
  [ "$status" -eq 0 ]
  [[ $output == *"<false>"* ]]
  grep -q 'SelectionEvent (uint32 5,)' "$SCRATCH/signals"
}
