#!/bin/bash
# omarchy-limine-theme rewrites the file that decides whether this machine
# boots, with an awk program. So it gets driven against a real limine.conf
# shape here rather than tried on /boot: the placement rule (globals must come
# before the first entry, or they belong to that entry instead) is the sort of
# thing that looks right and silently is not.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
TOOL=$HERE/../bin/omarchy-limine-theme
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fail=0
chk() {
  if [[ $2 == "$3" ]]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s: got %q want %q\n' "$1" "$2" "$3"; fail=1; fi
}

fixture() {
  cat >"$T/limine.conf" <<'EOF'
timeout: 5
default_entry: 1
remember_last_entry: yes

/Omarchy
    comment: machine-id=aea39391a91545dfb5c3d7bd87c43ce0
    //Omarchy (linux)
        protocol: efi
        path: boot():/EFI/Linux/omarchy-linux.efi
/+Snapshots
    //2026-08-27 11:11
        protocol: efi
        path: boot():/EFI/Linux/snap-1.efi
EOF
}
run() { LIMINE_CONF=$T/limine.conf "$TOOL" "$@" >"$T/out" 2>&1; }
conf() { cat "$T/limine.conf"; }

fixture
run white
chk "applies cleanly"          "$?" "0"
# Two, not three: limine-entry-tool indents sub-entries, so only the top-level
# /Omarchy and /+Snapshots start at column 0. The count is a sanity check that
# the rewrite dropped nothing, so it only has to be consistent with itself.
chk "entry count preserved"    "$(grep -c '^/' "$T/limine.conf")" "2"
chk "one marker block"         "$(grep -c 'omarchy-limine-theme >>>' "$T/limine.conf")" "1"
chk "background from theme"    "$(sed -n 's/^term_background: //p' "$T/limine.conf")" "00ffffff"
chk "foreground from theme"    "$(sed -n 's/^term_foreground: //p' "$T/limine.conf")" "000000"

# Globals after the first '/' would be parsed as options of that entry, not as
# global settings. This is the assertion that matters most.
first_entry=$(grep -n '^/' "$T/limine.conf" | head -1 | cut -d: -f1)
marker=$(grep -n 'omarchy-limine-theme >>>' "$T/limine.conf" | cut -d: -f1)
chk "block sits above first entry" "$((marker < first_entry))" "1"

cp "$T/limine.conf" "$T/first.conf"
run white
chk "re-running changes nothing" "$(diff -q "$T/first.conf" "$T/limine.conf" >/dev/null && echo same)" "same"

run tokyo-night
chk "switching replaces block"   "$(grep -c 'omarchy-limine-theme >>>' "$T/limine.conf")" "1"
chk "switching recolours"        "$(sed -n 's/^term_background: //p' "$T/limine.conf")" "001a1b26"
chk "switching keeps entries"    "$(grep -c '^/' "$T/limine.conf")" "2"
run white
chk "switching round-trips"      "$(diff -q "$T/first.conf" "$T/limine.conf" >/dev/null && echo same)" "same"

# Refusals. A limine.conf this does not understand must be left alone, not
# half-written: the failure mode is a machine that does not boot.
printf 'timeout: 5\n' >"$T/limine.conf"
run white
chk "refuses a conf with no entries" "$?" "1"
chk "and leaves it untouched"        "$(cat "$T/limine.conf")" "timeout: 5"

fixture
run definitely-not-a-theme
chk "refuses an unknown theme"       "$?" "1"
chk "and leaves the conf untouched"  "$(grep -c 'omarchy-limine-theme' "$T/limine.conf")" "0"

fixture
cp "$T/limine.conf" "$T/orig.conf"
run white
chk "backs up the original"          "$(diff -q "$T/orig.conf" "$T/limine.conf.omarchy-limine-theme.bak" >/dev/null && echo same)" "same"
run tokyo-night
chk "backup is not overwritten"      "$(diff -q "$T/orig.conf" "$T/limine.conf.omarchy-limine-theme.bak" >/dev/null && echo same)" "same"

echo
if ((fail)); then echo "FAILURES"; exit 1; else echo "all pass"; fi
