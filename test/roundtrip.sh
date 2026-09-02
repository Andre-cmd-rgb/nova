#!/bin/bash
#
# batterylife — end-to-end tests against a fake battery and a written history.
#
# Nothing here touches the real machine: the battery is a directory of files,
# and config and history are redirected into a temporary tree. That is what
# makes the awkward cases testable at all — a battery cannot be asked to be
# at 3% and charging on demand, and a suspend cannot be arranged to order.
#
#   bash test/roundtrip.sh

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CLI="$HERE/../bin/batterylife"
[[ -x $CLI ]] || {
  echo "test: $CLI is not executable" >&2
  exit 1
}

FIXTURE=$(mktemp -d) || exit 1
trap 'rm -rf -- "$FIXTURE"' EXIT

export XDG_CONFIG_HOME="$FIXTURE/config"
export XDG_STATE_HOME="$FIXTURE/state"
export BATTERYLIFE_POWER_SUPPLY_DIR="$FIXTURE/power_supply"
DAYS="$XDG_STATE_HOME/omarchy-batterylife/days"

pass=0
fail=0

ok() {
  local what=$1 want=$2 got=$3
  if [[ $want == "$got" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n      want: %s\n      got:  %s\n' "$what" "$want" "$got" >&2
  fi
}

contains() {
  local what=$1 needle=$2 hay=$3
  if [[ $hay == *"$needle"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  %s\n      expected to contain: %s\n      got: %s\n' \
      "$what" "$needle" "$hay" >&2
  fi
}

# ---------------------------------------------------------------- fixtures

# A battery that reports energy, the common case.
battery() {
  local state=$1 energy=$2 power=$3 full=${4:-74480000}
  local dir="$BATTERYLIFE_POWER_SUPPLY_DIR/BAT0"
  mkdir -p -- "$dir"
  printf 'Battery\n' >"$dir/type"
  printf '1\n' >"$dir/present"
  printf '%s\n' "$state" >"$dir/status"
  printf '%s\n' "$energy" >"$dir/energy_now"
  printf '%s\n' "$full" >"$dir/energy_full"
  printf '90090000\n' >"$dir/energy_full_design"
  printf '%s\n' "$power" >"$dir/power_now"
  printf '%s\n' "$((energy * 100 / full))" >"$dir/capacity"
  printf '551\n' >"$dir/cycle_count"
}

no_battery() { rm -rf -- "$BATTERYLIFE_POWER_SUPPLY_DIR"; }

# A row, n seconds before the fixture's idea of now. That is pinned once per
# fixture rather than read per row: a loop of sixty rows takes about a second
# to write, and re-reading the clock each time stretches every span it builds
# by exactly that much.
FIXTURE_NOW=0

# A row, n seconds before now.
row() {
  local ago=$1 state=$2 energy=$3 power=${4:-20000000} full=${5:-74480000}
  local ts day
  ts=$((FIXTURE_NOW - ago))
  day=$(date -d "@$ts" +%F)
  mkdir -p -- "$DAYS"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$state" "$((energy * 100 / full))" "$energy" "$full" "$power" \
    >>"$DAYS/$day.tsv"
}

reset_history() {
  rm -rf -- "$DAYS"
  FIXTURE_NOW=$(date +%s)
}

# History is written newest-last by callers, but a day file is read in
# timestamp order regardless — sort it so the fixtures stay readable.
sort_history() {
  local f
  for f in "$DAYS"/*.tsv; do
    [[ -e $f ]] || continue
    sort -t$'\t' -k1,1n -o "$f" "$f"
  done
}

# ------------------------------------------------------------------- tests

echo "== no battery =="
no_battery
contains "status without a battery" "No battery" "$($CLI status 2>&1)"
ok "json says absent" "false" "$($CLI json 2>/dev/null | jq -c '.present')"

echo "== reading the battery =="
battery Discharging 35590000 18981000
ok "health reports capacity" "0" "$($CLI health >/dev/null 2>&1; echo $?)"
contains "health shows the design figure" "90.1 Wh design" "$($CLI health)"
contains "health shows cycles" "551" "$($CLI health)"

echo "== sampling =="
reset_history
out=$($CLI sample --print)
ok "a sample has six fields" "6" "$(awk -F'\t' '{print NF}' <<<"$out")"
ok "state is recorded" "D" "$(cut -f2 <<<"$out")"
ok "energy is recorded in uWh" "35590000" "$(cut -f4 <<<"$out")"
ok "power is recorded in uW" "18981000" "$(cut -f6 <<<"$out")"

before=$(cat "$DAYS"/*.tsv | wc -l)
$CLI sample; $CLI sample; $CLI sample
ok "samples inside the floor are dropped" "$before" "$(cat "$DAYS"/*.tsv | wc -l)"
$CLI sample --force
ok "--force writes anyway" "$((before + 1))" "$(cat "$DAYS"/*.tsv | wc -l)"

echo "== a plain discharge run =="
# One hour, 20 Wh spent, sampled every minute.
reset_history
for i in $(seq 60 -1 0); do
  row $((i * 60)) D $(( 60000000 - (60 - i) * 333333 ))
done
sort_history
run0=$($CLI json | jq -c '.sessions[0]')
ok "wall clock is the hour" "3600" "$(jq -r '.wall' <<<"$run0")"
ok "runtime is the hour too" "3600" "$(jq -r '.awake' <<<"$run0")"
ok "20 Wh accounted for" "20" "$(jq -r '.wh | round' <<<"$run0")"
ok "which is 20 W" "20" "$($CLI json | jq -r '.sessions[0].watts | round')"
ok "a full charge is 74.48/20 hours" "3h 43m" \
  "$($CLI sessions | awk 'NR==2 { print $(NF-1), $NF }')"

echo "== a suspend in the middle =="
# Same energy, same start and end, but two hours of nothing between.
reset_history
for i in $(seq 30 -1 0); do row $((i * 60 + 7200)) D $(( 60000000 - (30 - i) * 333333 )); done
for i in $(seq 30 -1 0); do row $((i * 60)) D $(( 50000000 - (30 - i) * 333333 )); done
sort_history
wall=$($CLI json | jq -r '.sessions[0].wall')
awake=$($CLI json | jq -r '.sessions[0].awake')
ok "wall clock spans the suspend" "9000" "$wall"
ok "runtime does not" "3600" "$awake"
contains "the suspend is not counted as cheap" "true" \
  "$(awk -v a="$awake" -v w="$wall" 'BEGIN { print (a < w) ? "true" : "false" }')"

echo "== a charge in the middle splits the run =="
reset_history
for i in $(seq 20 -1 0); do row $((i * 60 + 3000)) D $(( 60000000 - (20 - i) * 300000 )); done
for i in $(seq 20 -1 0); do row $((i * 60 + 1500)) C $(( 54000000 + (20 - i) * 400000 )); done
for i in $(seq 20 -1 0); do row $((i * 60)) D $(( 62000000 - (20 - i) * 300000 )); done
sort_history
ok "two runs, not one" "2" "$($CLI json --sessions 20 | jq '[.sessions[]] | length')"

echo "== charging =="
reset_history
for i in $(seq 20 -1 0); do row $((i * 60)) C $(( 30000000 + (20 - i) * 900000 )) 54000000; done
sort_history
battery Charging 48000000 54000000
now=$($CLI json | jq -c '.now')
ok "state is charging" "\"C\"" "$(jq -c '.state' <<<"$now")"
ok "no time-left while charging" "0" "$(jq -c '.timeLeft' <<<"$now")"
ok "no full-charge projection while charging" "0" "$(jq -c '.atRateSeconds' <<<"$now")"
contains "there is a time to full" "true" \
  "$(jq -r '.timeToFull > 0' <<<"$now")"
ok "the fill rate is measured, not the drain average" "54" \
  "$(jq -r '.chargeWatts | round' <<<"$now")"
ok "and that is what gets shown" "54" "$(jq -r '.displayWatts | round' <<<"$now")"

echo "== plugged in and full =="
battery Full 74480000 0
now=$($CLI json | jq -c '.now')
ok "state is full" "\"F\"" "$(jq -c '.state' <<<"$now")"
ok "nothing is being drawn" "0" "$(jq -r '.displayWatts | round' <<<"$now")"
ok "no time to full" "0" "$(jq -c '.timeToFull' <<<"$now")"

echo "== a charge-reporting battery =="
reset_history
rm -rf -- "$BATTERYLIFE_POWER_SUPPLY_DIR"
dir="$BATTERYLIFE_POWER_SUPPLY_DIR/BAT0"
mkdir -p -- "$dir"
printf 'Battery\n' >"$dir/type"
printf '1\n' >"$dir/present"
printf 'Discharging\n' >"$dir/status"
printf '3000000\n' >"$dir/charge_now"      # 3 Ah
printf '5000000\n' >"$dir/charge_full"     # 5 Ah
printf '5000000\n' >"$dir/charge_full_design"
printf '1000000\n' >"$dir/current_now"     # 1 A
printf '15000000\n' >"$dir/voltage_now"    # 15 V
ok "uAh becomes uWh at the pack voltage" "45000000" "$($CLI sample --print | cut -f4)"
ok "uA becomes uW the same way" "15000000" "$($CLI sample --force --print | cut -f6)"

echo "== a device battery is not the system battery =="
mkdir -p -- "$BATTERYLIFE_POWER_SUPPLY_DIR/hidpp_battery_0"
printf 'Battery\n' >"$BATTERYLIFE_POWER_SUPPLY_DIR/hidpp_battery_0/type"
printf 'Device\n' >"$BATTERYLIFE_POWER_SUPPLY_DIR/hidpp_battery_0/scope"
printf '1\n' >"$BATTERYLIFE_POWER_SUPPLY_DIR/hidpp_battery_0/present"
printf '50\n' >"$BATTERYLIFE_POWER_SUPPLY_DIR/hidpp_battery_0/capacity"
ok "a mouse is skipped" "45000000" "$($CLI sample --force --print | cut -f4)"

echo "== the shape of the day and the week =="
battery Discharging 35590000 18981000
reset_history
for i in $(seq 30 -1 0); do row $((i * 60)) D $(( 40000000 - (30 - i) * 300000 )); done
sort_history
ok "twenty-four hours, always" "24" "$($CLI json | jq '.hours | length')"
ok "seven days when seven are asked for" "7" "$($CLI json --days 7 | jq '.days | length')"
ok "an untouched hour reads as untouched" "0" \
  "$($CLI json | jq '[.hours[] | select(.awake == 0)] | length > 0 | if . then 0 else 1 end')"

echo "== settings =="
ok "a default is returned" "300" "$($CLI config GAP_SECONDS)"
ok "a set value comes back" "120" "$($CLI set GAP_SECONDS 120 >/dev/null && $CLI config GAP_SECONDS)"
ok "an unknown key is refused" "1" "$($CLI set NONSENSE 1 >/dev/null 2>&1; echo $?)"
ok "a non-numeric value is refused" "1" "$($CLI set GAP_SECONDS abc >/dev/null 2>&1; echo $?)"
contains "the config listing names every key" "RESPONSE_SECONDS" "$($CLI config)"
$CLI set GAP_SECONDS 300 >/dev/null

echo "== retention and forgetting =="
mkdir -p -- "$DAYS"
: >"$DAYS/2001-01-01.tsv"
$CLI prune
ok "history past the horizon is dropped" "1" \
  "$([[ -e $DAYS/2001-01-01.tsv ]] && echo 0 || echo 1)"
: >"$DAYS/2001-01-02.tsv"
$CLI forget 2001-01-02 >/dev/null
ok "a named day can be forgotten" "1" \
  "$([[ -e $DAYS/2001-01-02.tsv ]] && echo 0 || echo 1)"
$CLI forget all >/dev/null
ok "and so can all of it" "0" "$(cat "$DAYS"/*.tsv 2>/dev/null | wc -l)"

echo "== json stays json with nothing in it =="
ok "an empty history still parses" "0" "$($CLI json >/dev/null 2>&1; echo $?)"
ok "and reports no runs" "0" "$($CLI json | jq '.sessions | length')"

echo
if ((fail == 0)); then
  printf 'all pass (%d checks)\n' "$pass"
else
  printf '%d passed, %d FAILED\n' "$pass" "$fail" >&2
  exit 1
fi
