#!/usr/bin/env bats

# nova-launch-shell against a stubbed systemd-cat, which runs as the shell
# would: what the shell is started with.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_PATH="$SCRATCH/share" CALLS="$SCRATCH/calls"
  mkdir -p "$SCRATCH/bin"
  # The shell exits cleanly at once: stopped on purpose, so the launcher
  # does not start another.
  cat >"$SCRATCH/bin/systemd-cat" <<'STUB'
#!/bin/bash
printf '%s | MALLOC_CONF=%s\n' "$*" "${MALLOC_CONF-unset}" >>"$CALLS"
STUB
  chmod +x "$SCRATCH/bin/systemd-cat"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

launch() { "$REPO_ROOT/src/cli/bin/nova-launch-shell"; }

@test "the shell's allocator keeps two arenas, not four a CPU" {
  unset MALLOC_CONF
  run launch
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "-t nova-shell -- quickshell -n -p $NOVA_PATH/shell | MALLOC_CONF=narenas:2" ]
}

@test "a MALLOC_CONF of the caller's goes after Nova's, and wins" {
  MALLOC_CONF=narenas:8,stats_print:true run launch
  [ "$status" -eq 0 ]
  [[ $(cat "$CALLS") == *"| MALLOC_CONF=narenas:2,narenas:8,stats_print:true" ]]
}
