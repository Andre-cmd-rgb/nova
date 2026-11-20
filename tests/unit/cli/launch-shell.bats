#!/usr/bin/env bats

# nova-launch-shell against a stubbed systemd-cat, which runs as the shell
# would: what the shell is started with. The library it preloads is tried
# with Quickshell itself in tests/unit/shell/alloc.bats.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_PATH="$SCRATCH/share" CALLS="$SCRATCH/calls"
  export NOVA_SHELL_ALLOC="$SCRATCH/lib/libnova_shell_alloc.so"
  mkdir -p "$SCRATCH/bin" "$SCRATCH/lib"
  touch "$NOVA_SHELL_ALLOC"
  # The shell exits cleanly at once: stopped on purpose, so the launcher
  # does not start another.
  cat >"$SCRATCH/bin/systemd-cat" <<'STUB'
#!/bin/bash
printf '%s | LD_PRELOAD=%s MALLOC_CONF=%s\n' "$*" "${LD_PRELOAD-unset}" "${MALLOC_CONF-unset}" >>"$CALLS"
STUB
  chmod +x "$SCRATCH/bin/systemd-cat"
  export PATH="$SCRATCH/bin:$PATH"
  unset LD_PRELOAD MALLOC_CONF
}

teardown() { teardown_scratch; }

launch() { "$REPO_ROOT/src/cli/bin/nova-launch-shell"; }

@test "the allocator's settings are preloaded into Quickshell alone, not set in the environment" {
  run launch
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "-t nova-shell -- env LD_PRELOAD=$NOVA_SHELL_ALLOC quickshell -n -p $NOVA_PATH/shell | LD_PRELOAD=unset MALLOC_CONF=unset" ]
}

@test "a library the caller preloads stays preloaded, after Nova's" {
  LD_PRELOAD=/opt/other.so run launch
  [ "$status" -eq 0 ]
  [[ $(cat "$CALLS") == "-t nova-shell -- env LD_PRELOAD=$NOVA_SHELL_ALLOC:/opt/other.so quickshell "* ]]
}

@test "without the library the shell still starts, with jemalloc's own settings" {
  rm "$NOVA_SHELL_ALLOC"
  run launch
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "-t nova-shell -- quickshell -n -p $NOVA_PATH/shell | LD_PRELOAD=unset MALLOC_CONF=unset" ]
}
