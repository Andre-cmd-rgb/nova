#!/bin/bash
#
# Install omarchy-boot-theme.
#
#   ./install.sh              install, and hook it to theme changes
#   ./install.sh --no-hook    install the commands only
#   ./install.sh --uninstall  remove both, and restore limine.conf
#
# Run as your normal user. The commands themselves call sudo when they run.

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BIN=${XDG_BIN_HOME:-$HOME/.local/bin}
HOOK_DIR=$HOME/.config/omarchy/hooks/theme-set.d

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
  rm -f "$BIN/omarchy-boot-theme" "$BIN/omarchy-limine-theme"
  rm -f "$HOOK_DIR/omarchy-boot-theme"
  ok "commands and hook removed"
  # The themed block in limine.conf outlives the tool that wrote it, and
  # nothing else knows how to remove it.
  if sudo test -f /boot/limine.conf.omarchy-limine-theme.bak; then
    sudo mv -f /boot/limine.conf.omarchy-limine-theme.bak /boot/limine.conf &&
      ok "limine.conf restored from the backup taken at first run"
  else
    info "no limine.conf backup found; the themed block is still in place"
  fi
  printf '\nDone. The Plymouth theme is unchanged — pick another with\n'
  printf 'Super+Space -> Style -> Unlock, or omarchy-plymouth-reset.\n'
  exit 0
fi

step "Checking"
command -v omarchy-theme-dir >/dev/null 2>&1 || die 'this is not an Omarchy system'
command -v magick >/dev/null 2>&1 ||
  warn 'ImageMagick is missing; omarchy-plymouth-set needs it (omarchy pkg add imagemagick)'
[[ -r /boot/limine.conf ]] || sudo test -r /boot/limine.conf ||
  warn '/boot/limine.conf not found; is this machine on Limine?'
ok "Omarchy present"

step "Installing"
mkdir -p "$BIN" || die "could not create $BIN"
for cmd in omarchy-boot-theme omarchy-limine-theme; do
  install -m 755 "$HERE/bin/$cmd" "$BIN/$cmd" || die "could not install $cmd"
  ok "$BIN/$cmd"
done
case ":$PATH:" in
*":$BIN:"*) ;;
*) warn "$BIN is not on your PATH" ;;
esac

if ((HOOK)); then
  mkdir -p "$HOOK_DIR" || die "could not create $HOOK_DIR"
  install -m 755 "$HERE/hooks/omarchy-boot-theme" "$HOOK_DIR/omarchy-boot-theme" ||
    die 'could not install the hook'
  ok "theme-set hook installed"
  info "every theme change now opens a terminal and rebuilds the initramfs"
  info "drop --plymouth work with: $HOOK_DIR/omarchy-boot-theme"
else
  info "hook skipped (--no-hook); run omarchy-boot-theme by hand"
fi

cat <<'NEXT'

Apply it to the current theme now:

  omarchy-boot-theme

That asks for your password, re-colours the Limine menu, and rebuilds the
initramfs with a themed splash. Both only show at boot, so restart to see them.

If the boot menu ever looks wrong, the original is at
/boot/limine.conf.omarchy-limine-theme.bak.
NEXT
