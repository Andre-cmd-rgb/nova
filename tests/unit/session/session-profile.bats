#!/usr/bin/env bats

# nova-session-profile: what the user's login shell sets reaches the whole
# session (uwsm's env file evals its lines), and nothing else does: not the
# session's identity, not the profile's output, and not a profile that hangs
# or fails, which gives nothing rather than a session that does not start.

load ../test_helper

bats_require_minimum_version 1.5.0

setup() {
  setup_scratch
  SCRIPT=$REPO_ROOT/data/session/bin/nova-session-profile
  export HOME=$SCRATCH/home
  mkdir -p "$HOME"
}

teardown() {
  [[ ! -f $HOME/bg.pid ]] || kill "$(cat "$HOME/bg.pid")" 2>/dev/null || true
  teardown_scratch
}

# The helper as uwsm's env file runs it: a scratch home, the session's own
# variables already there. Extra NAME=value words go first.
profile() {
  env -i HOME="$HOME" PATH=/usr/local/bin:/usr/bin SHELL="${LOGIN_SHELL:-/bin/bash}" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" NOVA_LOGIN=autologin XDG_SESSION_ID=3 LANG=C.UTF-8 \
    "$@" "$SCRIPT"
}

# The value of <name> once sh has evaluated <lines>, as uwsm's env file does.
evaluated() { # lines name
  sh -c 'eval "$1"; eval "printf %s \"\${$2-unset}\""' _ "$1" "$2"
}

@test "what ~/.bash_profile sets reaches the session, and its PATH, each folder once" {
  cat >"$HOME/.bash_profile" <<'EOF'
export PATH="$HOME/.local/bin:$PATH:/usr/bin"
export NOVA_TEST_TOOL=/opt/tool
echo "Welcome back"
echo "a warning" >&2
EOF
  run --separate-stderr profile
  [ "$status" -eq 0 ]
  [ -z "$stderr" ]
  [[ $output != *Welcome* && $output != *warning* ]]
  [ "$(evaluated "$output" NOVA_TEST_TOOL)" = /opt/tool ]
  path=$(evaluated "$output" PATH)
  [[ $path == "$HOME/.local/bin:"* ]]
  [ "$(tr ':' '\n' <<<"$path" | sort | uniq -d)" = "" ]
}

@test "~/.profile, read by Nova's ~/.bash_profile, reaches it too" {
  cp "$REPO_ROOT/data/skel/.bash_profile" "$HOME/.bash_profile"
  echo 'export NOVA_TEST_FROM_PROFILE=yes' >"$HOME/.profile"
  run profile
  [ "$status" -eq 0 ]
  [ "$(evaluated "$output" NOVA_TEST_FROM_PROFILE)" = yes ]
}

@test "the session's identity and the shell's bookkeeping are never taken" {
  cat >"$HOME/.bash_profile" <<'EOF'
export NOVA_LOGIN=password XDG_SESSION_ID=99 XDG_CURRENT_DESKTOP=GNOME HOME=/elsewhere
export SHLVL=7 UWSM_TEST=1 __TEST=1 DBUS_SESSION_BUS_ADDRESS=unix:path=/nowhere
export NOVA_TEST_OK=1
EOF
  run profile
  [ "$status" -eq 0 ]
  [ "$(evaluated "$output" NOVA_TEST_OK)" = 1 ]
  fails grep -qE '^export (NOVA_LOGIN|XDG_SESSION_ID|XDG_CURRENT_DESKTOP|HOME|SHLVL|UWSM_TEST|__TEST|DBUS_SESSION_BUS_ADDRESS|PWD|_)=' <<<"$output"
}

@test "a value with quotes, a dollar sign and a newline comes through as it was" {
  cat >"$HOME/.bash_profile" <<'EOF'
export NOVA_TEST_TRICKY="it's \"quoted\" \$HOME & \`x\`
line two"
EOF
  run profile
  [ "$status" -eq 0 ]
  want=$(printf '%s\n%s' "it's \"quoted\" \$HOME & \`x\`" "line two")
  [ "$(evaluated "$output" NOVA_TEST_TRICKY)" = "$want" ]
}

@test "what the session has already, unchanged, is not said again" {
  echo 'export NOVA_TEST_SAME=1 NOVA_TEST_NEW=1' >"$HOME/.bash_profile"
  run profile NOVA_TEST_SAME=1
  [ "$status" -eq 0 ]
  fails grep -q '^export NOVA_TEST_SAME=' <<<"$output"
  grep -qx "export NOVA_TEST_NEW='1'" <<<"$output"
}

@test "a profile that hangs gives nothing, in its time, and says so" {
  echo 'export NOVA_TEST_NEVER=1; sleep 30' >"$HOME/.bash_profile"
  start=$SECONDS
  run --separate-stderr profile NOVA_PROFILE_TIMEOUT=1
  [ "$status" -eq 0 ]
  ((SECONDS - start < 5))
  [ -z "$output" ]
  [[ $stderr == *"did not finish within 1s"* ]]
}

@test "a profile that leaves something running is read at once" {
  echo 'sleep 30 & echo $! >"$HOME/bg.pid"; export NOVA_TEST_AFTER=1' >"$HOME/.bash_profile"
  start=$SECONDS
  run profile
  [ "$status" -eq 0 ]
  ((SECONDS - start < 4))
  [ "$(evaluated "$output" NOVA_TEST_AFTER)" = 1 ]
}

@test "a profile that exits before it is read gives nothing, and says so" {
  echo 'export NOVA_TEST_NEVER=1; exit 3' >"$HOME/.bash_profile"
  run --separate-stderr profile
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ $stderr == *"ended with status 3"* ]]
}

@test "a login shell that is not one it knows, or not there, is not run" {
  printf '#!/bin/sh\ntouch "$HOME/ran"\n' >"$SCRATCH/csh"
  chmod +x "$SCRATCH/csh"
  for shell in "$SCRATCH/csh" /usr/bin/nologin "$SCRATCH/missing/bash"; do
    LOGIN_SHELL=$shell run profile
    [ "$status" -eq 0 ]
    [ -z "$output" ]
  done
  [ ! -e "$HOME/ran" ]
}

@test "Nova's uwsm env file is plain sh, and runs the helper first" {
  run sh -n "$REPO_ROOT/data/session/uwsm/10-nova"
  [ "$status" -eq 0 ]
  first=$(grep -vE '^[[:space:]]*(#|$)' "$REPO_ROOT/data/session/uwsm/10-nova" | head -n 2)
  [[ $first == *"/usr/lib/nova/bin/nova-session-profile"* ]]
}
