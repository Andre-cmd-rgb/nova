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
  cat >"$SCRATCH/bin/passwd" <<'PY'
#!/usr/bin/python3 -I
import os
import sys
import termios
import time

with open(os.environ["ARGV_LOG"] + ".pid", "w") as pid:
    pid.write(str(os.getpid()))
with open(os.environ["ARGV_LOG"], "wb") as log:
    log.write(repr(sys.argv).encode())
    with open(f"/proc/{os.getppid()}/cmdline", "rb") as command:
        log.write(command.read())
assert os.environ["LC_ALL"] == "C"
assert len(sys.argv) == 1
if os.environ.get("PASSWD_HANG"):
    time.sleep(60)
tty = open("/dev/tty", "w")
tty_input = open("/dev/tty")

def ask(prompt):
    attrs = termios.tcgetattr(tty)
    attrs[3] &= ~termios.ECHO
    termios.tcsetattr(tty, termios.TCSAFLUSH, attrs)
    # Prompts need not arrive as a whole read, or end with a newline.
    tty.write(prompt[:4])
    tty.flush()
    time.sleep(0.02)
    tty.write(prompt[4:])
    tty.flush()
    answer = tty_input.readline().rstrip("\n")
    tty.write("\n")
    tty.flush()
    return answer

# An account without a password yet: passwd asks for the new one first.
current = "old secret" if os.environ.get("PASSWD_NO_CURRENT") else ask("Current password: ")
if current != "old secret":
    print("passwd: Authentication token manipulation error", flush=True)
    sys.exit(1)
new = ask("New password: ")
if new == "weak secret":
    print("BAD PASSWORD: The password is shorter than 12 characters", flush=True)
    ask("New password: ")
    sys.exit(1)
again = ask("Retype new password: ")
if again != new:
    print("Sorry, passwords do not match.", flush=True)
    sys.exit(1)
if new == "echo secret":
    print("passwd: rejected " + new, flush=True)
    sys.exit(1)
print("passwd: password updated successfully", flush=True)
PY
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
