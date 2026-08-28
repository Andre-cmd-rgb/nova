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
  magick -size 400x300 xc:'#3355ff' "$T/root/pics/wall.png"
  printf 'white\n' >"$T/root/home/.local/state/omarchy/current/theme.name"
  ln -nsf "$T/root/pics/wall.png" "$T/root/home/.local/state/omarchy/current/background"
  cp "$OMARCHY/default/plymouth/omarchy.script" "$T/root/ply/omarchy.script"
  cp "$OMARCHY/default/sddm/omarchy/Main.qml" "$T/root/sddm/Main.qml"
}

run() {
  OMARCHY_PLYMOUTH_DIR=$T/root/ply \
  OMARCHY_SDDM_DIR=$T/root/sddm \
  OMARCHY_BOOT_THEME_STATE=$T/root/state \
  OMARCHY_SPLASH_GEOMETRY=640x480 \
  OMARCHY_MKINITCPIO=true \
    "$TOOL" --home "$T/root/home" "$@" >"$T/out" 2>&1
}
ply() { cat "$T/root/ply/omarchy.script"; }
qml() { cat "$T/root/sddm/Main.qml"; }

setup
run
chk "applies cleanly"            "$?" "0"

# ---- the wallpaper itself
chk "background rendered"        "$([[ -f $T/root/ply/background.png ]] && echo yes)" "yes"
chk "at the screen geometry"     "$(magick identify -format '%wx%h' "$T/root/ply/background.png")" "640x480"
chk "sddm gets no image"         "$([[ -e $T/root/sddm/background.png ]] && echo yes || echo no)" "no"

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
# Plain colour, nothing on top of it: the wallpaper branding used to land
# behind the password box, and the logo on top of that.
chk "marked as transformed"      "$(qml | grep -c 'omarchy-boot-theme: plain background')" "1"
chk "no wallpaper on the login"  "$(qml | grep -c 'background.png')" "0"
chk "logo dropped"               "$(qml | grep -c 'id: logo')" "0"
tmpl_images=$(grep -cE '^[[:space:]]*Image[[:space:]]*\{' "$OMARCHY/default/sddm/omarchy/Main.qml")
chk "only the logo image went"   "$(qml | grep -cE '^[[:space:]]*Image[[:space:]]*\{')" "$((tmpl_images - 1))"
# The password field, lock and bullet images must all have survived the cut.
chk "entry survived"             "$(qml | grep -c 'id: entry')" "1"
chk "password survived"          "$(qml | grep -c 'id: password')" "1"
chk "qml braces balance"         "$(qml | tr -cd '{' | wc -c)" "$(qml | tr -cd '}' | wc -c)"

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
chk "login screen still plain"   "$(qml | grep -c 'omarchy-boot-theme: plain background')" "1"

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
chk "and leaves Main.qml alone"       "$(qml | grep -c 'omarchy-boot-theme: plain')" "0"

echo
if ((fail)); then echo "FAILURES"; exit 1; else echo "all pass"; fi
