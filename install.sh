#!/bin/bash
#
# Set up AC/battery power management on a hybrid-graphics Omarchy laptop.
#
#   ./install.sh              install (or re-install, idempotently)
#   ./install.sh --boot-path  also trim the boot path (opt-in, see README)
#   ./install.sh --hibernate  lid sleeps to RAM, then hibernates (opt-in)
#   ./install.sh --hibernate-after=90min   the same, with a different delay
#   ./install.sh --chrome-saver  force Chrome's Energy and Memory Saver on
#   ./install.sh --uninstall  put everything back, boot path included
#
# Run it as your normal user; it calls sudo for the parts that need root.

set -uo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# Started under `sudo`, $HOME is /root — and every path below it is *session*
# config that only the logged-in user's compositor ever reads: the GPU pin, the
# hyprland.lua block, the Omarchy menu override, the remembered power profile.
# Writing those into /root fails silently and completely: all four steps still
# print a tick, and the session they were meant to configure is untouched. This
# script escalates on its own where it needs root, so it is meant to be started
# as the user — but being started with sudo in front is an easy mistake and a
# quiet one, so recover the real account rather than configure an account that
# nobody logs into.
REAL_USER=${SUDO_USER:-$(id -un)}
REAL_HOME=$HOME
if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
  REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  [[ -d ${REAL_HOME:-} ]] || REAL_HOME=$HOME
fi
# XDG_CONFIG_HOME describes whichever session exported it, so it is honoured
# only when this *is* that session.
if [[ $REAL_HOME == "$HOME" ]]; then
  CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
  STATE_HOME=${XDG_STATE_HOME:-$HOME/.local/state}
else
  CONFIG_HOME=$REAL_HOME/.config
  STATE_HOME=$REAL_HOME/.local/state
fi

# Anything created under the user's home while this runs as root would be left
# root-owned in their own home, which breaks the next run started as the user.
own_as_user() {
  [[ $EUID -eq 0 && $REAL_USER != root ]] || return 0
  chown -R "$REAL_USER" "$@" 2>/dev/null
  return 0
}

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

# Once this tool has done its job the card is off the PCI bus and there is
# nothing in sysfs to find, so a re-install would conclude the machine has no
# discrete GPU and refuse. A previous run recorded the address for exactly
# this reason; trust it when the bus comes up empty.
recorded_nvidia() {
  local recorded
  recorded=$(sed -n 's/^NVIDIA_PCI=//p' /etc/thinkpad-power.conf 2>/dev/null)
  [[ -n $recorded ]] || return 1
  printf '%s\n' "$recorded"
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
  # The governor first, and stopped rather than only disabled: it holds the
  # fans and the power limits, and its own ExecStopPost is what puts them back.
  sudo systemctl disable --now thinkpad-powerd.service >/dev/null 2>&1
  sudo rm -f /etc/systemd/system/thinkpad-powerd.service
  sudo rm -f /usr/local/bin/thinkpad-powerd
  sudo rm -f /etc/modprobe.d/thinkpad-power-fan.conf
  # Belt and braces: if the unit was already gone, nothing ran the restore.
  [[ -w /proc/acpi/ibm/fan ]] && echo 'level auto' | sudo tee /proc/acpi/ibm/fan >/dev/null 2>&1
  sudo rm -f /run/thinkpad-powerd.owns-cpu /run/thinkpad-powerd.state
  ok "governor stopped and removed (fans back to the EC)"

  sudo rm -f /usr/local/bin/thinkpad-power
  sudo rm -f /etc/systemd/system/thinkpad-power.service
  sudo systemctl disable --now thinkpad-power-gpu.timer >/dev/null 2>&1
  sudo rm -f /etc/systemd/system/thinkpad-power-gpu.service /etc/systemd/system/thinkpad-power-gpu.timer
  sudo rm -f /etc/udev/rules.d/99-thinkpad-power.rules
  sudo rm -f /etc/udev/rules.d/98-thinkpad-power-igpu.rules
  # Hands the Wi-Fi flag back to Omarchy's wifi.powersave = 2, but only at the
  # next activation — the radio keeps whatever it has until then.
  if [[ -e /etc/NetworkManager/conf.d/zz-thinkpad-power-wifi.conf ]]; then
    sudo rm -f /etc/NetworkManager/conf.d/zz-thinkpad-power-wifi.conf
    sudo systemctl reload NetworkManager >/dev/null 2>&1
    for dev in /sys/class/net/*/wireless; do
      [[ -e $dev ]] || continue
      sudo iw dev "$(basename "$(dirname "$dev")")" set power_save off >/dev/null 2>&1
    done
    ok "Wi-Fi power save returned to NetworkManager"
  fi
  sudo rm -f /etc/thinkpad-power.conf
  if [[ -f /etc/opt/chrome/policies/managed/thinkpad-power.json ]]; then
    sudo rm -f /etc/opt/chrome/policies/managed/thinkpad-power.json
    ok "Chrome performance policy removed (restart Chrome to clear the banner)"
  fi
  # The card may be off the bus right now, with the driver barred from
  # loading. Leaving it that way with the tool gone would strand it.
  sudo rm -f /run/modprobe.d/thinkpad-power-nvidia.conf
  sudo rm -f /etc/modprobe.d/thinkpad-power-nvidia-fbdev.conf
  echo 1 | sudo tee /sys/bus/pci/rescan >/dev/null 2>&1 &&
    ok "PCI bus rescanned"
  sudo systemctl enable --now nvidia-persistenced >/dev/null 2>&1 &&
    ok "nvidia-persistenced re-enabled"
  sudo systemctl daemon-reload
  sudo udevadm control --reload-rules
  ok "root files removed"

  sudo rm -f /etc/systemd/sleep.conf.d/10-thinkpad-power.conf
  sudo rm -f /etc/systemd/logind.conf.d/10-thinkpad-power-lid.conf
  sudo rm -f /usr/lib/systemd/system-sleep/thinkpad-power-resume
  sudo systemctl reload systemd-logind >/dev/null 2>&1
  ok "sleep policy reverted (lid goes back to plain suspend)"
  if [[ -f $MENU_FILE ]] && grep -q '"system.suspend"' "$MENU_FILE"; then
    sed -i '/"system.suspend"/d' "$MENU_FILE"
    ok "menu Suspend entry restored to Omarchy's own"
  fi

  # Put the boot path back. Both of these change what boots, so restore them
  # before the rebuild rather than leaving a half-reverted machine.
  local rebuild=0
  if [[ -f /etc/mkinitcpio.conf.d/nvidia.conf.thinkpad-power-orig ]]; then
    sudo mv -f /etc/mkinitcpio.conf.d/nvidia.conf.thinkpad-power-orig \
      /etc/mkinitcpio.conf.d/nvidia.conf
    rebuild=1
    ok "NVIDIA early-load restored"
  fi
  if systemctl is-enabled systemd-tpm2-setup.service 2>/dev/null | grep -q masked; then
    sudo systemctl unmask systemd-tpm2-setup.service systemd-tpm2-setup-early.service
    ok "TPM provisioning unmasked"
  fi
  if ((rebuild)) && command -v limine-mkinitcpio >/dev/null 2>&1; then
    printf '  \033[2m·\033[0m rebuilding the initramfs, this takes a minute...\n'
    sudo limine-mkinitcpio && ok "initramfs rebuilt" ||
      warn "initramfs rebuild failed; run: sudo limine-mkinitcpio"
  fi

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

# The boot-path work is opt-in for the same reason ASPM is: it is the one part
# of this tool that changes what boots, and the rest is worth having without
# it. --uninstall reverts it whether or not this run asked for it.
BOOT_PATH=0
CHROME_SAVER=0
HIBERNATE=0
HIBERNATE_DELAY=2h
HIBERNATE_DELAY_HOURS=2
DO_UNINSTALL=0
for arg in "$@"; do
  case $arg in
  --uninstall) DO_UNINSTALL=1 ;;
  --chrome-saver) CHROME_SAVER=1 ;;
  --boot-path) BOOT_PATH=1 ;;
  --hibernate) HIBERNATE=1 ;;
  --hibernate-after=*)
    HIBERNATE=1
    HIBERNATE_DELAY=${arg#*=}
    [[ $HIBERNATE_DELAY =~ ^[0-9]+(h|min|m|s)$ ]] ||
      die "--hibernate-after wants something like 2h, 90min or 30m, not '$HIBERNATE_DELAY'"
    HIBERNATE_DELAY_HOURS=$(awk -v d="$HIBERNATE_DELAY" 'BEGIN{
      n = d + 0
      if (d ~ /h$/)   print n
      else if (d ~ /(min|m)$/) printf "%.4f", n / 60
      else            printf "%.5f", n / 3600
    }')
    ;;
  -h | --help)
    sed -n '3,11p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,2\} \?//'
    exit 0
    ;;
  *) die "unknown option: $arg (try --help)" ;;
  esac
done
((DO_UNINSTALL)) && uninstall

# -------------------------------------------------------------------- checks

step "Checking this machine"

if NVIDIA_PCI=$(detect_nvidia); then
  ok "discrete GPU at $NVIDIA_PCI"
elif NVIDIA_PCI=$(recorded_nvidia); then
  ok "discrete GPU at $NVIDIA_PCI (off the bus, from /etc/thinkpad-power.conf)"
else
  die "no discrete NVIDIA GPU found — this tool has nothing to do here.
   If the card is deliberately off the bus, put it back first:
   sudo /usr/local/bin/thinkpad-power gpu-on"
fi

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

# The governor is compiled here, as the invoking user, before anything wants
# root — a cargo build under sudo would write root-owned artefacts into the
# user's target/ directory and into ~/.cargo. It has no dependencies, so this
# needs no network.
step "Building the governor"
DAEMON_BIN=""
if [[ -f $HERE/daemon/Cargo.toml ]]; then
  if command -v cargo >/dev/null 2>&1; then
    if (cd "$HERE/daemon" && cargo build --release --quiet); then
      DAEMON_BIN=$HERE/daemon/target/release/thinkpad-powerd
      [[ -x $DAEMON_BIN ]] || { DAEMON_BIN=""; warn "cargo reported success but produced no binary"; }
      [[ -n $DAEMON_BIN ]] && ok "thinkpad-powerd built"
    else
      warn "cargo build failed — installing without the governor"
    fi
  else
    warn "no cargo on PATH — installing without the load-adaptive governor."
    warn "Install Rust (omarchy pkg add rust) and re-run to add it."
  fi
fi

info "administrator access is needed from here on"
sudo -v || die "could not authenticate — nothing was changed"

run sudo install -Dm755 "$HERE/bin/thinkpad-power" /usr/local/bin/thinkpad-power
ok "/usr/local/bin/thinkpad-power"

# Only the NVIDIA_PCI line is ours. Everything else in this file is the
# user's — PL1_ON_BAT, ASPM_ON_BAT, NMI_WATCHDOG_ON_BAT — and truncating it
# on every install silently ate their settings.
if [[ -f /etc/thinkpad-power.conf ]]; then
  sudo sed -i '/^NVIDIA_PCI=/d' /etc/thinkpad-power.conf
else
  sudo tee /etc/thinkpad-power.conf >/dev/null <<'CONF'
# thinkpad-power. Sourced by the policy script as shell; keep it parseable.
#
# Optional, all off unless set:
#   PL1_ON_BAT=30              sustained CPU power limit on battery, in watts
#   PL2_ON_BAT=45              burst CPU power limit; must be >= PL1_ON_BAT
#   CPU_MAX_PCT_ON_BAT=60      frequency ceiling, as a percent of the range
#   ASPM_ON_BAT=powersave      PCIe link power management
#   NMI_WATCHDOG_ON_BAT=off    disable the hard-lockup detector on battery
#
# On unless set:
#   WIFI_POWERSAVE_ON_BAT=off  keep the Wi-Fi radio awake on battery too
#
# The CPU caps are lifted for one bounded stretch by:
#   sudo thinkpad-power boost 60
#
# thinkpad-powerd, the load-adaptive governor. While it is running it owns PL1,
# PL2 and the frequency ceiling, and the three settings above are inert.
#   GOVERNOR=off               stop the governor managing the CPU at all
#   LIGHT_PL1 / LIGHT_PL2 / LIGHT_MAX_PCT    browsing        (12 / 18 / 45)
#   MID_PL1   / MID_PL2   / MID_MAX_PCT      working          (18 / 28 / 70)
#   FULL_PL1  / FULL_PL2  / FULL_MAX_PCT     compiling        (28 / 42 / 100)
#   TURBO_PL1 / TURBO_PL2 / TURBO_MAX_PCT    prolonged load   (40 / 60 / 100)
#   LIGHT_NO_TURBO=off         let the browsing tier reach turbo after all
#   LIGHT_GPU_MHZ / MID_GPU_MHZ / ...   iGPU ceiling, MHz; 0 leaves it alone
#                                       (800 / 1050 / 0 / 0)
#   GOVERNOR_CLIMB_AFTER=8     seconds before climbing; each rung costs one more
#   GOVERNOR_FALL_AFTER=25     seconds of quiet before dropping one
#   GOVERNOR_BUSY_CLIMB=65     percent busy that counts as work
#   GOVERNOR_BUSY_FALL=30      percent busy that counts as done
#   GOVERNOR_TEMP_THROTTLE=85  step down a tier above this, whatever the load
#   FAN_CONTROL=off            leave the fans to the EC
CONF
fi
printf 'NVIDIA_PCI=%s\n' "$NVIDIA_PCI" | sudo tee -a /etc/thinkpad-power.conf >/dev/null ||
  die "failed writing /etc/thinkpad-power.conf"
ok "/etc/thinkpad-power.conf (NVIDIA_PCI only; other settings preserved)"

# Omarchy sets wifi.powersave=2 (off) distribution-wide, and NetworkManager
# applies that on every connection activation — so a roam or a reconnect would
# undo the flag thinkpad-power sets on battery, silently. 1 means "ignore":
# NetworkManager stops writing the flag at all and leaves it to the policy.
# The name has to sort after omarchy-wifi-powersave.conf, and conf.d is read
# in plain alphabetical order, so a 99- prefix would lose to an o.
sudo tee /etc/NetworkManager/conf.d/zz-thinkpad-power-wifi.conf >/dev/null <<'NMCONF'
# thinkpad-power: the Wi-Fi power-save flag is set per power source by
# /usr/local/bin/thinkpad-power, so NetworkManager must not write it. Removing
# this file hands the flag back to Omarchy's own wifi.powersave = 2 (off).
[connection]
wifi.powersave = 1
NMCONF
sudo systemctl reload NetworkManager >/dev/null 2>&1
ok "Wi-Fi power save handed to the policy (on for battery, off on AC)"

if [[ -n $DAEMON_BIN ]]; then
  run sudo install -Dm755 "$DAEMON_BIN" /usr/local/bin/thinkpad-powerd
  run sudo install -Dm644 "$HERE/systemd/thinkpad-powerd.service" \
    /etc/systemd/system/thinkpad-powerd.service

  # Manual fan control is refused by thinkpad_acpi unless the module was loaded
  # with fan_control=1, and the module is loaded long before this runs. The
  # daemon checks the parameter and stands down with one line if it is off, so
  # the gap between writing this and rebooting is harmless rather than silent.
  sudo tee /etc/modprobe.d/thinkpad-power-fan.conf >/dev/null <<'FANCONF'
# thinkpad-power: let thinkpad-powerd drive /proc/acpi/ibm/fan. The EC still
# takes the fans back on its own if the daemon stops feeding the watchdog.
options thinkpad_acpi fan_control=1
FANCONF
  if [[ $(cat /sys/module/thinkpad_acpi/parameters/fan_control 2>/dev/null) == Y ]]; then
    ok "fan control enabled"
  else
    ok "fan control queued — thinkpad_acpi needs a reboot to accept it"
  fi
fi

# The one reference that no process holds, and the reason `gpu-off` could fail
# with the card completely idle. With `nvidia-drm fbdev=1` — the driver default
# since 560, and nothing in EnvyControl's generated nvidia.conf turns it off —
# nvidia_drm registers a DRM fbdev client at load, and drm_client_init() takes
# `try_module_get(funcs->owner)` on nvidia_drm itself. That self-reference is
# `refs: 1, held by -` in /proc/modules, it is there from the instant the
# driver loads, and no amount of closing file descriptors clears it:
#
#   11:33:48 kernel: [drm] [nvidia-drm] [GPU ID 0x00000100] Loading driver
#   11:33:49 thinkpad-power[830]: nvidia_drm would not unload
#
# — the unload failing 95 seconds before the compositor even started.
#
# modeset stays on; fact 44 is right that PRIME needs it. fbdev is only the
# framebuffer console on the discrete card, which on a laptop with no displays
# wired to it never had anything to draw: the kernel says so in the same
# breath, "Cannot find any crtc or sizes". Written as its own file because
# nvidia.conf carries "Automatically generated by EnvyControl" and gets
# rewritten; modprobe merges options for a module across every file.
sudo tee /etc/modprobe.d/thinkpad-power-nvidia-fbdev.conf >/dev/null <<'FBCONF'
# thinkpad-power: stop nvidia_drm holding a reference on itself. The fbdev
# client is a framebuffer console for a card with no displays attached, and it
# is the difference between `gpu-off` working and "nvidia_drm is in use".
options nvidia-drm fbdev=0
FBCONF
if [[ $(cat /sys/module/nvidia_drm/parameters/fbdev 2>/dev/null) == N ]]; then
  ok "nvidia_drm fbdev off"
elif [[ -e /sys/module/nvidia_drm ]]; then
  ok "nvidia_drm fbdev queued — takes effect when the driver next loads"
else
  ok "nvidia_drm fbdev off (driver not loaded)"
fi

run sudo install -Dm644 "$HERE/systemd/thinkpad-power.service" \
  /etc/systemd/system/thinkpad-power.service
run sudo install -Dm644 "$HERE/udev/99-thinkpad-power.rules" \
  /etc/udev/rules.d/99-thinkpad-power.rules
run sudo install -Dm644 "$HERE/systemd/thinkpad-power-gpu.service" \
  /etc/systemd/system/thinkpad-power-gpu.service
run sudo install -Dm644 "$HERE/systemd/thinkpad-power-gpu.timer" \
  /etc/systemd/system/thinkpad-power-gpu.timer
run sudo systemctl daemon-reload
sudo systemctl enable thinkpad-power.service >/dev/null 2>&1
sudo systemctl enable --now thinkpad-power-gpu.timer >/dev/null 2>&1
if [[ -n $DAEMON_BIN ]]; then
  # Restarted rather than only enabled, so a re-install picks up a new binary
  # instead of leaving the old one running and looking installed.
  sudo systemctl enable thinkpad-powerd.service >/dev/null 2>&1
  if sudo systemctl restart thinkpad-powerd.service >/dev/null 2>&1; then
    ok "thinkpad-powerd running (it now owns PL1, PL2 and the frequency ceiling)"
  else
    warn "thinkpad-powerd would not start: systemctl status thinkpad-powerd"
  fi
fi
run sudo udevadm control --reload-rules
ok "systemd units + udev rule (plug/unplug, boot, resume, and a 2 min retry)"

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

step "Standing down what holds the GPU open"

# nvidia-persistenced exists to keep the driver resident so it never unloads.
# On a laptop whose dGPU renders nothing that is precisely backwards: it holds
# /dev/nvidia0 from boot and blocks every attempt to take the card off the bus.
# CUDA does not need it; it is for headless compute nodes.
if systemctl list-unit-files nvidia-persistenced.service >/dev/null 2>&1; then
  if systemctl is-enabled --quiet nvidia-persistenced 2>/dev/null ||
    systemctl is-active --quiet nvidia-persistenced 2>/dev/null; then
    sudo systemctl disable --now nvidia-persistenced >/dev/null 2>&1 &&
      ok "nvidia-persistenced stopped and disabled (it pins the driver in memory)"
  else
    info "nvidia-persistenced already down"
  fi
fi


if systemctl list-unit-files supergfxd.service >/dev/null 2>&1; then
  sudo systemctl disable --now supergfxd >/dev/null 2>&1
  ok "supergfxd stopped and disabled"
fi
# Its Integrated-mode leftovers run on every resume and fight this setup.
for leftover in /usr/lib/systemd/system-sleep/force-igpu \
  /etc/systemd/system/supergfxd.service.d/delay-start.conf \
  /etc/modprobe.d/supergfxd.conf; do
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


# ----------------------------------------------------------------- chrome

# Opt-in, and for one reason: this is an *enterprise policy*, so Chrome greys
# the settings out and shows "Managed by your organization". That is a visible
# change to somebody's browser and not something to do to them quietly. The
# same two settings are two clicks in chrome://settings/performance with no
# banner at all; this exists for when you want them pinned.
#
# BatterySaverModeAvailability: 2 is "enabled while on battery" (1 would be
# "only below 20%", which is the default and far too late to help). Energy
# Saver caps background frame rates and throttles background tabs;
# HighEfficiencyModeEnabled discards inactive ones, which is what actually
# matters with thirty renderer processes open.
CHROME_POLICY=/etc/opt/chrome/policies/managed/thinkpad-power.json

step "Chrome"

if ((CHROME_SAVER)); then
  if [[ -d /etc/opt/chrome/policies/managed ]]; then
    # Only real policy names go in here. Chrome validates every key in the
    # file against its policy list and reports anything it does not recognise
    # as an Error row in chrome://policy — including a "_comment" key, which
    # is what the first version of this file shipped with. The explanation
    # lives in the filename and in this script instead.
    sudo tee "$CHROME_POLICY" >/dev/null <<'CHROMEPOL'
{
  "BatterySaverModeAvailability": 2,
  "HighEfficiencyModeEnabled": true
}
CHROMEPOL
    ok "Energy Saver on battery + Memory Saver pinned by policy"
    info "restart Chrome for it to take, and expect a 'managed by your"
    info "organization' banner — rm $CHROME_POLICY undoes it"
  else
    warn "no /etc/opt/chrome/policies/managed — is Google Chrome installed?"
  fi
elif [[ -f $CHROME_POLICY ]]; then
  info "Chrome policy already in place — ./install.sh --uninstall removes it"
else
  info "not touched. ./install.sh --chrome-saver pins Energy and Memory Saver,"
  info "or set them yourself in chrome://settings/performance (no banner)"
fi

# ------------------------------------------------------------------ boot path

# Opt-in, because this is the one part of the tool that changes what boots.
# Everything above it is reversible from a running session; this is not.
NVIDIA_INITCPIO=/etc/mkinitcpio.conf.d/nvidia.conf
NVIDIA_INITCPIO_BAK=$NVIDIA_INITCPIO.thinkpad-power-orig
TPM_UNITS=(systemd-tpm2-setup.service systemd-tpm2-setup-early.service)
tpm_masked() { systemctl is-enabled "${TPM_UNITS[0]}" 2>/dev/null | grep -q masked; }

step "Boot path"

if ((BOOT_PATH == 0)); then
  if [[ -f $NVIDIA_INITCPIO_BAK ]] || tpm_masked; then
    info "already trimmed by an earlier run — ./install.sh --uninstall reverts it"
  else
    info "not touched. ./install.sh --boot-path also drops the NVIDIA driver"
    info "from the initramfs and masks unused TPM provisioning; see the README"
  fi
else
  # The boot loader reads the whole UKI off vfat before the kernel starts, so
  # every megabyte in the initramfs is paid for at every boot. Measured here:
  # 9.1 s in Limine against 11.5 s of firmware POST.
  #
  # mkinitcpio pulls in the firmware a module *declares*, and nvidia.ko declares
  # four GSP blobs that live in a 109 MB directory. Omarchy writes
  # mkinitcpio.conf.d/nvidia.conf to early-load the driver, which is correct on
  # a machine whose displays hang off the NVIDIA. Here the panel is on the iGPU
  # and this tool takes the card off the bus outright, so the driver was loaded
  # early, at maximum cost, for a device that renders nothing.
  #
  # The `kms` hook stays, and still early-loads i915 for Plymouth. Omarchy's
  # hook file drops `kms` only when nvidia_drm is in MODULES and no other GPU is
  # present, so emptying this file leaves kms in place rather than removing it.
  REBUILD_INITRAMFS=0

  # mkinitcpio sources *.conf from that directory, so the backup must not end in
  # .conf or it would be sourced too and put the MODULES line straight back.
  if [[ -f $NVIDIA_INITCPIO ]] && grep -q '^MODULES+=(nvidia' "$NVIDIA_INITCPIO"; then
    [[ -f $NVIDIA_INITCPIO_BAK ]] ||
      run sudo cp -a "$NVIDIA_INITCPIO" "$NVIDIA_INITCPIO_BAK"
    sudo tee "$NVIDIA_INITCPIO" >/dev/null <<'NVCONF'
# Emptied by thinkpad-power.
#
# Omarchy writes MODULES+=(nvidia nvidia_modeset nvidia_uvm nvidia_drm) here so
# the driver is loaded from the initramfs. That is right when the NVIDIA drives
# a display. On this machine the panel is on the iGPU and the card is taken off
# the PCI bus on battery, so the only effect was size: nvidia.ko declares four
# GSP firmware blobs, and mkinitcpio pulls the 109 MB directory holding them
# into every initramfs, which the boot loader reads off vfat at every boot.
#
# Nothing is lost. The driver still loads from the root filesystem when the
# card comes back on AC, and /etc/modprobe.d/nvidia.conf still applies
# nvidia_drm modeset=1 when it does.
#
# ./install.sh --uninstall puts the original back from nvidia.conf.thinkpad-power-orig.
NVCONF
    # A heredoc cannot go through run(), and a half-written file here is a file
    # mkinitcpio sources at the next rebuild. Check it landed.
    grep -q '^MODULES+=(nvidia' "$NVIDIA_INITCPIO" &&
      die "could not empty $NVIDIA_INITCPIO"
    REBUILD_INITRAMFS=1
    ok "NVIDIA driver and its 109 MB of GSP firmware dropped from the initramfs"
  elif [[ -f $NVIDIA_INITCPIO_BAK ]]; then
    info "initramfs already trimmed"
  else
    info "no NVIDIA early-load to remove"
  fi

  # systemd-tpm2-setup{,-early} sit on the critical chain: sysinit.target waits
  # for them, and they cost 4.1 s of a 6.0 s userspace here. They exist to
  # provision the SRK for TPM-bound disk unlock. With no LUKS volume and no
  # pcrlock policy there is nothing to unlock, so that is 4.1 s per boot for a
  # key nothing consults. Masked, not disabled: both are static units, so
  # `disable` is a no-op on them.
  if [[ $(lsblk -o FSTYPE -n 2>/dev/null | grep -c crypto_LUKS) -eq 0 ]] &&
    [[ ! -d /var/lib/systemd/pcrlock.d ]]; then
    if tpm_masked; then
      info "TPM setup units already masked"
    else
      run sudo systemctl mask "${TPM_UNITS[@]}"
      ok "TPM provisioning masked (no LUKS volume, no pcrlock policy: nothing uses it)"
    fi
  elif [[ -d /var/lib/systemd/pcrlock.d ]]; then
    info "TPM provisioning left alone — a pcrlock policy is in place"
  else
    info "TPM provisioning left alone — there is an encrypted volume to unlock"
  fi

  if ((REBUILD_INITRAMFS)); then
    if command -v limine-mkinitcpio >/dev/null 2>&1; then
      info "rebuilding the initramfs, this takes a minute..."
      run sudo limine-mkinitcpio
      ok "initramfs rebuilt"
    else
      warn "limine-mkinitcpio missing; run your own initramfs rebuild or the
    change will not take effect"
    fi
  fi
fi

# ----------------------------------------------------------------------- wake

# There is no fingerprint knob here any more, and fact 25 in CLAUDE.md is why:
# marking the reader wake-capable was measured, over a 63 min suspend, to leave
# it in a state fprintd rejects outright — "Ignoring device due to
# initialization error: unsupported firmware version" — so fingerprint unlock
# did not work at all on resume. It did cut the PAM retries from 4 to 1, which
# is the wrong trade at any price.

# ---------------------------------------------------------------------- sleep

step "Sleep"

# Measured here: S3 costs 1.26 W, so a full battery is gone in about 59 h. What
# a MacBook actually does is two things — sleep to RAM, then after a few hours
# write RAM to disk and cut power. systemd calls that suspend-then-hibernate.
#
# Everything it needs was already in place on this machine (Omarchy sets up the
# swapfile, resume= and resume_offset); what was missing is anything asking for
# it. The lid was going to plain suspend and staying there until flat.
SLEEP_CONF=/etc/systemd/sleep.conf.d/10-thinkpad-power.conf
LOGIND_CONF=/etc/systemd/logind.conf.d/10-thinkpad-power-lid.conf
SLEEP_HOOK=/usr/lib/systemd/system-sleep/thinkpad-power-resume

if ((HIBERNATE == 0)); then
  if [[ -f $SLEEP_CONF ]]; then
    info "suspend-then-hibernate already set up — ./install.sh --uninstall reverts it"
  else
    info "lid still goes to plain suspend. ./install.sh --hibernate makes it"
    info "suspend-then-hibernate: RAM for ${HIBERNATE_DELAY:-2h}, then disk, then no power"
  fi
else
  # Refuse rather than write a config that cannot work. A machine that suspends
  # and then fails to hibernate stays in S3 and drains, which looks like the
  # feature silently not working.
  hibernate_ready=1
  swapon --show=NAME --noheadings 2>/dev/null | grep -q . ||
    { warn "no swap is active; hibernation has nowhere to write"; hibernate_ready=0; }
  grep -q 'resume=' /proc/cmdline ||
    { warn "no resume= on the kernel command line; run omarchy-hibernation-setup"; hibernate_ready=0; }
  [[ -f /sys/power/image_size ]] ||
    { warn "this kernel has no hibernation support"; hibernate_ready=0; }

  if ((hibernate_ready)); then
    run sudo mkdir -p /etc/systemd/sleep.conf.d /etc/systemd/logind.conf.d
    sudo tee "$SLEEP_CONF" >/dev/null <<SLEEPCONF
# thinkpad-power. Sleep to RAM first, then hibernate and cut power.
[Sleep]
# How long to hold in S3 before writing the image out. At the 1.26 W measured
# on this machine that window costs about $(awk -v h="${HIBERNATE_DELAY_HOURS:-2}" 'BEGIN{printf "%.1f", 1.26*h}') Wh; after it, draw is
# the RTC and nothing else.
HibernateDelaySec=${HIBERNATE_DELAY:-2h}

# On mains there is nothing to save and a resume costs a full POST, so plugged
# in this stays an ordinary suspend. systemd's default here is yes, which would
# hibernate a machine sitting on a charger.
HibernateOnACPower=no
SLEEPCONF
    grep -q '^HibernateDelaySec=' "$SLEEP_CONF" 2>/dev/null ||
      die "could not write $SLEEP_CONF"
    ok "sleep.conf.d: hibernate after ${HIBERNATE_DELAY:-2h} on battery, never on AC"

    sudo tee "$LOGIND_CONF" >/dev/null <<'LOGINDCONF'
# thinkpad-power. Closing the lid is the one sleep the user does not choose
# explicitly, so it is the one that has to do the right thing on its own.
[Login]
HandleLidSwitch=suspend-then-hibernate
HandleSuspendKey=suspend-then-hibernate
LOGINDCONF
    grep -q 'suspend-then-hibernate' "$LOGIND_CONF" 2>/dev/null ||
      die "could not write $LOGIND_CONF"
    ok "logind: lid close and the suspend key use it too"

    run sudo install -Dm755 "$HERE/systemd/thinkpad-power-resume" "$SLEEP_HOOK"
    ok "resume hook (puts the discrete card back on the bus after a hibernate)"

    run sudo systemctl daemon-reload
    sudo systemctl reload systemd-logind >/dev/null 2>&1 ||
      warn "could not reload systemd-logind; the lid setting applies at next login"

    # Omarchy's menu calls systemctl suspend directly, which bypasses the lid
    # policy entirely. Same override mechanism as the GPU entry above.
    if [[ -f $MENU_FILE ]] && ! grep -q '"system.suspend"' "$MENU_FILE"; then
      tmp=$(mktemp)
      awk '
        /^\}/ && !done {
          print "  \"system.suspend\": {\"icon\":\"󰒲\",\"label\":\"Suspend\",\"action\":\"systemctl suspend-then-hibernate\"},"
          done = 1
        }
        { print }
      ' "$MENU_FILE" >"$tmp" && cat "$tmp" >"$MENU_FILE"
      rm -f "$tmp"
      own_as_user "$MENU_FILE"
      grep -q '"system.suspend"' "$MENU_FILE" &&
        ok "menu Suspend entry now uses suspend-then-hibernate too"
    else
      info "menu Suspend entry already overridden"
    fi
  else
    warn "suspend-then-hibernate not configured; fix the above and re-run"
  fi
fi

# --------------------------------------------------------------- user config

step "Session configuration"

OLD_BATTERY_PROFILE=$(cat "$STATE_HOME/omarchy/powerprofiles/battery" 2>/dev/null)

mkdir -p "$(dirname -- "$UWSM_ENV")"
touch "$UWSM_ENV"
own_as_user "$(dirname -- "$UWSM_ENV")"
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
    own_as_user "$UWSM_ENV"
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
-- runs on the iGPU here, so send them there; "thinkpad-power run" overrides
-- both per-process for anything that genuinely wants the dGPU.
hl.env("LIBVA_DRIVER_NAME", "iHD")
hl.env("__GLX_VENDOR_LIBRARY_NAME", "mesa")
-- A fullscreen window whose buffer the display controller can read directly
-- skips compositing altogether: no 3840x2400 blit per frame, which is the
-- largest single thing this GPU does while a video is playing. Hyprland ships
-- it off. 2 would enable it only for surfaces tagged "game", and a video is
-- tagged "video", so full-screen playback needs 1. The compositor drops back
-- to compositing on its own the moment anything has to be drawn on top - a
-- notification, the bar, a screen recorder - so nothing is lost by leaving it
-- on, and "hyprctl reload" undoes it live if it ever misbehaves.
hl.config({ render = { direct_scanout = 1 } })
$MARK_END
LUA
  ok "$HYPR_CONF (video decode and GLX pointed at the iGPU)"
fi

# Omarchy already switches the power profile on AC and battery and remembers
# what you chose for each; two things doing it meant the last writer won. Tell
# Omarchy what to remember instead of overriding it every plug event.
if command -v omarchy-powerprofiles-set >/dev/null 2>&1; then
  pp_state="$STATE_HOME/omarchy/powerprofiles"
  mkdir -p "$pp_state"
  own_as_user "$STATE_HOME/omarchy"
  if [[ $(cat "$pp_state/battery" 2>/dev/null) != power-saver ]]; then
    printf 'power-saver\n' >"$pp_state/battery"
    ok "Omarchy will use power-saver on battery (was: ${OLD_BATTERY_PROFILE:-unset})"
  else
    info "Omarchy already uses power-saver on battery"
  fi
  [[ -s $pp_state/ac ]] || printf 'performance\n' >"$pp_state/ac"
  omarchy-powerprofiles-set autodetect >/dev/null 2>&1
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
  own_as_user "$MENU_FILE"
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

  thinkpad-power status         what is on, what holds the GPU
  thinkpad-power run <program>  run something on the discrete GPU
  Super+Space -> Discrete GPU   toggle it by hand, no reboot

If the screen ever fails to come back after a login, switch to a TTY with
Ctrl+Alt+F2 and run:

  rm ~/.config/uwsm/env-hyprland

which undoes the GPU pin, and log in again.
NEXT
