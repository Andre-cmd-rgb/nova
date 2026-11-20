#!/usr/bin/env bats

# nova-shell against a stubbed qs: what it is asked, and how each of its
# answers comes out. The stub prints $QS_REPLY and exits $QS_STATUS, or sleeps
# past the timeout when $QS_STATUS is "hang".

load ../test_helper

setup() {
  setup_scratch
  export NOVA_PATH=$SCRATCH/share CALLS=$SCRATCH/calls WAYLAND_DISPLAY=wayland-1
  export QS_REPLY="" QS_STATUS=0
  write_file "$NOVA_PATH/shell/shell.qml"
  mkdir -p "$SCRATCH/bin"
  cat >"$SCRATCH/bin/qs" <<'STUB'
#!/bin/bash
printf 'qs %s | %s\n' "$*" "$WAYLAND_DISPLAY" >>"$CALLS"
if [[ $QS_STATUS == hang ]]; then exec sleep 10; fi
[[ -z $QS_REPLY ]] || printf '%s\n' "$QS_REPLY"
exit "$QS_STATUS"
STUB
  chmod +x "$SCRATCH/bin/qs"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

shell() { "$REPO_ROOT/src/cli/bin/nova-shell" "$@"; }

@test "the call goes to the shell's own config, after a --, and its answer is printed" {
  QS_REPLY=ok run shell nova.menu show '{"a":1}'
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
  [ "$(cat "$CALLS")" = "qs ipc -n -p $NOVA_PATH/shell call -- nova.menu show {\"a\":1} | wayland-1" ]
}

@test "a menu summoned or toggled with no payload gets {}, and nothing else does" {
  shell shell summon nova.menu
  shell shell toggle nova.menu '{"menu":"root"}'
  shell shell hide nova.menu
  shell nova.menu summon x
  [ "$(cut -d" " -f8- "$CALLS")" = "$(printf '%s\n' \
    'shell summon nova.menu {} | wayland-1' \
    'shell toggle nova.menu {"menu":"root"} | wayland-1' \
    'shell hide nova.menu | wayland-1' \
    'nova.menu summon x | wayland-1')" ]
}

@test "help, and too few arguments" {
  run shell
  [ "$status" -eq 0 ]
  [[ ${lines[0]} == "Usage: nova-shell [-q] <target> <method> [args...]" ]]
  run shell --help
  [ "$status" -eq 0 ]
  run shell shell
  [ "$status" -eq 1 ]
  [ "$output" = "Usage: nova-shell <target> <method> [args...]" ]
  run shell -q shell
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$CALLS" ]
}

@test "no shell config: said, and qs not asked" {
  rm "$NOVA_PATH/shell/shell.qml"
  run shell shell ping
  [ "$status" -eq 1 ]
  [ "$output" = "nova-shell config not found: $NOVA_PATH/shell/shell.qml" ]
  [ ! -e "$CALLS" ]
}

@test "no shell reached, a shell that hangs, and one still starting" {
  QS_STATUS=1 run shell shell ping
  [ "$status" -eq 1 ]
  [ "$output" = "nova-shell is not running" ]
  QS_STATUS=hang NOVA_SHELL_IPC_TIMEOUT=0.2s run shell shell ping
  [ "$status" -eq 1 ]
  [ "$output" = "nova-shell is not responding" ]
  QS_REPLY="Not ready to accept queries yet, try again" run shell shell ping
  [ "$status" -eq 1 ]
  [ "$output" = "nova-shell is not ready" ]
}

@test "a call the shell refuses comes out as qs worded it, with a 1" {
  for reply in "Target not found." "Function not found." \
    "Too few arguments provided (2 needed)" "Too many arguments provided (1 needed)"; do
    QS_REPLY=$reply run shell nova.menu nothing
    [ "$status" -eq 1 ]
    [ "$output" = "$reply" ]
  done
  # Only as the whole answer, or its start.
  QS_REPLY="Function not found. Or so it says" run shell nova.menu nothing
  [ "$status" -eq 0 ]
}

@test "-q: nothing printed and a 0, whatever happens" {
  for answer in 1 hang; do
    QS_STATUS=$answer NOVA_SHELL_IPC_TIMEOUT=0.2s run shell -q shell ping
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  QS_REPLY="Function not found." run shell -q nova.menu nothing
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  QS_REPLY=ok run shell -q shell ping
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "from outside the session, the compositor's newest Wayland socket" {
  unset WAYLAND_DISPLAY
  export XDG_RUNTIME_DIR=$SCRATCH/run
  mkdir -p "$XDG_RUNTIME_DIR"
  for name in wayland-0 wayland-1 wayland-2; do
    bind_socket "$XDG_RUNTIME_DIR/$name"
  done
  touch -d '2024-01-01' "$XDG_RUNTIME_DIR/wayland-0" "$XDG_RUNTIME_DIR/wayland-2"
  : >"$XDG_RUNTIME_DIR/wayland-1.lock"
  shell shell ping
  [[ $(cat "$CALLS") == *" | wayland-1" ]]
}
