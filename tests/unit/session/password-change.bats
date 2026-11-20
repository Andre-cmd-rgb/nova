#!/usr/bin/env bats

# nova-password-change, Settings' Change Password, against a fake passwd that
# asks as PAM does: on its terminal, flushing what was typed ahead, each
# prompt in pieces. Its prompt matching and its diagnostics are in its Rust
# tests too (cargo test).

load ../test_helper

setup_file() {
  if command -v cargo >/dev/null; then
    (cd "$REPO_ROOT" && cargo build --quiet --package nova-account)
  fi
}

setup() {
  setup_scratch
  helper=${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/nova-password-change
  [[ -x $helper ]] || skip "needs cargo, to build nova-password-change"
  mkdir "$SCRATCH/bin"
  export PATH="$SCRATCH/bin:$PATH" ARGV_LOG="$SCRATCH/arguments" NOVA_PASSWD="$SCRATCH/bin/passwd"
  cat >"$SCRATCH/bin/passwd" <<'STUB'
#!/bin/bash
echo $$ >"$ARGV_LOG.pid"
{ echo "argv: $*"; tr '\0' ' ' <"/proc/$PPID/cmdline"; } >"$ARGV_LOG"
[[ $LC_ALL == C && $# -eq 0 ]] || exit 99
[[ -z ${PASSWD_HANG:-} ]] || exec sleep 60
exec 3>/dev/tty 4</dev/tty

# Asks as PAM does: echo off, what was typed ahead thrown away, the prompt in
# two writes and without a newline at its end.
ask() { # prompt
  local answer
  stty -echo <&4
  while read -t 0 <&4; do read -r -t 0.01 _ <&4 || true; done
  printf '%s' "${1:0:4}" >&3
  sleep 0.02
  printf '%s' "${1:4}" >&3
  IFS= read -r answer <&4
  printf '\n' >&3
  printf '%s' "$answer"
}

# An account without a password yet: passwd asks for the new one first.
if [[ -n ${PASSWD_NO_CURRENT:-} ]]; then current='old secret'; else current=$(ask "Current password: "); fi
if [[ $current != 'old secret' ]]; then
  echo "passwd: Authentication token manipulation error"
  exit 1
fi
new=$(ask "New password: ")
if [[ $new == 'weak secret' ]]; then
  echo "BAD PASSWORD: The password is shorter than 12 characters"
  ask "New password: " >/dev/null
  exit 1
fi
again=$(ask "Retype new password: ")
if [[ $again != "$new" ]]; then
  echo "Sorry, passwords do not match."
  exit 1
fi
if [[ $new == 'echo secret' ]]; then
  echo "passwd: rejected $new"
  exit 1
fi
echo "passwd: password updated successfully"
STUB
  chmod +x "$SCRATCH/bin/passwd"
}

teardown() { teardown_scratch; }

change_password() { printf '%s\0' "$1" "$2" "$3" | "$helper"; }

@test "passwd's terminal prompts get each answer after PAM flushes input" {
  run change_password 'old secret' 'new secret' 'new secret'
  [ "$status" -eq 0 ]
  [ "$(jq -r .ok <<<"$output")" = true ]
  [[ $output != *secret* ]]
  fails grep -q secret "$ARGV_LOG"
}

@test "a wrong current password has one short error" {
  run change_password 'wrong secret' 'new secret' 'new secret'
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = 'The current password is not right.' ]
  [[ $output != *secret* ]]
}

@test "mismatching new passwords never start passwd" {
  run change_password 'old secret' 'new secret' 'other secret'
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = 'The new passwords are not the same.' ]
  [ ! -e "$ARGV_LOG" ]
}

@test "PAM's weak password reason survives without retrying blindly" {
  run change_password 'old secret' 'weak secret' 'weak secret'
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = 'The password is shorter than 12 characters' ]
  [[ $output != *secret* ]]
}

@test "even an unexpected diagnostic cannot echo a password" {
  run change_password 'old secret' 'echo secret' 'echo secret'
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = 'rejected [hidden]' ]
  [[ $output != *secret* ]]
  fails grep -q secret "$ARGV_LOG"
}

@test "incomplete input does not start passwd" {
  run bash -c 'printf "old\\0" | "$1"' _ "$helper"
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = 'Enter all three passwords.' ]
  [ ! -e "$ARGV_LOG" ]
}

@test "a password with a control character in it does not start passwd" {
  run change_password $'old\tsecret' 'new secret' 'new secret'
  [ "$status" -eq 1 ]
  [ "$(jq -r .error <<<"$output")" = 'That password contains unsupported characters or is too long.' ]
  [ ! -e "$ARGV_LOG" ]
}

@test "an account without a password yet starts at the new one" {
  PASSWD_NO_CURRENT=1 run change_password 'old secret' 'new secret' 'new secret'
  [ "$status" -eq 0 ]
  [ "$(jq -r .ok <<<"$output")" = true ]
}

# Settings cancelling: passwd and its PAM session end with the helper, and
# nothing is said.
@test "cancelled, it ends passwd with it and says nothing" {
  printf '%s\0' 'old secret' 'new secret' 'new secret' >"$SCRATCH/input"
  PASSWD_HANG=1 "$helper" <"$SCRATCH/input" >"$SCRATCH/said" &
  local helper_pid=$! passwd_pid status=0
  for _ in $(seq 100); do
    [[ -s $ARGV_LOG.pid ]] && break
    sleep 0.05
  done
  passwd_pid=$(cat "$ARGV_LOG.pid")
  running "$passwd_pid"
  kill -TERM "$helper_pid"
  wait "$helper_pid" || status=$?
  [ "$status" -eq 1 ]
  [ ! -s "$SCRATCH/said" ]
  fails running "$passwd_pid"
}
