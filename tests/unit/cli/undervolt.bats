#!/usr/bin/env bats

# nova power undervolt and its root half, with pkexec, systemctl and the
# nova-undervolt tool stubbed. The tool's own logic (the mailbox, the holds)
# has Rust tests in src/power/undervolt. compare reads a fake CPU's voltage,
# which the fake systemctl's start sets from the offset.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" NOVA_UNDERVOLT_STATE="$SCRATCH/state"
  export NOVA_POWER_UNDERVOLT_APPLY="$REPO_ROOT/src/power/bin/nova-power-undervolt-apply"
  export NOVA_UNDERVOLT="$SCRATCH/bin/nova-undervolt"
  mkdir -p "$SCRATCH/bin"
  stub pkexec '"$@"'
  stub systemctl
  stub nova-undervolt 'echo "the status"'
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

undervolt() { "$REPO_ROOT/src/cli/bin/nova-power-undervolt" "$@"; }

# A systemctl whose start puts the offset on a fake CPU: its last core at
# 4.8 GHz and 1.100 V less the core's offset, or, with SHARED, less the
# higher of what the core's and the cache's ask for, in IA32_PERF_STATUS. A
# start with the offset MCE_AT logs a machine check: the undervolt is held.
fake_cpu() {
  export FAKE_MSR="$SCRATCH/msr/$(($(nproc --all) - 1))/msr"
  mkdir -p "$(dirname "$FAKE_MSR")"
  truncate -s 4096 "$FAKE_MSR"
  export NOVA_UNDERVOLT_MSR="$SCRATCH/msr"
  cat >"$SCRATCH/bin/systemctl" <<'FAKE'
#!/bin/bash
echo "systemctl $*" >>"$CALLS"
[[ $1 == start ]] || exit 0
read -r core cache <"$NOVA_UNDERVOLT_STATE/offset"
cache=${cache:-$core}
[[ "$core $cache" != "${MCE_AT:-}" ]] || echo "a machine check" >"$NOVA_UNDERVOLT_STATE/held"
mv=$core
[[ -z ${SHARED:-} ]] || ((cache < core)) || mv=$cache
raw=$(((1100 + mv) * 8192 / 1000))
hex=$(printf '%016x' $(((raw << 32) | (48 << 8))))
bytes=
for ((i = 14; i >= 0; i -= 2)); do bytes+="\\x${hex:i:2}"; done
printf "$bytes" | dd of="$FAKE_MSR" bs=1 seek=$((0x198)) conv=notrunc status=none
FAKE
  chmod +x "$SCRATCH/bin/systemctl"
  stub nova-undervolt '[[ -e $NOVA_UNDERVOLT_STATE/held ]] && echo "{\"state\":\"held\"}" || echo "{\"state\":\"applied\"}"'
  stub taskset
  stub sleep
  stub modprobe
  mkdir -p "$NOVA_UNDERVOLT_STATE"
  echo -70 >"$NOVA_UNDERVOLT_STATE/offset"
}

@test "with nothing else, it says what is set" {
  run undervolt
  [ "$status" -eq 0 ]
  [ "$output" = "the status" ]
  run undervolt status --json
  grep -qx 'nova-undervolt status --json' "$CALLS"
}

@test "set: the offset is written and applied as root, the old one off first" {
  mkdir -p "$NOVA_UNDERVOLT_STATE"
  echo "the reason" >"$NOVA_UNDERVOLT_STATE/held"
  run undervolt set -70
  [ "$status" -eq 0 ]
  [ "$(cat "$NOVA_UNDERVOLT_STATE/offset")" = -70 ]
  [ ! -e "$NOVA_UNDERVOLT_STATE/held" ]
  [ "$(grep -v '^nova-undervolt' "$CALLS" | paste -sd '|')" = "pkexec $NOVA_POWER_UNDERVOLT_APPLY set -70|systemctl stop nova-undervolt.service|systemctl start nova-undervolt.service" ]
  [[ $output == *"the status"* ]]
}

@test "set takes only a whole number of millivolts from -150 to -1" {
  for bad in 70 -0 -070 -151 -1000 -7.5 abc ''; do
    run "$NOVA_POWER_UNDERVOLT_APPLY" set "$bad"
    [ "$status" -eq 1 ]
    [[ $output == *"from -150 to -1"* ]]
  done
  [ ! -e "$NOVA_UNDERVOLT_STATE/offset" ]
  fails grep -q systemctl "$CALLS"
  run "$NOVA_POWER_UNDERVOLT_APPLY" set -150
  [ "$status" -eq 0 ]
}

@test "set: the core's and the cache's, each from -150 to 0, and not both 0" {
  run undervolt set -80 -70
  [ "$status" -eq 0 ]
  [ "$(cat "$NOVA_UNDERVOLT_STATE/offset")" = "-80 -70" ]
  run undervolt set -60 -60
  [ "$(cat "$NOVA_UNDERVOLT_STATE/offset")" = -60 ]
  run undervolt set -50 0
  [ "$(cat "$NOVA_UNDERVOLT_STATE/offset")" = "-50 0" ]
  for bad in "0 0" "-80 5" "-151 -70" "-80 -070" "-80 abc"; do
    # shellcheck disable=SC2086 # two numbers
    run "$NOVA_POWER_UNDERVOLT_APPLY" set $bad
    [ "$status" -eq 1 ]
    [[ $output == *"the core's and the cache's"* ]]
  done
  [ "$(cat "$NOVA_UNDERVOLT_STATE/offset")" = "-50 0" ]
}

@test "compare: a core whose offset is its own runs lower with it" {
  fake_cpu
  run undervolt compare -80 -70
  [ "$status" -eq 0 ]
  [[ $output == *"At 4.8 GHz, 40 readings each:"* ]]
  [[ $output == *"-70 mV on the core and cache"*"1.0299 V"* ]]
  [[ $output == *"-80 mV on the core, -70 mV on the cache"*"1.0199 V"* ]]
  [[ $output == *"The core ran -10.0 mV of the -10 mV asked: at this load its offset is its own."* ]]
  grep -qx "pkexec $NOVA_POWER_UNDERVOLT_APPLY compare -80 -70" "$CALLS"
  # One core loaded, and the offset set before put back.
  [ "$(grep -c '^taskset' "$CALLS")" = 1 ]
  [ "$(cat "$NOVA_UNDERVOLT_STATE/offset")" = -70 ]
  [ "$(grep systemctl "$CALLS" | tail -2 | paste -sd '|')" = "systemctl stop nova-undervolt.service|systemctl start nova-undervolt.service" ]
}

@test "compare waits for the service to put the offset on" {
  fake_cpu
  # Pending for the first two answers after each start, as the service's
  # start returns before its offset is on.
  mv "$SCRATCH/bin/systemctl" "$SCRATCH/bin/systemctl-real"
  stub systemctl 'systemctl-real "$@"; [[ $1 != start ]] || echo 2 >"$SCRATCH/pending"'
  stub nova-undervolt 'n=$(cat "$SCRATCH/pending" 2>/dev/null || echo 0)
    if ((n > 0)); then echo $((n - 1)) >"$SCRATCH/pending"; echo "{\"state\":\"pending\"}"; else echo "{\"state\":\"applied\"}"; fi'
  run undervolt compare -80 -70
  [ "$status" -eq 0 ]
  [[ $output == *"its offset is its own"* ]]
}

@test "compare: a core the cache holds up does not move" {
  fake_cpu
  SHARED=1 run undervolt compare -80 -70
  [ "$status" -eq 0 ]
  [[ $output == *"The core ran +0.0 mV of the -10 mV asked: the cache held it up, as they share one voltage at this load."* ]]
}

@test "compare: the disk has the undervolt set now while the other one runs" {
  fake_cpu
  stub sleep 'cat "$NOVA_UNDERVOLT_STATE/offset" >>"$SCRATCH/on-disk"'
  run undervolt compare -80 -70
  [ "$status" -eq 0 ]
  [[ $output == *"its offset is its own"* ]]
  [ "$(sort -u "$SCRATCH/on-disk")" = -70 ]
}

@test "compare --all loads every core" {
  fake_cpu
  run undervolt compare -80 -70 --all
  [ "$status" -eq 0 ]
  [ "$(grep -c '^taskset' "$CALLS")" = "$(nproc --all)" ]
}

@test "compare: a machine check stops it, held, with the offset set before back" {
  fake_cpu
  MCE_AT="-80 -70" run undervolt compare -80 -70
  [ "$status" -eq 1 ]
  [[ $output == *"the undervolt is held"* ]]
  [ -e "$NOVA_UNDERVOLT_STATE/held" ]
  [ "$(cat "$NOVA_UNDERVOLT_STATE/offset")" = -70 ]
}

@test "compare needs the undervolt set now on the CPU, and another to compare" {
  fake_cpu
  run undervolt compare -70 -70
  [ "$status" -eq 1 ]
  [[ $output == *"that is the undervolt set now"* ]]
  echo "a freeze" >"$NOVA_UNDERVOLT_STATE/held"
  run undervolt compare -80 -70
  [ "$status" -eq 1 ]
  [[ $output == *"not on the CPU"* ]]
  rm "$NOVA_UNDERVOLT_STATE/offset" "$NOVA_UNDERVOLT_STATE/held"
  run undervolt compare -80 -70
  [ "$status" -eq 1 ]
  [[ $output == *"set the undervolt you have first"* ]]
  fails grep -q '^taskset' "$CALLS"
}

@test "on applies the offset again after a hold; with none set, it says so" {
  run undervolt on
  [ "$status" -eq 1 ]
  [[ $output == *"no undervolt is set"* ]]
  mkdir -p "$NOVA_UNDERVOLT_STATE"
  echo -70 >"$NOVA_UNDERVOLT_STATE/offset"
  echo "a freeze" >"$NOVA_UNDERVOLT_STATE/held"
  run undervolt on
  [ "$status" -eq 0 ]
  [ ! -e "$NOVA_UNDERVOLT_STATE/held" ]
  [ "$(cat "$NOVA_UNDERVOLT_STATE/offset")" = -70 ]
  grep -qx 'systemctl start nova-undervolt.service' "$CALLS"
}

@test "on says what is on once the service has put it there, not while it starts" {
  mkdir -p "$NOVA_UNDERVOLT_STATE"
  echo -70 >"$NOVA_UNDERVOLT_STATE/offset"
  stub sleep
  echo 2 >"$SCRATCH/pending"
  stub nova-undervolt 'n=$(cat "$SCRATCH/pending"); if [[ $1 == status && ${2:-} == --json ]] && ((n > 0)); then echo $((n - 1)) >"$SCRATCH/pending"; echo "{\"state\":\"pending\"}"
    elif [[ ${2:-} == --json ]]; then echo "{\"state\":\"applied\"}"; else echo "on the CPU"; fi'
  run undervolt on
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "on the CPU" ]
  [ "$(grep -c 'status --json' "$CALLS")" = 3 ]
}

@test "off takes it off, then forgets it" {
  mkdir -p "$NOVA_UNDERVOLT_STATE"
  echo -70 >"$NOVA_UNDERVOLT_STATE/offset"
  run undervolt off
  [ "$status" -eq 0 ]
  [ ! -e "$NOVA_UNDERVOLT_STATE/offset" ]
  grep -qx 'systemctl stop nova-undervolt.service' "$CALLS"
  ! grep -q 'systemctl start' "$CALLS"
}

@test "a password not given changes nothing and says nothing more" {
  stub pkexec 'exit 126'
  run undervolt set -70
  [ "$status" -eq 126 ]
  [ ! -e "$NOVA_UNDERVOLT_STATE/offset" ]
  ! grep -q '^nova-undervolt' "$CALLS"
}

@test "anything else is a usage error" {
  run undervolt set
  [ "$status" -eq 2 ]
  run undervolt status --yaml
  [ "$status" -eq 2 ]
  run undervolt deeper
  [ "$status" -eq 2 ]
}
