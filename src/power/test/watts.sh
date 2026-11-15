#!/bin/bash
# The measuring stick. Not part of roundtrip.sh — that runs anywhere in a
# second, and this needs a battery, a discharge, and several minutes.
#
#   ./test/watts.sh            60 s, then the mean draw over the window
#   ./test/watts.sh 300        a longer window, for a quieter number
#
# Two figures come back and they measure different things:
#
#   gauge   energy_now at the start minus energy_now at the end, over the
#           elapsed time. This is the honest one — it is the same arithmetic
#           the battery does — but it needs a window long enough for the
#           charge counter to move past its own quantisation.
#   sampled the mean of power_now, read once a second. It settles faster and
#           tracks a change while you are making it, but it is the firmware's
#           estimate, not a measurement.
#
# They should agree within a few tenths over a few minutes. When they do not,
# believe the gauge.
#
# Whatever is being compared, only one thing may differ between the two runs.
# The panel backlight alone outweighs every tunable in this repo, so hold it
# still, close what you are not testing, and let the machine settle first —
# an unplug leaves the CPU busy for a minute afterwards.
set -uo pipefail

BAT=${BAT:-/sys/class/power_supply/BAT0}
SECONDS_TO_RUN=${1:-60}

[[ $SECONDS_TO_RUN =~ ^[0-9]+$ ]] && ((SECONDS_TO_RUN >= 10)) ||
  { echo "usage: $0 [seconds >= 10]" >&2; exit 1; }
[[ -r $BAT/energy_now ]] ||
  { echo "no energy_now under $BAT — is that the right battery?" >&2; exit 1; }
[[ $(<"$BAT/status") == Discharging ]] ||
  { echo "battery says '$(<"$BAT/status")' — unplug first, this measures a discharge" >&2; exit 1; }

start_uwh=$(<"$BAT/energy_now")
start_ns=$(date +%s%N)

# power_now is sampled rather than integrated, so it needs its own accumulator.
samples=0 total_uw=0
printf 'measuring for %s s' "$SECONDS_TO_RUN"
for ((i = 0; i < SECONDS_TO_RUN; i++)); do
  sleep 1
  uw=$(<"$BAT/power_now") 2>/dev/null || uw=0
  ((uw > 0)) && { total_uw=$((total_uw + uw)); samples=$((samples + 1)); }
  ((i % 10 == 9)) && printf '.'
  # A plug event mid-window invalidates everything measured so far.
  [[ $(<"$BAT/status") == Discharging ]] ||
    { printf '\naborted: the machine was plugged in mid-measurement\n' >&2; exit 1; }
done
printf '\n\n'

end_uwh=$(<"$BAT/energy_now")
end_ns=$(date +%s%N)

awk -v s="$start_uwh" -v e="$end_uwh" -v ns="$((end_ns - start_ns))" \
  -v tot="$total_uw" -v n="$samples" 'BEGIN {
  secs = ns / 1000000000
  printf "  %-10s %6.2f W   (%d uWh over %.1f s)\n", "gauge", \
    (s - e) / 1000000 * 3600 / secs, s - e, secs
  if (n > 0) printf "  %-10s %6.2f W   (%d samples)\n", "sampled", tot / n / 1000000, n
  # A window too short to move the counter reads as a suspiciously round number.
  if (s - e < 2000) print "\n  the charge counter barely moved; use a longer window"
}'
