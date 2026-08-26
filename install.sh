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
MARK_BEGIN="-- >>> omarchy-power >>>"
MARK_END="-- <<< omarchy-power <<<"
ENV_MARK="# omarchy-power"

ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '  \033[2m·\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die() {
  printf '\033[31mx\033[0m %s\n' "$*" >&2
  exit 1
}
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
  step "Removing omarchy-power"
  sudo rm -f /usr/local/bin/omarchy-power-mode /usr/local/bin/omarchy-gpu-switch
  sudo rm -f /etc/systemd/system/omarchy-power-mode.service
  sudo rm -f /etc/udev/rules.d/99-omarchy-power-mode.rules
  sudo rm -f /etc/omarchy-power-mode.conf
  sudo systemctl daemon-reload
  sudo udevadm control --reload-rules
  ok "root files removed"

  if [[ -f $UWSM_ENV ]] && grep -q "$ENV_MARK" "$UWSM_ENV"; then
    sed -i "/$ENV_MARK/,+1d" "$UWSM_ENV"
    [[ -s $UWSM_ENV ]] || rm -f "$UWSM_ENV"
    ok "session GPU pin removed"
  fi

  if [[ -f $HYPR_CONF ]] && grep -qF "$MARK_BEGIN" "$HYPR_CONF"; then
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

sudo install -Dm755 "$HERE/bin/omarchy-power-mode" /usr/local/bin/omarchy-power-mode
sudo install -Dm755 "$HERE/bin/omarchy-gpu-switch" /usr/local/bin/omarchy-gpu-switch
ok "/usr/local/bin/omarchy-power-mode, omarchy-gpu-switch"

printf 'NVIDIA_PCI=%s\n' "$NVIDIA_PCI" | sudo tee /etc/omarchy-power-mode.conf >/dev/null
ok "/etc/omarchy-power-mode.conf"

sudo install -Dm644 "$HERE/systemd/omarchy-power-mode.service" \
  /etc/systemd/system/omarchy-power-mode.service
sudo install -Dm644 "$HERE/udev/99-omarchy-power-mode.rules" \
  /etc/udev/rules.d/99-omarchy-power-mode.rules
sudo systemctl daemon-reload
sudo systemctl enable omarchy-power-mode.service >/dev/null 2>&1
sudo udevadm control --reload-rules
ok "systemd unit + udev rule (fires on plug/unplug, boot and resume)"

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
if grep -q "$ENV_MARK" "$UWSM_ENV"; then
  sed -i "/$ENV_MARK/,+1d" "$UWSM_ENV"
fi
{
  printf '%s — keep the compositor on the integrated GPU so nothing pins the\n' "$ENV_MARK"
  printf 'export AQ_DRM_DEVICES=%s\n' "$DISPLAY_CARD"
} >>"$UWSM_ENV"
ok "$UWSM_ENV"

if [[ -f $HYPR_CONF ]]; then
  grep -qF "$MARK_BEGIN" "$HYPR_CONF" && sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$HYPR_CONF"
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
  entry='  "trigger.hardware.hybrid-gpu": {"label":"Discrete GPU","when":"true","action":"omarchy-launch-floating-terminal-with-presentation omarchy-gpu-switch"},'
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
sudo /usr/local/bin/omarchy-power-mode auto
echo
/usr/local/bin/omarchy-power-mode status

cat <<'NEXT'

Log out and back in to finish.

The compositor only reads its GPU list at startup, so until you do, Hyprland
still holds the discrete card open and it cannot be powered off. After the
next login:

  omarchy-power-mode status     what is on, what holds the GPU
  prime-run <program>           run something on the discrete GPU
  Super+Space -> Discrete GPU   toggle it by hand, no reboot

If the screen ever fails to come back after a login, switch to a TTY with
Ctrl+Alt+F2 and run:

  rm ~/.config/uwsm/env-hyprland

which undoes the GPU pin, and log in again.
NEXT
