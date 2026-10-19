#!/bin/bash
# omarchy-splash-wallpaper rewrites two files it does not own — Omarchy's
# Plymouth script and its SDDM Main.qml — and both are regenerated from
# upstream defaults behind its back, so its edits have to be re-appliable and
# idempotent. It also has to survive the shapes of those upstream files
# changing, by refusing rather than by writing something broken.
#
# Driven against fixture directories, never against /usr/share, and with the
# initramfs rebuild stubbed out.
set -uo pipefail
HERE=$(cd -- "$(dirname -- "$0")" && pwd)
TOOL=$HERE/../bin/omarchy-splash-wallpaper
OMARCHY=${OMARCHY_PATH:-/usr/share/omarchy}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fail=0
chk() {
  if [[ $2 == "$3" ]]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s: got %q want %q\n' "$1" "$2" "$3"; fail=1; fi
}

command -v magick >/dev/null 2>&1 || { echo "skipped: ImageMagick missing"; exit 0; }
[[ -r $OMARCHY/default/plymouth/omarchy.script ]] ||
  { echo "skipped: no Omarchy Plymouth default to work from"; exit 0; }

# A home with the state layout omarchy-theme-bg-set maintains, and the two
# upstream files as this machine actually ships them.
setup() {
  rm -rf "$T/root"
  mkdir -p "$T/root/home/.local/state/omarchy/current" "$T/root/ply" \
    "$T/root/sddm" "$T/root/state" "$T/root/pics"
  # A band of content across the middle third, the shape of a wordmark
  # wallpaper: the offset measurement has something to find.
  magick -size 400x300 xc:'#3355ff' -fill '#ffffff' \
    -draw 'rectangle 100,120 300,180' "$T/root/pics/wall.png"
  printf 'white\n' >"$T/root/home/.local/state/omarchy/current/theme.name"
  ln -nsf "$T/root/pics/wall.png" "$T/root/home/.local/state/omarchy/current/background"
  cp "$OMARCHY/default/plymouth/omarchy.script" "$T/root/ply/omarchy.script"
  cp "$OMARCHY/default/sddm/omarchy/Main.qml" "$T/root/sddm/Main.qml"
  pristine_lua >"$T/root/hyprland.lua"
}

# Upstream's greeter config as it ships, never as this machine currently has it.
# Once installed, /usr/share/sddm/hyprland.lua carries the line this tool writes,
# and a fixture copied straight from it is already themed -- so "a package
# upgrade put the original back" was not being tested at all.
pristine_lua() { awk '!index($0, "-- omarchy-boot-theme")' /usr/share/sddm/hyprland.lua; }

# env -i is the point of this, not tidiness. The tool only ever runs as root
# under sudo, and sudo does not pass the session environment through. Verifying
# the greeter config with Hyprland worked perfectly in a developer shell and did
# nothing at all under sudo, because XDG_RUNTIME_DIR was gone and Hyprland dies
# on that before it reads a config -- and the suite could not see it, because
# the suite was handing the tool an environment root never has. So it stops
# doing that.
run() {
  env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root \
    OMARCHY_PLYMOUTH_DIR=$T/root/ply \
    OMARCHY_SDDM_DIR=$T/root/sddm \
    OMARCHY_BOOT_THEME_STATE=$T/root/state \
    OMARCHY_SPLASH_GEOMETRY=640x480 \
    OMARCHY_GREETER_LUA=$T/root/hyprland.lua \
    OMARCHY_MKINITCPIO=true \
    "$TOOL" --home "$T/root/home" "$@" >"$T/out" 2>&1
}
ply() { cat "$T/root/ply/omarchy.script"; }
qml() { cat "$T/root/sddm/Main.qml"; }
lua() { cat "$T/root/hyprland.lua"; }

setup
run
chk "applies cleanly"            "$?" "0"

# ---- the wallpaper itself
chk "background rendered"        "$([[ -f $T/root/ply/background.png ]] && echo yes)" "yes"
chk "at the screen geometry"     "$(magick identify -format '%wx%h' "$T/root/ply/background.png")" "640x480"
chk "sddm gets the same image"   "$(cmp -s "$T/root/ply/background.png" "$T/root/sddm/background.png" && echo same)" "same"

# ---- plymouth
chk "one plymouth block"         "$(ply | grep -c '>>> omarchy-boot-theme >>>')" "1"
chk "draws the background"       "$(ply | grep -c 'background.sprite.SetPosition(0, 0, -100)')" "1"
chk "hides the theme logo"       "$(ply | grep -c 'logo.sprite.SetOpacity(0)')" "1"
# Behind everything: the dialogue sits at z 10001 and the progress bar at 0.
chk "background is behind"       "$(ply | grep -c 'SetPosition(0, 0, -100)')" "1"

# ---- sddm: the colour bug this exists to fix
# omarchy-plymouth-set writes #1a1b26 -> #ffffff -> #000000 with two sequential
# seds, so the White theme gets a black login screen. It must come out white.
chk "login background is white"  "$(qml | sed -n '/^  color:/p' | tr -d ' ')" 'color:"#ffffff"'
chk "wallpaper behind the login" "$(qml | grep -c 'source: "background.png"')" "1"
chk "and it fills the screen"    "$(qml | grep -c 'fillMode: Image.PreserveAspectCrop')" "1"
chk "logo dropped"               "$(qml | grep -c 'id: logo')" "0"

# The password box used to sit on top of the wallpaper's branding, because both
# are centred. The fixture's band ends at y=180 of 300, so the box belongs below
# 0.6 of the height -- and centerIn must be gone, since QML refuses it next to
# an explicit verticalCenter.
chk "box moved off centre"       "$(qml | grep -c 'anchors.verticalCenterOffset')" "1"
chk "entry keeps its centerIn"   "$(qml | grep -c 'anchors.centerIn: parent')" "1"
# One scale on the prompt Row rather than four separate sizes, so the lock, the
# box, the bullets and the text stay in proportion.
chk "prompt scaled down"         "$(qml | grep -c 'scale: 0.85')" "1"
chk "on the prompt Row"          "$(qml | grep -A1 -E '^    Row \{' | grep -c 'scale: 0.85')" "1"
chk "below the branding"         "$(qml | sed -n 's/.*parent.height \* \([0-9.]*\)).*/\1/p' |
                                    awk '{ print ($1 > 0.05 && $1 < 0.32) ? "yes" : "no " $1 }')" "yes"
# The password field, lock and bullet images must all have survived the cut.
chk "entry survived"             "$(qml | grep -c 'id: entry')" "1"
chk "password survived"          "$(qml | grep -c 'id: password')" "1"
chk "qml braces balance"         "$(qml | tr -cd '{' | wc -c)" "$(qml | tr -cd '}' | wc -c)"

# ---- the greeter compositor, which is what the black gap actually was
chk "greeter background themed"  "$(lua | grep -c 'background_color = "rgb(ffffff)"')" "1"
chk "inside the misc block"      "$(lua | awk '/misc[[:space:]]*=/ { n = NR } /background_color/ { print NR - n }')" "1"
chk "upstream keys kept"         "$(lua | grep -c 'disable_hyprland_logo')" "1"

# ---- doing nothing when nothing changed, since the cost is an initramfs
cp "$T/root/ply/omarchy.script" "$T/first.script"
cp "$T/root/sddm/Main.qml" "$T/first.qml"
run
chk "second run is a no-op"      "$(grep -c 'already on this wallpaper' "$T/out")" "1"
chk "plymouth untouched"         "$(diff -q "$T/first.script" "$T/root/ply/omarchy.script" >/dev/null && echo same)" "same"
chk "main.qml untouched"         "$(diff -q "$T/first.qml" "$T/root/sddm/Main.qml" >/dev/null && echo same)" "same"
run --force
chk "--force runs anyway"        "$(grep -c 'already on this wallpaper' "$T/out")" "0"
chk "and is still idempotent"    "$(diff -q "$T/first.script" "$T/root/ply/omarchy.script" >/dev/null && echo same)" "same"

# A new wallpaper is work again, and only one block comes out of it.
magick -size 400x300 xc:'#ff3355' "$T/root/pics/other.png"
ln -nsf "$T/root/pics/other.png" "$T/root/home/.local/state/omarchy/current/background"
run
chk "a new wallpaper re-runs"    "$(grep -c 'already on this wallpaper' "$T/out")" "0"
chk "still one plymouth block"   "$(ply | grep -c '>>> omarchy-boot-theme >>>')" "1"
chk "still one background image" "$(qml | grep -c 'source: "background.png"')" "1"

# omarchy-plymouth-set rewrites both files from Omarchy's defaults whenever a
# theme changes, which silently removes this. The stamp would still read
# current, so the installed state has to be checked too.
setup
run
cp "$OMARCHY/default/plymouth/omarchy.script" "$T/root/ply/omarchy.script"
run
chk "notices its block was wiped" "$(ply | grep -c '>>> omarchy-boot-theme >>>')" "1"

# A wallpaper can legitimately be an animated GIF, and ImageMagick writes one
# numbered file per frame unless told which frame to take — so background.png
# would never be created and the whole thing would fail on a valid wallpaper.
setup
magick -delay 10 -size 200x150 xc:red xc:green xc:blue "$T/root/pics/anim.gif" 2>/dev/null
ln -nsf "$T/root/pics/anim.gif" "$T/root/home/.local/state/omarchy/current/background"
run
chk "takes one frame from a GIF" "$?" "0"
chk "and writes exactly one file" "$(ls "$T/root/ply" | grep -c '^background')" "1"
chk "at the screen geometry"      "$(magick identify -format '%wx%h' "$T/root/ply/background.png")" "640x480"

# Transparency flattened onto the theme background, not onto ImageMagick's
# default white, which is wrong on every dark theme. tokyo-night is #1a1b26.
setup
magick -size 200x150 xc:none "$T/root/pics/clear.png"
ln -nsf "$T/root/pics/clear.png" "$T/root/home/.local/state/omarchy/current/background"
run --theme tokyo-night
chk "alpha flattened to the theme" "$(magick "$T/root/ply/background.png" -format '%[pixel:p{5,5}]' info:)" "srgb(26,27,38)"
chk "and the image is opaque"      "$(magick "$T/root/ply/background.png" -format '%[opaque]' info:)" "True"

# The login screen has to stay valid QML. A Main.qml that will not parse is a
# login screen nobody can type into.
if [[ -x /usr/lib/qt6/bin/qmllint ]]; then
  setup
  run
  chk "generated Main.qml is valid QML" \
    "$(/usr/lib/qt6/bin/qmllint "$T/root/sddm/Main.qml" 2>&1 | grep -c '^Error:')" "0"
  # No worse than the file it came from, so a warning upstream already had does
  # not read as one this introduced.
  chk "and no worse than upstream's" \
    "$(/usr/lib/qt6/bin/qmllint "$T/root/sddm/Main.qml" 2>&1 | grep -c '^Warning:')" \
    "$(/usr/lib/qt6/bin/qmllint "$OMARCHY/default/sddm/omarchy/Main.qml" 2>&1 | grep -c '^Warning:')"
fi

# The greeter compositor config has the same property: a file that will not
# parse is a login screen that never appears. Hyprland can check it without
# being run, so there is no reason to guess.
if command -v Hyprland >/dev/null 2>&1; then
  setup
  run
  chk "generated greeter config parses" \
    "$(Hyprland --verify-config --config "$T/root/hyprland.lua" 2>&1 | grep -c 'config ok')" "1"
fi

# Changing the tool has to reapply, even when the theme, the wallpaper and the
# screen are all identical. Without this the stamp reports "already on this
# wallpaper" and the new output never lands -- which is exactly what happened
# when the password box moved and nothing changed on the machine.
setup
run
chk "first run applies"             "$(grep -c 'already on this wallpaper' "$T/out")" "0"
run
chk "unchanged tool is a no-op"     "$(grep -c 'already on this wallpaper' "$T/out")" "1"
# A copy of the tool that differs only in a comment is still a different tool.
sed '2i # a change to how this generates its output' "$TOOL" >"$T/tool2"
chmod 755 "$T/tool2"
# Plain assignments, not "VAR=x run": whether a prefix assignment on a function
# call survives the call is exactly the kind of bash corner this should not rest
# on, and it does not behave the same everywhere.
saved_tool=$TOOL
TOOL=$T/tool2
run
chk "a changed tool reapplies"      "$(grep -c 'already on this wallpaper' "$T/out")" "0"
chk "but does not rebuild for it"   "$(grep -c 'no initramfs rebuild needed' "$T/out")" "1"
TOOL=$saved_tool

# The initramfs is the slow part and only carries the Plymouth files, so a run
# that changes only the greeter config -- which is what an omarchy-settings
# upgrade putting its own file back looks like -- must not rebuild it.
setup
run
pristine_lua >"$T/root/hyprland.lua"
run
chk "notices the greeter reverted"  "$(grep -c 'already on this wallpaper' "$T/out")" "0"
chk "and writes the line back"      "$(lua | grep -c 'background_color')" "1"
chk "without rebuilding anything"   "$(grep -c 'no initramfs rebuild needed' "$T/out")" "1"
# --force is the escape hatch for an initramfs that is not trusted, so it has to
# rebuild even when nothing on disk changed.
run --force
chk "--force rebuilds regardless"   "$(grep -c 'no initramfs rebuild needed' "$T/out")" "0"
chk "and rebuilds it"               "$(grep -c 'rebuilding the initramfs' "$T/out")" "1"

# Two runs inside mkinitcpio at once is a corrupt initramfs, so they serialise
# on a lock. The first holds it for two seconds; the second must wait, not run
# alongside, and must not leave a second block behind.
setup
run
start=$SECONDS
OMARCHY_PLYMOUTH_DIR=$T/root/ply OMARCHY_SDDM_DIR=$T/root/sddm \
  OMARCHY_BOOT_THEME_STATE=$T/root/state OMARCHY_SPLASH_GEOMETRY=640x480 \
  OMARCHY_MKINITCPIO='sleep 2' "$TOOL" --home "$T/root/home" --force >/dev/null 2>&1 &
slow=$!
sleep 0.3
run --force
chk "second run waited for the lock" "$(( SECONDS - start >= 2 ))" "1"
wait $slow
chk "and left one block behind"      "$(ply | grep -c '>>> omarchy-boot-theme >>>')" "1"

# ---- refusals. A broken login screen locks you out of the machine.
setup
grep -v 'logo.sprite' "$OMARCHY/default/plymouth/omarchy.script" >"$T/root/ply/omarchy.script"
run
chk "refuses a script with no logo.sprite" "$?" "1"
chk "and says why"                "$(grep -c 'changed shape' "$T/out")" "1"

setup
ln -nsf "$T/root/pics/gone.png" "$T/root/home/.local/state/omarchy/current/background"
run
chk "refuses a dangling wallpaper" "$?" "1"
chk "and installs nothing"         "$([[ -f $T/root/ply/background.png ]] && echo yes || echo no)" "no"

setup
run --theme definitely-not-a-theme
chk "refuses an unknown theme"     "$?" "1"
chk "and installs nothing"         "$([[ -f $T/root/ply/background.png ]] && echo yes || echo no)" "no"

# An SDDM template that no longer has a logo block to drop means upstream moved,
# and guessing would mean shipping a login screen nobody can type into.
setup
grep -v 'id: logo' "$OMARCHY/default/sddm/omarchy/Main.qml" >"$T/tmpl.qml"
mkdir -p "$T/fake/default/sddm/omarchy"
cp -r "$OMARCHY/default/plymouth" "$T/fake/default/plymouth"
cp "$T/tmpl.qml" "$T/fake/default/sddm/omarchy/Main.qml"
cp -r "$OMARCHY/themes" "$T/fake/themes"
OMARCHY_PATH=$T/fake OMARCHY_PLYMOUTH_DIR=$T/root/ply OMARCHY_SDDM_DIR=$T/root/sddm \
  OMARCHY_BOOT_THEME_STATE=$T/root/state OMARCHY_SPLASH_GEOMETRY=640x480 \
  OMARCHY_MKINITCPIO=true "$TOOL" --home "$T/root/home" >"$T/out" 2>&1
chk "refuses a changed sddm template" "$?" "1"
chk "and leaves Main.qml alone"       "$(qml | grep -c 'source: "background.png"')" "0"

# Same for the Row the prompt lives in. Without it there is nothing to scale,
# and silently skipping would ship a layout nobody asked for.
setup
sed 's/^    Row {/    Rectangle {/' "$OMARCHY/default/sddm/omarchy/Main.qml" >"$T/tmpl2.qml"
mkdir -p "$T/fake2/default/sddm/omarchy"
cp -r "$OMARCHY/default/plymouth" "$T/fake2/default/plymouth"
cp "$T/tmpl2.qml" "$T/fake2/default/sddm/omarchy/Main.qml"
cp -r "$OMARCHY/themes" "$T/fake2/themes"
OMARCHY_PATH=$T/fake2 OMARCHY_PLYMOUTH_DIR=$T/root/ply OMARCHY_SDDM_DIR=$T/root/sddm \
  OMARCHY_BOOT_THEME_STATE=$T/root/state OMARCHY_SPLASH_GEOMETRY=640x480 \
  OMARCHY_GREETER_LUA=$T/root/hyprland.lua \
  OMARCHY_MKINITCPIO=true "$TOOL" --home "$T/root/home" >"$T/out" 2>&1
chk "refuses a template with no prompt Row" "$?" "1"

# The greeter config is upstream's and only costs a dark gap, so a shape it does
# not recognise is a warning and a skip -- never a broken compositor config.
setup
printf 'hl.config({\n  animations = { enabled = false },\n})\n' >"$T/root/hyprland.lua"
run
chk "applies without a misc block"     "$?" "0"
chk "says it left the greeter alone"   "$(grep -c 'no misc block' "$T/out")" "1"
chk "and wrote nothing into it"        "$(lua | grep -c 'background_color')" "0"
chk "greeter config still parses"      "$(Hyprland --verify-config --config "$T/root/hyprland.lua" 2>&1 | grep -c 'config ok')" "1"

# And the other half of that: a greeter config Hyprland genuinely rejects must
# be left alone, not installed. This is the assertion that proves the verifier
# actually ran -- if it cannot reach Hyprland's parser it returns no verdict and
# this file would be installed broken. That is exactly what happened under sudo,
# where XDG_RUNTIME_DIR is gone and Hyprland dies before reading anything.
setup
printf 'hl.config({\n  misc = {\n    disable_hyprland_logo = true,\n' >"$T/root/hyprland.lua"
cp "$T/root/hyprland.lua" "$T/broken-before.lua"
run
chk "still applies"                    "$?" "0"
chk "refuses an unparseable greeter"   "$(grep -c 'will not parse' "$T/out")" "1"
chk "and leaves the file untouched"    "$(diff -q "$T/broken-before.lua" "$T/root/hyprland.lua" >/dev/null && echo same)" "same"

echo
if ((fail)); then echo "FAILURES"; exit 1; else echo "all pass"; fi
