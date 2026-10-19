#!/bin/bash
#
# Install omarchy-boot-theme.
#
#   ./install.sh              install, and hook it to theme and wallpaper changes
#   ./install.sh --no-hook    install the commands only
#   ./install.sh --uninstall  remove everything, and restore limine.conf
#
# Run as your normal user. The commands themselves call sudo when they run.

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN=${XDG_BIN_HOME:-$HOME/.local/bin}
# The two halves that run as root live here instead. A boot hook and a systemd
# unit both invoke them as root, and root executing a file its owner can
# rewrite hands root to anything running as that user.
SBIN=/usr/local/bin
HOOK_DIR=$HOME/.config/omarchy/hooks/theme-set.d
BOOT_HOOK_DIR=/etc/boot/hooks/post.d
UNIT_DIR=/etc/systemd/system
STATE=${OMARCHY_STATE:-$HOME/.local/state/omarchy}

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  \033[2m·\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die() {
  printf '\033[31mx\033[0m %s\n' "$*" >&2
  exit 1
}
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

HOOK=1
UNINSTALL=0
for arg in "$@"; do
  case $arg in
  --no-hook) HOOK=0 ;;
  --uninstall) UNINSTALL=1 ;;
  -h | --help)
    sed -n '3,8p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    exit 0
    ;;
  *) die "unknown option: $arg (try --help)" ;;
  esac
done

if ((UNINSTALL)); then
  step "Removing omarchy-boot-theme"
  sudo systemctl disable --now omarchy-splash-wallpaper.path 2>/dev/null
  sudo rm -f "$UNIT_DIR/omarchy-splash-wallpaper.path" \
    "$UNIT_DIR/omarchy-splash-wallpaper.service" \
    "$UNIT_DIR/plymouth-quit.service.d/omarchy-boot-theme.conf"
  sudo rmdir "$UNIT_DIR/plymouth-quit.service.d" 2>/dev/null
  sudo systemctl daemon-reload
  rm -f "$BIN/omarchy-boot-theme" "$BIN/omarchy-limine-theme"
  sudo rm -f "$SBIN/omarchy-limine-theme" "$SBIN/omarchy-splash-wallpaper"
  rm -f "$HOOK_DIR/omarchy-boot-theme"
  sudo rm -f "$BOOT_HOOK_DIR/50-omarchy-boot-theme"
  sudo rm -rf /var/lib/omarchy-boot-theme
  ok "commands, hooks and units removed"

  # The splash edits outlive the tool that made them, and nothing else knows
  # what they were. Take the block back out and drop the wallpaper, so what is
  # left is Omarchy's own theme with its own logo waiting for a rebuild.
  PLY=/usr/share/plymouth/themes/omarchy
  # mktemp, not /tmp/name.$$: a predictable path in a world-writable directory
  # is a file anyone on the machine can have pointed somewhere else first.
  tmp=$(mktemp) || die 'mktemp failed'
  trap 'rm -f "$tmp"' EXIT
  if sudo test -f "$PLY/omarchy.script"; then
    sudo awk '
      /^# >>> omarchy-boot-theme >>>$/ { skip = 1; next }
      /^# <<< omarchy-boot-theme <<<$/ { skip = 0; next }
      !skip { print }
    ' "$PLY/omarchy.script" >"$tmp" &&
      sudo cp "$tmp" "$PLY/omarchy.script" &&
      ok "splash block removed from omarchy.script"
  fi
  sudo rm -f "$PLY/background.png"

  # Main.qml is rewritten, not appended to, so there is no block to take back
  # out — put upstream's template back. Deleting background.png without doing
  # this would leave a Main.qml pointing at a file that is gone. The colours
  # come back as Tokyo Night until the next theme change rewrites them, which
  # omarchy-plymouth-set does on its own.
  SDDM=/usr/share/sddm/themes/omarchy
  SDDM_TEMPLATE=${OMARCHY_PATH:-/usr/share/omarchy}/default/sddm/omarchy/Main.qml
  if sudo test -f "$SDDM/Main.qml" && [[ -r $SDDM_TEMPLATE ]]; then
    sudo install -m 644 "$SDDM_TEMPLATE" "$SDDM/Main.qml" &&
      ok "login screen restored to Omarchy's template"
  fi
  sudo rm -f "$SDDM/background.png"

  # Same for the greeter compositor: one line added to a file this tool does not
  # own. -e on the grep and the awk index(), because the mark starts with -- and
  # both would otherwise read it as an option.
  GREETER_LUA=/usr/share/sddm/hyprland.lua
  if sudo test -f "$GREETER_LUA"; then
    lua_tmp=$(mktemp) || die 'mktemp failed'
    sudo awk '!index($0, "-- omarchy-boot-theme")' "$GREETER_LUA" >"$lua_tmp" &&
      sudo cp "$lua_tmp" "$GREETER_LUA" &&
      ok 'greeter compositor background restored'
    rm -f "$lua_tmp"
  fi
  # The themed block in limine.conf outlives the tool that wrote it, and
  # nothing else knows how to remove it.
  if sudo test -f /boot/limine.conf.omarchy-limine-theme.bak; then
    sudo mv -f /boot/limine.conf.omarchy-limine-theme.bak /boot/limine.conf &&
      ok "limine.conf restored from the backup taken at first run"
  else
    info "no limine.conf backup found; the themed block is still in place"
  fi
  cat <<'NEXT'

Done. Two things are back to Omarchy's defaults rather than to your theme: the
splash still has the wallpaper on it until the initramfs is rebuilt, and the
login screen is on the template's colours. One command settles both:

  omarchy-plymouth-set-by-theme "$(cat ~/.local/state/omarchy/current/theme.name)"
NEXT
  exit 0
fi

step "Checking"
command -v omarchy-theme-dir >/dev/null 2>&1 || die 'this is not an Omarchy system'
command -v magick >/dev/null 2>&1 ||
  die 'ImageMagick is missing, and the wallpaper has to be rendered (omarchy pkg add imagemagick)'
[[ -r /boot/limine.conf ]] || sudo test -r /boot/limine.conf ||
  warn '/boot/limine.conf not found; is this machine on Limine?'
[[ -r $STATE/current/background ]] ||
  warn "no current background at $STATE/current/background; the splash will keep Omarchy's logo"
ok "Omarchy present"

step "Installing"
mkdir -p "$BIN" || die "could not create $BIN"
install -m 755 "$HERE/bin/omarchy-boot-theme" "$BIN/omarchy-boot-theme" ||
  die 'could not install omarchy-boot-theme'
ok "$BIN/omarchy-boot-theme"

# Earlier versions of this installed the root-run half into ~/.local/bin. Take
# it back out, so there is no stale copy on PATH ahead of the real one.
if [[ -e $BIN/omarchy-limine-theme ]]; then
  rm -f "$BIN/omarchy-limine-theme" &&
    info "removed the old $BIN/omarchy-limine-theme (it moved to $SBIN)"
fi

for cmd in omarchy-limine-theme omarchy-splash-wallpaper; do
  sudo install -o root -g root -m 755 "$HERE/bin/$cmd" "$SBIN/$cmd" ||
    die "could not install $cmd"
  ok "$SBIN/$cmd (root-owned)"
done

case ":$PATH:" in
*":$BIN:"*) ;;
*) warn "$BIN is not on your PATH" ;;
esac

# Not part of --no-hook: this is not a trigger, it is the boot looking right.
# A plain "plymouth quit" blanks the screen, and SDDM only starts afterwards, so
# the splash disappears seconds before the login screen paints. The drop-in
# leaves the last frame up across the handoff; the file itself has the reasoning.
if systemctl cat plymouth-quit.service >/dev/null 2>&1; then
  sudo install -d -m 755 "$UNIT_DIR/plymouth-quit.service.d" &&
    sudo install -m 644 "$HERE/hooks/plymouth-quit-retain-splash.conf" \
      "$UNIT_DIR/plymouth-quit.service.d/omarchy-boot-theme.conf" &&
    sudo systemctl daemon-reload &&
    ok 'splash now holds until the login screen paints' ||
    warn 'could not install the plymouth-quit drop-in'
else
  info 'no plymouth-quit.service here, skipping the splash handoff'
fi

if ((HOOK)); then
  mkdir -p "$HOOK_DIR" || die "could not create $HOOK_DIR"
  install -m 755 "$HERE/hooks/omarchy-boot-theme" "$HOOK_DIR/omarchy-boot-theme" ||
    die 'could not install the hook'
  ok "theme-set hook installed"

  # Nothing in Omarchy runs a hook when the wallpaper changes — omarchy-theme-bg-set
  # just relinks current/background and tells the shell. So watch the directory.
  sed -e "s|@USER_STATE@|$STATE|" "$HERE/hooks/omarchy-splash-wallpaper.path" |
    sudo tee "$UNIT_DIR/omarchy-splash-wallpaper.path" >/dev/null || die 'could not install the path unit'
  sed -e "s|@USER_HOME@|$HOME|" -e "s|@SPLASH_CMD@|$SBIN/omarchy-splash-wallpaper|" \
    "$HERE/hooks/omarchy-splash-wallpaper.service" |
    sudo tee "$UNIT_DIR/omarchy-splash-wallpaper.service" >/dev/null || die 'could not install the service unit'
  for unit in omarchy-splash-wallpaper.path omarchy-splash-wallpaper.service; do
    sudo grep -q '@USER_STATE@\|@USER_HOME@\|@SPLASH_CMD@' "$UNIT_DIR/$unit" &&
      die "placeholders left in $UNIT_DIR/$unit"
  done
  sudo systemctl daemon-reload &&
    sudo systemctl enable --now omarchy-splash-wallpaper.path >/dev/null 2>&1 &&
    ok "wallpaper watch enabled" ||
    warn 'could not enable omarchy-splash-wallpaper.path'
  info "a theme change rebuilds the initramfs twice, a wallpaper change once"
else
  info "hooks skipped (--no-hook); run omarchy-boot-theme by hand"
fi

# Anything that regenerates limine.conf rewrites the block this tool writes, so
# a kernel update would quietly revert the boot menu. limine-entry-tool runs
# /etc/boot/hooks/post.d/* after every such regeneration; sort before
# 90-limine-enroll-config so the file is final before it is hashed.
if [[ -d $BOOT_HOOK_DIR ]]; then
  sed -e "s|@USER_STATE@|$STATE|" \
    -e "s|@USER_HOME@|$HOME|" \
    -e "s|@THEME_CMD@|$SBIN/omarchy-limine-theme|" \
    "$HERE/hooks/50-omarchy-boot-theme" |
    sudo tee "$BOOT_HOOK_DIR/50-omarchy-boot-theme" >/dev/null &&
    sudo chmod 755 "$BOOT_HOOK_DIR/50-omarchy-boot-theme" ||
    die 'could not install the limine boot hook'
  sudo grep -q '@USER_STATE@\|@USER_HOME@\|@THEME_CMD@' "$BOOT_HOOK_DIR/50-omarchy-boot-theme" &&
    die "placeholders left in $BOOT_HOOK_DIR/50-omarchy-boot-theme"
  ok "limine boot hook installed (survives kernel updates)"
else
  warn "$BOOT_HOOK_DIR does not exist; the boot menu will revert on kernel updates"
fi

cat <<'NEXT'

Apply it to the current theme now:

  omarchy-boot-theme

That asks for your password, re-colours the Limine menu, and rebuilds the
initramfs with the current wallpaper behind the splash. Both only show at boot,
so restart to see them.

If the boot menu ever looks wrong, the original is at
/boot/limine.conf.omarchy-limine-theme.bak.
NEXT
