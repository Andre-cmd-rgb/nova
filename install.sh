#!/bin/bash
#
# Set up AC/battery power management on a hybrid-graphics Omarchy laptop.
#
#   ./install.sh              install (or re-install, idempotently)
#   ./install.sh --uninstall  put everything back
#
# Run it as your normal user; it calls sudo for the parts that need root.

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
UWSM_ENV="$CONFIG_HOME/uwsm/env-hyprland"
HYPR_CONF="$CONFIG_HOME/hypr/hyprland.lua"
MENU_FILE="$CONFIG_HOME/omarchy/extensions/omarchy-menu.jsonc"
MARK_BEGIN="-- >>> thinkpad-power >>>"
MARK_END="-- <<< thinkpad-power <<<"
ENV_MARK="# thinkpad-power"
ENV_BEGIN="# >>> thinkpad-power >>>"
ENV_END="# <<< thinkpad-power <<<"
IGPU_LINK_NAME="igpu"

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  \033[2m·\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die() {
  printf '\033[31mx\033[0m %s\n' "$*" >&2
  exit 1
}
# Every privileged step goes through this. Printing a tick for a command that
# failed is worse than failing: it leaves a half-installed machine looking
# like a working one.
run() { "$@" || die "failed: $*"; }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ------------------------------------------------------------------ detection

# Cached sysfs ids, never lspci: reading PCI config space wakes a suspended GPU.
detect_nvidia() {
  local dev vendor class
  for dev in /sys/bus/pci/devices/*/; do
    [[ -r ${dev}vendor && -r ${dev}class ]] || continue
    vendor=$(<"${dev}vendor")
    class=$(<"${dev}class")
    [[ $vendor == 0x10de ]] || continue
    case $(<"${dev}class") in
    0x030000 | 0x030200) basename "$dev"; return 0 ;;
    esac
  done
  return 1
}

# The card that actually drives a connected panel. Pinning the compositor to
# anything else is how you end up at a black screen.
detect_display_card() {
  local conn card dev
  for conn in /sys/class/drm/card*-*/status; do
    [[ -r $conn ]] || continue
    [[ $(<"$conn") == connected ]] || continue
    card=${conn%/status}
    card=$(basename "$card")
    card=${card%%-*}
    dev=$(basename "$(readlink -f "/sys/class/drm/$card/device")" 2>/dev/null) || continue
    [[ -e /dev/dri/by-path/pci-$dev-card ]] || continue
    printf '%s' "$dev"
    return 0
  done
  return 1
}

# --------------------------------------------------------------------- remove

uninstall() {
  step "Removing thinkpad-power"
  sudo rm -f /usr/local/bin/thinkpad-power
  sudo rm -f /etc/systemd/system/thinkpad-power.service
  sudo rm -f /etc/udev/rules.d/99-thinkpad-power.rules
  sudo rm -f /etc/udev/rules.d/98-thinkpad-power-igpu.rules
  sudo rm -f /etc/thinkpad-power.conf
  sudo systemctl daemon-reload
  sudo udevadm control --reload-rules
  ok "root files removed"

  if [[ -f $UWSM_ENV ]] && grep -q "$ENV_MARK" "$UWSM_ENV"; then
    sed -i "/$ENV_BEGIN/,/$ENV_END/d;/$ENV_MARK/d;/AQ_DRM_DEVICES/d" "$UWSM_ENV"
    [[ -s $UWSM_ENV ]] || rm -f "$UWSM_ENV"
    ok "session GPU pin removed"
  fi

  if [[ -f $HYPR_CONF ]] && grep -qF -- "$MARK_BEGIN" "$HYPR_CONF"; then
    sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$HYPR_CONF"
    ok "Hyprland env overrides removed"
  fi

  if [[ -f $MENU_FILE ]] && grep -q '"trigger.hardware.hybrid-gpu"' "$MENU_FILE"; then
    sed -i '/"trigger.hardware.hybrid-gpu"/d' "$MENU_FILE"
    ok "menu override removed (Omarchy's own entry returns)"
  fi

  printf '\nDone. Log out and back in to restore the original GPU selection.\n'
  printf 'supergfxctl was not reinstalled; `omarchy pkg add supergfxctl` if you want it back.\n'
  exit 0
}

[[ ${1:-} == --uninstall ]] && uninstall

# -------------------------------------------------------------------- checks

step "Checking this machine"

NVIDIA_PCI=$(detect_nvidia) || die "no discrete NVIDIA GPU found — this tool has nothing to do here"
ok "discrete GPU at $NVIDIA_PCI"

DISPLAY_PCI=$(detect_display_card) || die "could not work out which card drives the panel"
if [[ $DISPLAY_PCI == "$NVIDIA_PCI" ]]; then
  die "the connected panel is driven by the NVIDIA card. Powering it off would
   black out the screen, so this tool refuses to set that up."
fi
ok "panel is driven by $DISPLAY_PCI, not the NVIDIA"

DISPLAY_CARD="/dev/dri/by-path/pci-$DISPLAY_PCI-card"
[[ -e $DISPLAY_CARD ]] || die "$DISPLAY_CARD does not exist"
ok "compositor will be pinned to $DISPLAY_CARD"

command -v powerprofilesctl >/dev/null 2>&1 ||
  warn "power-profiles-daemon is missing; profile switching will be skipped"

# ------------------------------------------------------------------- install

step "Installing"

# Authenticate once, here, so a fingerprint that times out fails the install
# outright instead of silently skipping the step it was asked for.
info "administrator access is needed from here on"
sudo -v || die "could not authenticate — nothing was changed"

run sudo install -Dm755 "$HERE/bin/thinkpad-power" /usr/local/bin/thinkpad-power
ok "/usr/local/bin/thinkpad-power"

printf 'NVIDIA_PCI=%s\n' "$NVIDIA_PCI" | sudo tee /etc/thinkpad-power.conf >/dev/null ||
  die "failed writing /etc/thinkpad-power.conf"
ok "/etc/thinkpad-power.conf"

run sudo install -Dm644 "$HERE/systemd/thinkpad-power.service" \
  /etc/systemd/system/thinkpad-power.service
run sudo install -Dm644 "$HERE/udev/99-thinkpad-power.rules" \
  /etc/udev/rules.d/99-thinkpad-power.rules
run sudo systemctl daemon-reload
sudo systemctl enable thinkpad-power.service >/dev/null 2>&1
run sudo udevadm control --reload-rules
ok "systemd unit + udev rule (fires on plug/unplug, boot and resume)"

# A stable, colon-free name for the integrated card. AQ_DRM_DEVICES splits its
# value on ":", so a /dev/dri/by-path/pci-0000:00:02.0-card path is torn into
# three nonexistent paths, aquamarine matches none of them, and the compositor
# exits with "Found no gpus to use" — which costs you the login screen. Card
# numbering is not stable either, hence a symlink rather than /dev/dri/cardN.
# This is the arrangement the Hyprland wiki recommends for exactly this.
printf 'KERNEL=="card*", KERNELS=="%s", SUBSYSTEM=="drm", SUBSYSTEMS=="pci", SYMLINK+="dri/%s"\n' \
  "$DISPLAY_PCI" "$IGPU_LINK_NAME" |
  sudo tee "/etc/udev/rules.d/98-thinkpad-power-igpu.rules" >/dev/null ||
  die "failed writing the iGPU symlink rule"
run sudo udevadm control --reload
run sudo udevadm trigger --subsystem-match=drm
ok "/dev/dri/$IGPU_LINK_NAME -> the integrated card"

# ------------------------------------------------------------------ supergfx

step "Standing down supergfxd"

if systemctl list-unit-files supergfxd.service >/dev/null 2>&1; then
  sudo systemctl disable --now supergfxd >/dev/null 2>&1
  ok "supergfxd stopped and disabled"
fi
# Its Integrated-mode leftovers run on every resume and fight this setup.
for leftover in /usr/lib/systemd/system-sleep/force-igpu \
  /etc/systemd/system/supergfxd.service.d/delay-start.conf; do
  if [[ -e $leftover ]]; then
    sudo rm -f "$leftover"
    ok "removed $leftover"
  fi
done
if pacman -Q supergfxctl >/dev/null 2>&1; then
  sudo pacman -Rns --noconfirm supergfxctl >/dev/null 2>&1 &&
    ok "supergfxctl uninstalled" ||
    warn "could not uninstall supergfxctl; it is disabled, which is enough"
fi
sudo rm -f /etc/supergfxd.conf

# --------------------------------------------------------------- user config

step "Session configuration"

mkdir -p "$(dirname -- "$UWSM_ENV")"
touch "$UWSM_ENV"
# Remove the whole managed block as a unit, markers included. Anything else
# in this file is the user's and is left alone.
sed -i "/$ENV_BEGIN/,/$ENV_END/d" "$UWSM_ENV"
# Blocks written before the markers existed had no reliable end; drop their
# remains rather than leave half an if-statement behind.
sed -i "/$ENV_MARK/d;/AQ_DRM_DEVICES/d;/_tp_egl/d;/_tp_card/d;/__EGL_VENDOR_LIBRARY_FILENAMES/d;/VK_LOADER_DRIVERS_DISABLE/d" "$UWSM_ENV"
sed -i '/^if \[ -e \/dev\/dri\//,/^fi$/d;/^if \[ -n "\$_tp_egl" \]/,/^fi$/d' "$UWSM_ENV"
if ! sh -n "$UWSM_ENV" 2>/dev/null; then
  warn "$UWSM_ENV had unparseable leftovers; starting it fresh"
  : >"$UWSM_ENV"
fi

# Only pin if the symlink really exists. A pin that cannot be resolved is the
# one failure mode of this whole tool that costs a login, so it is checked
# here, and checked again at every login by the guard written below.
if [[ -e /dev/dri/$IGPU_LINK_NAME ]]; then
  cat >>"$UWSM_ENV" <<ENV
$ENV_BEGIN
$ENV_MARK keep the compositor on the integrated GPU, so nothing holds the
$ENV_MARK discrete card open and it can be powered off. The value must not
$ENV_MARK contain a colon: AQ_DRM_DEVICES splits on it.
if [ -e /dev/dri/$IGPU_LINK_NAME ] && grep -qx connected /sys/class/drm/\$(basename \$(readlink -f /dev/dri/$IGPU_LINK_NAME))-*/status 2>/dev/null; then
  export AQ_DRM_DEVICES=/dev/dri/$IGPU_LINK_NAME
fi

$ENV_MARK Pinning the compositor's DRM device is not enough on its own: it
$ENV_MARK decides which card draws the screen, not which driver the graphics
$ENV_MARK libraries load. GLVND loads every EGL vendor it finds, and the
$ENV_MARK Vulkan loader every ICD, so libEGL_nvidia and nvidia_icd get pulled
$ENV_MARK into the compositor and into ordinary GTK apps, and those open
$ENV_MARK /dev/nvidia0 and hold the card awake with nothing drawn on it.
$ENV_MARK
$ENV_MARK Built from what is on disk rather than hardcoded, and only exported
$ENV_MARK when non-NVIDIA vendors were actually found: an empty or bogus list
$ENV_MARK breaks EGL for everything.
_tp_egl=\$(ls /usr/share/glvnd/egl_vendor.d/*.json 2>/dev/null | grep -v nvidia | paste -sd:)
if [ -n "\$_tp_egl" ]; then
  export __EGL_VENDOR_LIBRARY_FILENAMES="\$_tp_egl"
fi
unset _tp_egl
export VK_LOADER_DRIVERS_DISABLE='*nvidia*'
$ENV_END
ENV
  if sh -n "$UWSM_ENV" 2>/dev/null; then
    ok "$UWSM_ENV (pins the compositor to /dev/dri/$IGPU_LINK_NAME)"
  else
    sed -i "/$ENV_BEGIN/,/$ENV_END/d" "$UWSM_ENV"
    die "$UWSM_ENV would not parse as shell; the block was removed and nothing
   was changed. Please report this — a file that cannot be sourced costs a login."
  fi
else
  warn "/dev/dri/$IGPU_LINK_NAME did not appear — skipping the compositor pin."
  warn "The dGPU will keep being held open; re-run once the symlink exists."
fi

if [[ -f $HYPR_CONF ]]; then
  grep -qF -- "$MARK_BEGIN" "$HYPR_CONF" && sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$HYPR_CONF"
  cat >>"$HYPR_CONF" <<LUA
$MARK_BEGIN
-- Omarchy points video decode and GLX at the NVIDIA whenever one is present.
-- That is what makes ordinary apps open the discrete card and hold it awake,
-- and it breaks decoding outright once the card is off the bus. The desktop
-- runs on the iGPU here, so send them there; prime-run still overrides both
-- per-process for anything that genuinely wants the dGPU.
hl.env("LIBVA_DRIVER_NAME", "iHD")
hl.env("__GLX_VENDOR_LIBRARY_NAME", "mesa")
$MARK_END
LUA
  ok "$HYPR_CONF (video decode and GLX pointed at the iGPU)"
fi

if [[ -f $MENU_FILE ]]; then
  grep -q '"trigger.hardware.hybrid-gpu"' "$MENU_FILE" &&
    sed -i '/"trigger.hardware.hybrid-gpu"/d' "$MENU_FILE"
  entry='  "trigger.hardware.hybrid-gpu": {"label":"Discrete GPU","when":"true","action":"omarchy-launch-floating-terminal-with-presentation thinkpad-power switch"},'
  tmp=$(mktemp)
  awk -v entry="$entry" '
    { lines[NR] = $0 }
    END {
      last = 0
      for (i = NR; i >= 1; i--) if (lines[i] ~ /^[[:space:]]*}[[:space:]]*$/) { last = i; break }
      for (i = 1; i <= NR; i++) { if (i == last) print entry; print lines[i] }
      if (last == 0) print entry
    }
  ' "$MENU_FILE" >"$tmp" && cat "$tmp" >"$MENU_FILE"
  rm -f "$tmp"
  ok "Omarchy menu entry now toggles the GPU live instead of rebooting"
fi

# ---------------------------------------------------------------------- apply

step "Applying now"
sudo /usr/local/bin/thinkpad-power auto
echo
/usr/local/bin/thinkpad-power status

cat <<'NEXT'

Log out and back in to finish.

The compositor only reads its GPU list at startup, so until you do, Hyprland
still holds the discrete card open and it cannot be powered off. After the
next login:

  thinkpad-power status     what is on, what holds the GPU
  prime-run <program>           run something on the discrete GPU
  Super+Space -> Discrete GPU   toggle it by hand, no reboot

If the screen ever fails to come back after a login, switch to a TTY with
Ctrl+Alt+F2 and run:

  rm ~/.config/uwsm/env-hyprland

which undoes the GPU pin, and log in again.
NEXT
