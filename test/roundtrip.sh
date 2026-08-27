#!/bin/bash
# Every tunable saves the firmware's value on the way to battery and puts it
# back on AC. That is easy to get wrong in ways nothing notices until you
# unplug for a week — the runtime-PM state file was truncated on every battery
# run for a while, so AC had nothing to restore and nobody saw it.
#
# The functions read their paths from globals, so the test points them at
# temporary files and drives the round trips directly. No root, no sysfs.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
TOOL=$HERE/../bin/thinkpad-power
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# Everything above the dispatch is the library half.
sed '/^cmd=\${1:-auto}/,$d' "$TOOL" > "$T/lib.sh"
grep -q '^aspm()' "$T/lib.sh" || { echo "could not extract the library half of $TOOL"; exit 1; }
CONFIG=/dev/null . "$T/lib.sh"

fail=0
chk() {
  if [[ $2 == "$3" ]]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s: got %q want %q\n' "$1" "$2" "$3"; fail=1; fi
}

ASPM_ON_BAT=powersave ASPM_POLICY=$T/aspm ASPM_STATE=$T/aspm.state
echo '[default] performance powersave powersupersave' >"$ASPM_POLICY"
aspm battery
chk "aspm battery writes policy"   "$(cat "$ASPM_POLICY")" "powersave"
chk "aspm battery saves original"  "$(cat "$ASPM_STATE")"  "default"
aspm battery
chk "aspm battery idempotent"      "$(cat "$ASPM_STATE")"  "default"
aspm ac
chk "aspm ac restores"             "$(cat "$ASPM_POLICY")" "default"
chk "aspm ac clears state"         "$([[ -e $ASPM_STATE ]] && echo yes || echo no)" "no"

NMI_WATCHDOG_ON_BAT=off NMI_WATCHDOG=$T/nmi NMI_STATE=$T/nmi.state
echo 1 >"$NMI_WATCHDOG"
nmi_watchdog battery
chk "nmi battery disables"         "$(cat "$NMI_WATCHDOG")" "0"
nmi_watchdog ac
chk "nmi ac restores"              "$(cat "$NMI_WATCHDOG")" "1"

PL1_ON_BAT=30 RAPL_PL1=$T/pl1 RAPL_WINDOW=$T/win RAPL_STATE=$T/rapl.state
echo 109000000 >"$RAPL_PL1"; echo 55967744 >"$RAPL_WINDOW"
power_limit battery
chk "pl1 battery sets limit"       "$(cat "$RAPL_PL1")"    "30000000"
chk "pl1 battery shortens window"  "$(cat "$RAPL_WINDOW")" "10000000"
power_limit ac
chk "pl1 ac restores limit"        "$(cat "$RAPL_PL1")"    "109000000"
chk "pl1 ac restores window"       "$(cat "$RAPL_WINDOW")" "55967744"

# A bad wattage must be refused, not applied: this runs as root against a
# register that decides how much power the package may draw.
for bad in 2 abc -5 ''; do
  PL1_ON_BAT=$bad; echo 109000000 >"$RAPL_PL1"
  power_limit battery >/dev/null 2>&1
  chk "pl1 refuses '$bad'"         "$(cat "$RAPL_PL1")"    "109000000"
done

echo
if ((fail)); then echo "FAILURES"; exit 1; else echo "all pass"; fi
