#!/bin/bash
# omarchy-limine-theme rewrites the file that decides whether this machine
# boots, with an awk program. So it gets driven against a real limine.conf
# shape here rather than tried on /boot.
#
# "A real shape" is the point. The first version of this suite used a clean
# limine.conf with no colours in it, passed everything, and shipped a tool that
# did nothing on the actual machine: Omarchy writes its own Tokyo Night globals
# at the top of the file, Limine honours the first definition of a duplicated
# key, and our block was further down. The fixture now carries that block.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
TOOL=$HERE/../bin/omarchy-limine-theme
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fail=0
chk() {
  if [[ $2 == "$3" ]]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s: got %q want %q\n' "$1" "$2" "$3"; fail=1; fi
}

# Omarchy's default/limine/limine.conf globals, verbatim, then limine-entry-tool
# entries below them. `term_background: deadbe` inside the first entry is not
# something Omarchy writes — it is there to catch a rewrite that reaches past
# the first '/', where an option belongs to that entry and is none of our
# business.
fixture() {
  cat >"$T/limine.conf" <<'EOF'
### Read more at config document: https://github.com/limine-bootloader/limine/blob/trunk/CONFIG.md
#timeout: 3
default_entry: 2
interface_branding: Omarchy Bootloader
interface_branding_color: 9ece6a
interface_help_color: 9ece6a
interface_help_color_bright: 9ece6a
hash_mismatch_panic: no

term_background: 1a1b26
backdrop: 1a1b26

# Terminal colors (Tokyo Night palette)
term_palette: 15161e;f7768e;9ece6a;e0af68;7aa2f7;bb9af7;7dcfff;a9b1d6
term_palette_bright: 414868;f7768e;9ece6a;e0af68;7aa2f7;bb9af7;7dcfff;c0caf5

# Text colors
term_foreground: c0caf5
term_foreground_bright: c0caf5
term_background_bright: 24283b

/Omarchy
    comment: machine-id=aea39391a91545dfb5c3d7bd87c43ce0
    term_background: deadbe
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
# Only the globals: everything above the first entry.
globals() { awk '/^\// { exit } { print }' "$T/limine.conf"; }
# How many times an option is defined and still live in the globals.
live() { globals | grep -cE "^[[:blank:]]*($1)[[:blank:]]*:"; }

fixture
run white
chk "applies cleanly"          "$?" "0"
# Two, not three: limine-entry-tool indents sub-entries, so only the top-level
# /Omarchy and /+Snapshots start at column 0. The count is a sanity check that
# the rewrite dropped nothing, so it only has to be consistent with itself.
chk "entry count preserved"    "$(grep -c '^/' "$T/limine.conf")" "2"
chk "one marker block"         "$(grep -c 'omarchy-limine-theme >>>' "$T/limine.conf")" "1"
chk "background from theme"    "$(globals | sed -n 's/^term_background: //p')" "ffffff"
chk "foreground from theme"    "$(globals | sed -n 's/^term_foreground: //p')" "000000"
chk "accent on the branding"   "$(globals | sed -n 's/^interface_branding_colour: //p')" "6e6e6e"

# The bug. Omarchy's colours are above ours and Limine honours the first
# definition, so every one of them has to stop being a definition.
chk "omarchy's background superseded" \
  "$(globals | grep -c '^#omarchy-limine-theme:superseded# term_background: 1a1b26')" "1"
chk "the color/colour alias too" \
  "$(globals | grep -c '^#omarchy-limine-theme:superseded# interface_branding_color: 9ece6a')" "1"
chk "and its help colours" \
  "$(globals | grep -c '^#omarchy-limine-theme:superseded# interface_help_color')" "2"

# What the tool promises: one live definition of each colour option, no more.
for option in term_background term_background_bright term_foreground \
  term_foreground_bright backdrop term_palette term_palette_bright \
  'interface_branding_colour|interface_branding_color' \
  'interface_help_colour|interface_help_color' \
  'interface_help_colour_bright|interface_help_color_bright'; do
  chk "one live ${option%%|*}" "$(live "$option")" "1"
done

# Not a colour, not ours: the branding text must survive untouched.
chk "branding text untouched" "$(globals | grep -c '^interface_branding: Omarchy Bootloader')" "1"
# Below the first '/' an option belongs to that entry.
chk "entry options untouched"  "$(grep -c '^    term_background: deadbe' "$T/limine.conf")" "1"

# Globals after the first '/' would be parsed as options of that entry, not as
# global settings. This is the assertion that matters most.
first_entry=$(grep -n '^/' "$T/limine.conf" | head -1 | cut -d: -f1)
marker=$(grep -n 'omarchy-limine-theme >>>' "$T/limine.conf" | cut -d: -f1)
chk "block sits above first entry" "$((marker < first_entry))" "1"

cp "$T/limine.conf" "$T/first.conf"
run white
chk "re-running changes nothing" "$(diff -q "$T/first.conf" "$T/limine.conf" >/dev/null && echo same)" "same"
chk "and does not re-comment"    "$(grep -c 'superseded# #omarchy' "$T/limine.conf")" "0"

run tokyo-night
chk "switching replaces block"   "$(grep -c 'omarchy-limine-theme >>>' "$T/limine.conf")" "1"
chk "switching recolours"        "$(globals | sed -n 's/^term_background: //p')" "1a1b26"
chk "switching keeps entries"    "$(grep -c '^/' "$T/limine.conf")" "2"
chk "switching keeps one live"   "$(live term_background)" "1"
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
chk "and supersedes nothing"         "$(live term_background)" "1"

fixture
cp "$T/limine.conf" "$T/orig.conf"
run white
chk "backs up the original"          "$(diff -q "$T/orig.conf" "$T/limine.conf.omarchy-limine-theme.bak" >/dev/null && echo same)" "same"
run tokyo-night
chk "backup is not overwritten"      "$(diff -q "$T/orig.conf" "$T/limine.conf.omarchy-limine-theme.bak" >/dev/null && echo same)" "same"

# The boot hook runs as root, where $HOME is /root and $OMARCHY_PATH is unset.
# omarchy-theme-dir then returns "/themes/<slug>" and the tool failed on a path
# that never existed. This is that environment, exactly.
fixture
HOME=/root OMARCHY_PATH= LIMINE_CONF=$T/limine.conf "$TOOL" white >"$T/out" 2>&1
chk "works with root's environment" "$?" "0"
chk "and still finds the colours"   "$(globals | sed -n 's/^term_background: //p')" "ffffff"

# A slug that exists nowhere must still be refused, not resolved to something.
fixture
HOME=/root OMARCHY_PATH= LIMINE_CONF=$T/limine.conf "$TOOL" nope >"$T/out" 2>&1
chk "still refuses an unknown slug" "$?" "1"
chk "and names both search paths"   "$(grep -c 'looked in' "$T/out")" "1"

echo
if ((fail)); then echo "FAILURES"; exit 1; else echo "all pass"; fi
