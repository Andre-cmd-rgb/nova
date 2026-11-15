#!/usr/bin/env bats

# nova-system-sleep-monitor against a scripted logind: a gdbus that prints
# the lines of $LOGIND, a systemd-inhibit that says when it holds and when it
# lets go, and a stubbed lock. Each step is logged to $CALLS.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" LOGIND="$SCRATCH/logind" XDG_RUNTIME_DIR="$SCRATCH/run"
  mkdir -p "$SCRATCH/bin" "$XDG_RUNTIME_DIR/nova"
  : >"$CALLS"
  # "@holds N" waits until systemd-inhibit has held N times.
  cat >"$SCRATCH/bin/gdbus" <<'EOF'
#!/bin/bash
while IFS= read -r line; do
  if [[ $line == '@holds '* ]]; then
    for _ in {1..100}; do
      (($(grep -cx hold "$CALLS") >= ${line#@holds })) && break
      sleep 0.05
    done
  else
    printf '%s\n' "$line"
  fi
done <"$LOGIND"
EOF
  cat >"$SCRATCH/bin/systemd-inhibit" <<'EOF'
#!/bin/bash
trap 'echo "let go" >>"$CALLS"; kill "$sleeper"; exit 0' TERM
sleep 30 >/dev/null 2>&1 3>&- &
sleeper=$!
echo hold >>"$CALLS"
wait
EOF
  # A lock that is not up in time leaves the marker, as the real one does.
  cat >"$SCRATCH/bin/nova-system-sleep-lock" <<'EOF'
#!/bin/bash
echo "lock${1:+ $1}" >>"$CALLS"
marker=$XDG_RUNTIME_DIR/nova/sleep-unsecured
if [[ ${1:-} == --resumed ]]; then rm -f "$marker"; elif [[ -n ${UNSECURED:-} ]]; then : >"$marker"; exit 1; fi
EOF
  chmod +x "$SCRATCH/bin/"*
  export PATH="$SCRATCH/bin:$PATH"
  monitor="$REPO_ROOT/src/cli/bin/nova-system-sleep-monitor"
}

teardown() { teardown_scratch; }

owner='The name org.freedesktop.login1 is owned by :1.7'
asleep='/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (true,)'
awake='/org/freedesktop/login1: org.freedesktop.login1.Manager.PrepareForSleep (false,)'

@test "a sleep: the lock first, then the inhibitor goes, and is held again on the wake" {
  printf '%s\n' 'Monitoring signals on object /org/freedesktop/login1 owned by org.freedesktop.login1' \
    "$owner" '@holds 1' \
    "/org/freedesktop/login1: org.freedesktop.login1.Manager.SessionNew ('3', '/org/freedesktop/login1/session/_33')" \
    "$asleep" "$awake" '@holds 2' >"$LOGIND"
  run "$monitor"
  # gdbus ending is the monitor's failure, for systemd to start it again.
  [ "$status" -eq 1 ]
  [[ $output == *"gdbus stopped"* ]]
  [ "$(cat "$CALLS")" = "$(printf '%s\n' hold lock 'let go' hold 'let go')" ]
}

@test "nothing held before gdbus watches, and a new logind gets a new inhibitor" {
  printf '%s\n' "$owner" '@holds 1' 'The name org.freedesktop.login1 does not have an owner' \
    'The name org.freedesktop.login1 is owned by :1.9' '@holds 2' >"$LOGIND"
  run "$monitor"
  [ "$(cat "$CALLS")" = "$(printf '%s\n' hold 'let go' hold 'let go')" ]
}

@test "a sleep the lock was not up for: the wake asks for it again" {
  printf '%s\n' "$owner" '@holds 1' "$asleep" "$awake" '@holds 2' >"$LOGIND"
  UNSECURED=1 run "$monitor"
  for _ in {1..40}; do
    [ -e "$XDG_RUNTIME_DIR/nova/sleep-unsecured" ] || break
    sleep 0.05
  done
  grep -qx 'lock --resumed' "$CALLS"
  [ ! -e "$XDG_RUNTIME_DIR/nova/sleep-unsecured" ]
}

@test "started after such a sleep, it asks for the lock again at once" {
  : >"$XDG_RUNTIME_DIR/nova/sleep-unsecured"
  printf '%s\n' "$owner" '@holds 1' >"$LOGIND"
  run "$monitor"
  for _ in {1..40}; do
    grep -qx 'lock --resumed' "$CALLS" && break
    sleep 0.05
  done
  grep -qx 'lock --resumed' "$CALLS"
}
