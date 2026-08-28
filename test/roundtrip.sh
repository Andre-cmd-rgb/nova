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

# doctor's boot figures. An awk program printed a label and no number for two
# commits because the only run during development hit the root guard, so
# anything with awk in it gets driven against real input here. efivarfs puts
# four attribute bytes in front of the value, which is the part that is easy
# to be off by one on.
EFIVARS=$T/efivars; mkdir -p "$EFIVARS"
efivar() { printf '\x07\x00\x00\x00%s' "$2" >"$EFIVARS/$1-8be4df61-93ca-11d2-aa0d-00e098032b8c"; }

efivar LoaderTimeInitUSec 11496098
efivar LoaderTimeExecUSec 20604018
chk "boot firmware figure"  "$(boot_timing | sed -n 1p)" "    firmware (POST)         11.50 s"
chk "boot loader figure"    "$(boot_timing | sed -n 2p)" "    boot loader              9.11 s"

# Nothing to print is a legitimate answer, and must not be a blank number.
rm -f "$EFIVARS"/LoaderTimeExecUSec-*
chk "boot half-recorded"    "$(boot_timing; echo "rc=$?")" "rc=1"
rm -f "$EFIVARS"/LoaderTime*
chk "boot unrecorded"       "$(boot_timing; echo "rc=$?")" "rc=1"

# Firmware can write anything into an efivar; a garbage value must not reach awk.
efivar LoaderTimeInitUSec 11496098
efivar LoaderTimeExecUSec 'not-a-number'
chk "boot rejects garbage"  "$(boot_timing; echo "rc=$?")" "rc=1"
efivar LoaderTimeExecUSec 900
chk "boot rejects backwards" "$(boot_timing; echo "rc=$?")" "rc=1"

echo
if ((fail)); then echo "FAILURES"; exit 1; else echo "all pass"; fi
