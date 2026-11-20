#!/usr/bin/env bats

# The shell's allocator settings (src/shell/alloc), preloaded into Quickshell
# as nova-launch-shell does: jemalloc takes them, and what the shell starts
# has neither the library nor a setting of jemalloc's in its environment.
# Quickshell runs offscreen, with no display, bus or home of the session's.

load ../test_helper

# Built once for these, as `cargo test` builds only its tests.
setup_file() {
  if command -v cargo >/dev/null; then
    (cd "$REPO_ROOT" && cargo build --quiet --package nova-shell-alloc)
  fi
}

setup() {
  setup_scratch
  LIB=${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/libnova_shell_alloc.so
  [[ -f $LIB ]] || skip "needs cargo, to build the library"
  QS=$(command -v quickshell) || skip "needs Quickshell"
  ldd "$QS" | grep -q libjemalloc || skip "this Quickshell is not built with jemalloc"
  mkdir -p "$SCRATCH/home" "$SCRATCH/shell"
}

teardown() { teardown_scratch; }

# Quickshell with the library preloaded, and only what it needs to start.
# env execs Quickshell, so the preload is its: a command in between, as
# timeout would be, would take the library out of LD_PRELOAD itself.
preloaded() {
  timeout 30 env -i PATH="$PATH" HOME="$SCRATCH/home" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
    DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS" QT_QPA_PLATFORM=offscreen \
    LD_PRELOAD="$LIB" "$@"
}

@test "jemalloc in Quickshell takes the library's settings: two arenas" {
  run preloaded MALLOC_CONF=stats_print:true "$QS" --version
  [ "$status" -eq 0 ]
  [[ $output == *"opt.narenas: 2"* ]]
}

@test "an app the shell starts has neither the library nor jemalloc's settings" {
  # The app reports on itself, and the shell on itself: the shell has the
  # library, so the arenas are its own.
  cat >"$SCRATCH/shell/shell.qml" <<'EOF'
import QtQuick
import Quickshell
import Quickshell.Io

ShellRoot {
  FileView {
    id: maps
    path: "/proc/self/maps"
    blockLoading: true
  }
  Process {
    running: true
    command: ["sh", "-c", "echo \"app=$(grep -c nova_shell_alloc /proc/self/maps) preload=${LD_PRELOAD-unset} conf=${MALLOC_CONF-unset}\""]
    stdout: StdioCollector {
      onStreamFinished: {
        console.log("SHELL " + (maps.text().indexOf("libnova_shell_alloc.so") >= 0) + " APP " + text.trim())
        Qt.quit()
      }
    }
  }
}
EOF
  run preloaded "$QS" -n -p "$SCRATCH/shell/shell.qml"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ $output == *"SHELL true APP app=0 preload=unset conf=unset"* ]]
}
