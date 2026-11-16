#!/usr/bin/env bats

# nova doctor against a stubbed system: each check's verdict, and that only a
# FAIL fails the run.

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" XDG_DATA_HOME="$SCRATCH/data" XDG_STATE_HOME="$SCRATCH/state"
  export NOVA_SYSFS_BTRFS="$SCRATCH/sys" NOVA_PAM_DIR="$SCRATCH/pam.d" NOVA_MODULES_DIR="$SCRATCH/modules"
  export NOVA_SNAPPER_CONFIG="$SCRATCH/snapper/root" NOVA_BOOT_ESP="$SCRATCH/esp"
  export NOVA_PATCH_STATUS="$SCRATCH/patches" NOVA_RAM_TEST="$SCRATCH/ram-test.conf"
  # This computer's parts: a fake /sys and /proc, empty unless a test fills them.
  export NOVA_SYS="$SCRATCH/sysfs" NOVA_PROC="$SCRATCH/proc" NOVA_PORTABLE_MARKER="$SCRATCH/portable"
  export NOVA_HARDWARE="$SCRATCH/hardware"
  unset WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE
  mkdir -p "$HOME" "$SCRATCH/bin" "$NOVA_MODULES_DIR/6.17.0-nova1" "$NOVA_BOOT_ESP" "$NOVA_SYS/bus/pci/devices" "$NOVA_PROC"
  write_file "$NOVA_SYSFS_BTRFS/f00d/devinfo/1/error_stats" $'write_errs 0\nread_errs 0\nflush_errs 0\ncorruption_errs 0\ngeneration_errs 0\n'
  write_file "$NOVA_PAM_DIR/nova-lock-password"
  write_file "$NOVA_SNAPPER_CONFIG"

  export ROOT_OPTIONS=rw,noatime USED=41 MISSING=0 SYSTEM_FAILED='' USER_FAILED=''
  stub findmnt 'echo "btrfs $ROOT_OPTIONS f00d"'
  stub df 'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 100 1 1 %s%% /\n" "$USED"'
  # -T names what of its arguments is in NOT_INSTALLED.
  stub pacman 'case $1 in -Q) echo "nova 1.0.0beta.1-1" ;; -Qk) echo "nova: 1200 total files, $MISSING missing files" ;;
    -T) shift; for p in "$@"; do [[ " ${NOT_INSTALLED:-} " != *" $p "* ]] || echo "$p"; done ;; esac'
  stub uname 'echo 6.17.0-nova1'
  stub systemctl 'case " $* " in
    *" is-active "*"ModemManager"*) [[ -z ${MM_STOPPED:-} ]] ;;
    *" --user "*"--failed"*) [[ -z $USER_FAILED ]] || echo "$USER_FAILED loaded failed failed A unit" ;;
    *"--failed"*) [[ -z $SYSTEM_FAILED ]] || echo "$SYSTEM_FAILED loaded failed failed A unit" ;;
  esac'
  stub timedatectl 'echo yes'
  stub nova-hw-detect 'exit 1'
  stub nova-boot-check 'exit 0'
  # No undervolt tool, rather than this computer's own undervolt.
  stub nova-power-undervolt 'exit 1'
  # A desktop that can hibernate, with no kernel log to read.
  stub nova-hw-laptop 'exit 1'
  stub nova-hibernation-available 'exit 0'
  stub journalctl 'exit 0'
  export PATH="$SCRATCH/bin:$PATH"
}

# A PCI device in the fake sysfs.
pci() { # slot class vendor device [driver|-] [boot_vga]
  local dir=$NOVA_SYS/bus/pci/devices/$1
  mkdir -p "$dir"
  echo "$2" >"$dir/class"
  echo "$3" >"$dir/vendor"
  echo "$4" >"$dir/device"
  [[ ${5:--} == - ]] || ln -s "../../../bus/pci/drivers/$5" "$dir/driver"
  [[ -z ${6:-} ]] || echo "$6" >"$dir/boot_vga"
}

# The firmware's SecureBoot variable: four bytes of attributes, then the value.
secure_boot() { # 0|1
  mkdir -p "$NOVA_SYS/firmware/efi/efivars"
  printf '\x06\x00\x00\x00\x0'"$1" >"$NOVA_SYS/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
}

teardown() { teardown_scratch; }

stub() { # name [body]
  printf '#!/bin/bash\n%s\n' "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

doctor() { "$REPO_ROOT/src/cli/bin/nova-doctor" "$@"; }

@test "a healthy system: everything ok, and the run passes" {
  run doctor
  [ "$status" -eq 0 ]
  [[ $output != *warn* && $output != *FAIL* ]]
  [[ $output == *"ok    / is writable btrfs, with no device errors"* ]]
  [[ $output == *"ok    nova 1.0.0beta.1-1, every file in place"* ]]
  [[ $output == *"sudo nova doctor checks it"* ]]
}

@test "a read-only root fails, and says where to look" {
  ROOT_OPTIONS=ro,noatime run doctor
  [ "$status" -eq 1 ]
  [[ $output == *"FAIL  / is read-only"* ]]
}

@test "btrfs device errors fail, naming each counter" {
  write_file "$NOVA_SYSFS_BTRFS/f00d/devinfo/1/error_stats" $'write_errs 0\nread_errs 3\ncorruption_errs 1\n'
  run doctor
  [ "$status" -eq 1 ]
  [[ $output == *"FAIL  btrfs on / has recorded errors: read_errs 3, corruption_errs 1"* ]]
}

@test "a nearly full disk warns, a full one fails" {
  USED=91 run doctor
  [ "$status" -eq 0 ]
  [[ $output == *"warn  / is 91% full"* ]]
  USED=96 run doctor
  [ "$status" -eq 1 ]
  [[ $output == *"FAIL  / is 96% full"* ]]
}

@test "the boot partition: room for an update's images is ok, too little warns, none fails" {
  stub df 'if [[ ${!#} == "$NOVA_BOOT_ESP" ]]; then
      printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/y 100 1 1 %s%% /boot\n" "$ESP_USED"
    else
      printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 100 1 1 41%% /\n"
    fi'
  ESP_USED=40 run doctor
  [ "$status" -eq 0 ]
  [[ $output == *"ok    the boot partition is 40% full"* ]]
  ESP_USED=85 run doctor
  [ "$status" -eq 0 ]
  [[ $output == *"warn  the boot partition is 85% full: an update's boot images may not fit"* ]]
  ESP_USED=92 run doctor
  [ "$status" -eq 1 ]
  [[ $output == *"FAIL  the boot partition is 92% full, too full for an update's boot images"* ]]
  [[ $output == *"sudo snapper delete <number>"* ]]
}

@test "a boot partition that is / itself is not counted twice" {
  run doctor
  [[ $output != *"boot partition is"* ]]
}

@test "missing package files fail" {
  MISSING=3 run doctor
  [ "$status" -eq 1 ]
  [[ $output == *"FAIL  3 of nova's files are missing"* ]]
}

@test "a file a user cannot look at is not missing" {
  stub pacman 'case $1 in -Q) echo "nova 1.0.0beta.1-1" ;;
    -Qk) echo "warning: nova: /etc/sudoers.d/20-nova-pam (Permission denied)" >&2; echo "nova: 1200 total files, 1 missing file" ;; esac'
  run doctor
  [ "$status" -eq 0 ]
  [[ $output == *"ok    nova 1.0.0beta.1-1, every file in place"* ]]
}

@test "a missing file is still counted next to one a user cannot look at" {
  stub pacman 'case $1 in -Q) echo "nova 1.0.0beta.1-1" ;;
    -Qk) printf "warning: nova: /etc/sudoers.d/20-nova-pam (Permission denied)\nwarning: nova: /usr/bin/nova (No such file or directory)\n" >&2
         echo "nova: 1200 total files, 2 missing files" ;; esac'
  run doctor
  [ "$status" -eq 1 ]
  [[ $output == *"FAIL  1 of nova's files are missing"* ]]
}

@test "a kernel updated since boot is a warning" {
  rm -r "$NOVA_MODULES_DIR/6.17.0-nova1"
  run doctor
  [ "$status" -eq 0 ]
  [[ $output == *"warn  the kernel was updated since this boot"* ]]
}

@test "a lock without its PAM service fails" {
  rm "$NOVA_PAM_DIR/nova-lock-password"
  run doctor
  [ "$status" -eq 1 ]
  [[ $output == *"FAIL  the lock screen has no PAM service"* ]]
}

@test "failed services are named, system and user apart" {
  SYSTEM_FAILED=foo.service USER_FAILED=bar.service run doctor
  [ "$status" -eq 0 ]
  [[ $output == *"warn  failed system services: foo.service"* ]]
  [[ $output == *"warn  failed services of yours: bar.service"* ]]
}

@test "an unencrypted keyring warns, unless it is about to be moved" {
  write_file "$XDG_DATA_HOME/keyrings/Default_keyring.keyring" $'[keyring]\ndisplay-name=Default keyring\n'
  write_file "$XDG_DATA_HOME/keyrings/login.keyring" 'GnomeKeyring binary'
  run doctor
  [ "$status" -eq 0 ]
  [[ $output == *"warn  secrets stored unencrypted, in the keyring Default_keyring"* ]]
  [[ $output == *"echo Default_keyring >$XDG_STATE_HOME/nova/keyring-migrate-pending"* ]]
  write_file "$XDG_STATE_HOME/nova/keyring-migrate-pending"
  run doctor
  [[ $output == *"moves into your login keyring at the next unlock"* ]]
  [[ $output != *warn* ]]
}

@test "the boot fallback is checked where the EFI partition is readable" {
  write_file "$NOVA_BOOT_ESP/limine.conf" 'timeout: 1'
  stub nova-boot-check 'printf "nova-boot-check: the Limine fallback is incomplete, missing:\n  - a linux-lts fallback entry in /boot/limine.conf\nRun limine-update to rebuild it.\n" >&2; exit 1'
  run doctor
  [ "$status" -eq 1 ]
  [[ $output == *"FAIL  the boot menu's fallback is incomplete"* ]]
  [[ $output == *"- a linux-lts fallback entry in /boot/limine.conf"* ]]
}

@test "a boot check that cannot run shows its own error" {
  write_file "$NOVA_BOOT_ESP/limine.conf" 'timeout: 1'
  stub nova-boot-check 'echo "nova-boot-check: /boot/limine.conf: Permission denied" >&2; exit 1'
  run doctor
  [ "$status" -eq 1 ]
  [[ $output == *"FAIL  the boot menu's fallback is incomplete"$'\n'"      nova-boot-check: /boot/limine.conf: Permission denied"* ]]
}

@test "the shell is checked inside a session" {
  stub nova-shell 'exit 1'
  WAYLAND_DISPLAY=wayland-1 run doctor
  [[ $output == *"warn  the shell is not running"* ]]
  stub nova-shell 'echo ok'
  WAYLAND_DISPLAY=wayland-1 run doctor
  [[ $output == *"ok    the shell is running"* ]]
}

@test "Hyprland's config errors are named inside a session" {
  stub hyprctl 'echo "[\"\"]"'
  HYPRLAND_INSTANCE_SIGNATURE=x run doctor
  [[ $output == *"ok    Hyprland's config has no errors"* ]]
  stub hyprctl 'echo "[\"bindings.lua:4: unknown dispatcher\"]"'
  HYPRLAND_INSTANCE_SIGNATURE=x run doctor
  [ "$status" -eq 0 ]
  [[ $output == *"warn  Hyprland's config has errors"* ]]
  [[ $output == *"bindings.lua:4: unknown dispatcher"* ]]
  run doctor
  [[ $output != *"Hyprland"* ]]
}

@test "runs without HOME, as a service would run it" {
  run env -u HOME -u XDG_DATA_HOME -u XDG_STATE_HOME "$REPO_ROOT/src/cli/bin/nova-doctor"
  [ "$status" -eq 0 ]
  [[ $output != *unbound* ]]
}

@test "hardware: a package the profile adds and nothing has installed is a warning" {
  export NOVA_HARDWARE="$SCRATCH/hardware"
  write_file "$NOVA_HARDWARE/thinkpad-p1-gen4i/packages" $'# the profile\nfprintd\ncalf  # the tuning\nlsp-plugins-lv2\n'
  stub nova-hw-detect 'echo thinkpad-p1-gen4i'
  stub pacman 'case $1 in -Q) echo "nova 1.0.0beta.1-1" ;; -Qk) echo "nova: 1200 total files, 0 missing files" ;;
    -T) shift; for p in "$@"; do [[ $p == calf ]] && echo "$p"; done; exit 127 ;; esac'
  run doctor
  [ "$status" -eq 0 ]
  [[ $output == *"warn  packages this computer needs are not installed: calf"* ]]
  [[ $output == *"nova update installs them."* ]]
  stub pacman 'case $1 in -Q) echo "nova 1.0.0beta.1-1" ;; -Qk) echo "nova: 1200 total files, 0 missing files" ;; esac'
  run doctor
  [[ $output == *"ok    this computer's packages are installed"* ]]
}

@test "an undervolt: on, with the core's and the cache's, or held with why" {
  stub nova-power-undervolt 'echo "{\"core\":-80,\"cache\":-70,\"state\":\"applied\",\"reason\":null,\"intel\":true}"'
  run doctor
  [[ $output == *"ok    the CPU is undervolted by -80 mV on the core and -70 mV on the cache"* ]]
  stub nova-power-undervolt 'echo "{\"core\":-70,\"cache\":-70,\"state\":\"held\",\"reason\":\"a freeze\",\"intel\":true}"'
  run doctor
  [[ $output == *"warn  the CPU's undervolt is held: a freeze"* ]]
  # Held with no offset left set, the reason is still the reason.
  stub nova-power-undervolt 'echo "{\"core\":null,\"cache\":null,\"state\":\"held\",\"reason\":\"a freeze\",\"intel\":true}"'
  run doctor
  [[ $output == *"warn  the CPU's undervolt is held: a freeze"* ]]
}

@test "patches: those on named, one that cannot apply a warning, a memory test due said" {
  printf 'ram\ton\t\nbluetooth\tother\tit was made for another computer\nwake\tbad\t/etc/udev/rules.d/90-nova-patch-wake.rules is there already, and not from a patch\n' >"$NOVA_PATCH_STATUS"
  write_file "$NOVA_RAM_TEST"
  run doctor
  [ "$status" -eq 0 ]
  [[ $output == *"--    this computer's patches: ram"* ]]
  [[ $output == *"--    patches made for another computer, so off here: bluetooth"* ]]
  [[ $output == *"warn  patch wake is off: /etc/udev/rules.d/90-nova-patch-wake.rules is there already, and not from a patch"* ]]
  [[ $output == *"--    the memory test runs at the next start"* ]]
}

@test "JSON reports keep levels and repair lines, with the same failure status" {
  ROOT_OPTIONS=ro run doctor --json
  [ "$status" -eq 1 ]
  jq -e 'type == "array" and all(.[]; has("level") and has("what") and (.how | type == "array"))' <<<"$output"
  jq -e '.[0].level == "FAIL" and (.[0].how[0] | contains("journalctl"))' <<<"$output"
  USED=91 run doctor --json
  [ "$status" -eq 0 ]
  jq -e 'any(.[]; .level == "warn")' <<<"$output"
}

@test "JSON with an undervolt on: one array, the undervolt in it" {
  stub nova-power-undervolt 'echo "{\"core\":-86,\"cache\":-65,\"state\":\"applied\",\"reason\":null,\"intel\":true}"'
  doctor --json >"$SCRATCH/out" 2>"$SCRATCH/err" || true
  [ ! -s "$SCRATCH/err" ]
  jq -e 'any(.[]; .level == "ok" and (.what | startswith("the CPU is undervolted by -86 mV")))' "$SCRATCH/out"
}

@test "JSON preserves quotes and option-like repair text as data" {
  write_file "$NOVA_BOOT_ESP/limine.conf"
  stub nova-boot-check 'printf "problem\n--repair \"boot\"\n"; exit 1'
  run doctor --json
  [ "$status" -eq 1 ]
  jq -e 'any(.[]; .how | index("--repair \"boot\""))' <<<"$output"
  run doctor --unknown
  [ "$status" -eq 2 ]
}

# A laptop Nova has no profile for, working: its graphics and how it sleeps,
# and nothing else about its parts.
working_laptop() {
  stub nova-hw-laptop 'exit 0'
  pci 0000:00:02.0 0x030000 0x8086 0xa7a0 i915 1
  pci 0000:00:14.3 0x028000 0x8086 0x51f1 iwlwifi
  pci 0000:00:1f.3 0x040380 0x8086 0x51ca sof-audio-pci-intel-tgl
  mkdir -p "$NOVA_SYS/class/ieee80211/phy0" "$NOVA_SYS/class/sound/card0"
  write_file "$NOVA_SYS/power/mem_sleep" 's2idle [deep]'
}

@test "parts: a working laptop with no profile says what its graphics are and how it sleeps, and no more" {
  working_laptop
  run doctor
  [ "$status" -eq 0 ]
  [[ $output != *warn* ]]
  [[ $output == *"--    no hardware profile for this model: the generic setup"* ]]
  [[ $output == *"--    graphics: Intel (i915)"$'\n'* ]]
  [[ $output == *"--    sleep: deep (of s2idle, deep), and hibernation"* ]]
  run doctor --json
  jq -e 'all(.[]; (.level | type == "string") and (.what | type == "string") and (.how | type == "array"))' <<<"$output"
  jq -e 'any(.[]; .what == "graphics: Intel (i915)")' <<<"$output"
}

@test "parts: Secure Boot on is a warning, off says nothing" {
  secure_boot 1
  run doctor
  [ "$status" -eq 0 ]
  [[ $output == *"warn  Secure Boot is on, and Nova's boot loader is not signed for it"* ]]
  [[ $output == *"Turn Secure Boot off in the firmware settings"* ]]
  secure_boot 0
  run doctor
  [[ $output != *"Secure Boot"* ]]
}

@test "parts: firmware the kernel did not find is named once each, iwlwifi's tries not at all" {
  stub journalctl 'printf "%s\n" "Linux version 6.17.0-nova1" \
    "i915 0000:00:02.0: Direct firmware load for i915/adlp_dmc.bin failed with error -2" \
    "iwlwifi 0000:00:14.3: Direct firmware load for iwlwifi-so-a0-gf-a0-89.ucode failed with error -2" \
    "i915 0000:00:02.0: Direct firmware load for i915/adlp_dmc.bin failed with error -2" \
    "Bluetooth: hci0: firmware: failed to load intel/ibt-0040-0041.sfi (-2)"'
  run doctor
  [ "$status" -eq 0 ]
  [[ $output == *"warn  the kernel asked for firmware that is not here: i915/adlp_dmc.bin, intel/ibt-0040-0041.sfi"$'\n'* ]]
  [[ $output == *"A device may not work fully without it."* ]]
  stub journalctl 'printf "%s\n" "Linux version 6.17.0-nova1" "iwlwifi: Direct firmware load for iwlwifi-so-a0-gf-a0-89.ucode failed with error -2"'
  run doctor
  [[ $output != *firmware* ]]
}

@test "parts: a graphics card with no driver warns, and NVIDIA's says what to install" {
  pci 0000:01:00.0 0x030000 0x10de 0x2684 - 1
  pci 0000:03:00.0 0x030000 0x1002 0x744c
  run doctor
  [ "$status" -eq 0 ]
  [[ $output == *"--    graphics: NVIDIA (no driver), AMD (no driver)"* ]]
  [[ $output == *"warn  the NVIDIA graphics card has no driver"$'\n'"      NVIDIA's driver for it: sudo pacman -S --needed nvidia-open-nova nvidia-utils, then restart"* ]]
  [[ $output == *"warn  the AMD graphics card has no driver"$'\n'"      journalctl -k -b says why"* ]]
}

@test "parts: an NVIDIA card older than NVIDIA's own driver, on nouveau, is told as it is" {
  pci 0000:01:00.0 0x030000 0x10de 0x1c03 nouveau 1
  run doctor
  [ "$status" -eq 0 ]
  [[ $output == *"--    the NVIDIA card predates NVIDIA's own driver (GTX 16 and RTX 20 on), so it runs on nouveau"* ]]
  [[ $output != *warn* ]]
}

@test "parts: NVIDIA driving the display without its VA-API driver decodes video on the CPU" {
  pci 0000:00:02.0 0x030000 0x8086 0x4680 i915 0
  pci 0000:01:00.0 0x030000 0x10de 0x2684 nvidia 1
  NOT_INSTALLED=libva-nvidia-driver run doctor
  [[ $output == *"warn  video is decoded by the CPU: NVIDIA drives the display"*"sudo pacman -S libva-nvidia-driver"* ]]
  run doctor
  [[ $output != *"VA-API"* ]]
  # A hybrid laptop decodes on its iGPU.
  echo 1 >"$NOVA_SYS/bus/pci/devices/0000:00:02.0/boot_vga"
  echo 0 >"$NOVA_SYS/bus/pci/devices/0000:01:00.0/boot_vga"
  NOT_INSTALLED=libva-nvidia-driver run doctor
  [[ $output != *"VA-API"* ]]
}

@test "parts: a hybrid laptop's NVIDIA card asleep is ok, awake with no display costs battery; the P1 and desktops are left out" {
  stub nova-hw-laptop 'exit 0'
  pci 0000:00:02.0 0x030000 0x8086 0x9a60 i915 1
  pci 0000:01:00.0 0x030000 0x10de 0x25b8 nvidia 0
  local card=$NOVA_SYS/bus/pci/devices/0000:01:00.0
  write_file "$card/power/runtime_status" suspended
  write_file "$card/drm/card0/card0-HDMI-A-1/status" disconnected
  run doctor
  [[ $output == *"ok    the NVIDIA card sleeps while nothing uses it"* ]]
  echo active >"$card/power/runtime_status"
  run doctor
  [ "$status" -eq 0 ]
  [[ $output == *"--    the NVIDIA card is awake with no display on it, which costs battery unplugged: a program is using it"*"sudo fuser -v /dev/nvidia* names the programs"* ]]
  # A GTX 16 or RTX 20 sleeps only when its driver is asked to: 3 is NVIDIA's
  # default, which leaves it off for them.
  echo 0x1f91 >"$card/device"
  write_file "$NOVA_SYS/module/nvidia/parameters/NVreg_DynamicPowerManagement" 3
  run doctor
  [ "$status" -eq 0 ]
  [[ $output == *"--    the NVIDIA card stays awake while nothing uses it"*"a GTX 16 or RTX 20 sleeps only when its driver is asked to"*"NVreg_DynamicPowerManagement=0x02"*"/etc/modprobe.d/nova-nvidia-sleep.conf"*"delete that file"* ]]
  # Asked to, and awake all the same: a program holds it.
  echo 2 >"$NOVA_SYS/module/nvidia/parameters/NVreg_DynamicPowerManagement"
  run doctor
  [[ $output == *"awake with no display on it"*"a program is using it"* ]]
  [[ $output != *"sleeps only when its driver is asked to"* ]]
  echo 0x25b8 >"$card/device"
  # A display on it is what keeps it awake.
  echo connected >"$card/drm/card0/card0-HDMI-A-1/status"
  run doctor
  [[ $output != *"NVIDIA card is awake"* ]]
  echo disconnected >"$card/drm/card0/card0-HDMI-A-1/status"
  stub nova-hw-detect 'echo thinkpad-p1-gen4i'
  run doctor
  [[ $output != *"NVIDIA card"* ]]
  stub nova-hw-detect 'exit 1'
  stub nova-hw-laptop 'exit 1'
  run doctor
  [[ $output != *"NVIDIA card"* ]]
}

@test "parts: Wi-Fi or sound hardware with no device for it warns" {
  pci 0000:00:14.3 0x028000 0x8086 0x2725 -
  pci 0000:00:1f.3 0x040300 0x8086 0xa0c8 -
  run doctor
  [ "$status" -eq 0 ]
  [[ $output == *"warn  no Wi-Fi: the Wi-Fi card (Intel 0x2725) has no driver, or no firmware for it"* ]]
  [[ $output == *"warn  no sound card: the sound hardware has no driver, or no firmware for it"* ]]
  mkdir -p "$NOVA_SYS/class/ieee80211/phy0" "$NOVA_SYS/class/sound/card0"
  run doctor
  [[ $output != *"no Wi-Fi"* && $output != *"no sound card"* ]]
}

@test "parts: a cellular modem without ModemManager installed, or not running, warns" {
  pci 0000:08:00.0 0x0d4000 0x105b 0xe0ab mhi-pci-generic
  run doctor
  [[ $output != *"ModemManager"* ]]
  MM_STOPPED=1 run doctor
  [[ $output == *"warn  ModemManager is not running, so mobile data cannot work"* ]]
  [[ $output == *"sudo systemctl enable --now ModemManager.service"* ]]
  NOT_INSTALLED=modemmanager run doctor
  [[ $output == *"warn  the cellular modem has no ModemManager, so mobile data cannot work"* ]]
}

@test "parts: an Intel MIPI camera with no video device, or no libcamera for apps to see it" {
  pci 0000:00:05.0 0x048000 0x8086 0xa75d intel-ipu6
  run doctor
  [[ $output == *"warn  the camera (Intel IPU) has no video device: its driver or firmware did not load"* ]]
  mkdir -p "$NOVA_SYS/bus/pci/devices/0000:00:05.0/intel_ipu6.isys.40/video4linux/video0"
  NOT_INSTALLED="pipewire-libcamera" run doctor
  [[ $output == *"warn  apps cannot see the camera: it needs libcamera"*"sudo pacman -S libcamera libcamera-ipa pipewire-libcamera"* ]]
  run doctor
  [[ $output != *camera* ]]
  # Not every Intel device is a camera.
  rm -r "$NOVA_SYS/bus/pci/devices/0000:00:05.0"
  pci 0000:00:05.0 0x048000 0x8086 0x1234
  run doctor
  [[ $output != *camera* ]]
}

@test "parts: sleep without hibernation: why, as a warning on a laptop and as information on a desktop" {
  write_file "$NOVA_SYS/power/mem_sleep" '[s2idle]'
  write_file "$NOVA_SYS/power/state" 'freeze mem'
  write_file "$NOVA_PROC/swaps" $'Filename\tType\tSize\tUsed\tPriority\n/dev/zram0 partition 8388604 0 100\n'
  write_file "$NOVA_PROC/meminfo" 'MemTotal:       16000000 kB'
  write_file "$NOVA_PROC/cmdline" 'root=PARTUUID=x rw quiet'
  run doctor
  [[ $output == *"--    sleep: s2idle, and hibernation"* ]]
  stub nova-hibernation-available 'exit 1'
  run doctor
  [ "$status" -eq 0 ]
  [[ $output == *"--    sleep: s2idle; no hibernation"$'\n'"      The kernel offers no hibernation."$'\n'"      There is no swap on a disk to keep the memory in."$'\n'"      The boot line has no resume=, so a hibernated image may not be found."* ]]
  stub nova-hw-laptop 'exit 0'
  write_file "$NOVA_SYS/power/state" 'freeze mem disk'
  write_file "$NOVA_PROC/swaps" $'Filename\tType\tSize\tUsed\tPriority\n/swap/swapfile file 8388604 0 -2\n'
  write_file "$NOVA_PROC/cmdline" 'root=PARTUUID=x rw resume=PARTUUID=x resume_offset=1'
  run doctor
  [[ $output == *"warn  this computer cannot hibernate, so a closed lid only suspends, which empties the battery in a few days"$'\n'"      The swap (8 GiB) is smaller than the memory (15 GiB)."* ]]
  write_file "$NOVA_PORTABLE_MARKER"
  run doctor
  [[ $output == *"--    sleep: s2idle; a portable Nova never hibernates"* ]]
  [[ $output != *"cannot hibernate"* ]]
}

# --- --bundle --------------------------------------------------------------------

# A world with something to hide in each place a report reads from: the
# journal, the crashes, the firmware's serial numbers, AirDrop's phone.
bundle_world() {
  mkdir -p "$HOME/Fetched" "$HOME/.config"
  # shellcheck disable=SC2016 # $HOME is user-dirs.dirs' own
  printf 'XDG_DOWNLOAD_DIR="$HOME/Fetched"\n' >"$HOME/.config/user-dirs.dirs"
  write_file "$XDG_STATE_HOME/nova/airdrop/phones" 'a1b2 c3d4 e5f6 0718'
  write_file "$NOVA_PROC/sys/kernel/hostname" 'andres-p1'
  export USER=andres
  local field
  for field in sys_vendor:LENOVO product_name:20Y4S34G33 "product_version:ThinkPad P1 Gen 4i" "bios_version:N40ET53W (1.35 )" \
    product_serial:SERIAL-PRODUCT board_serial:SERIAL-BOARD product_uuid:4c4c4544-0042-3510-8051-b4c04f4b3732; do
    write_file "$NOVA_SYS/class/dmi/id/${field%%:*}" "${field#*:}"
  done
  export SECRET_LINE="wlan0: a4:c3:f0:12:34:56 at 192.168.1.23 and fe80::1c2b:3cff:fe4d:5e6f, SSID 'HomeNet', $HOME/notes.txt, SerialNumber: ABC123, IMEI: 356938035643809, boot 0d3c1f5e-7a2b-4c9d-8e1f-2a3b4c5d6e7f, machine 4c1e2a7b9d3f4e5a8b6c7d8e9f0a1b2c, phone A1B2, host Andres-P1.local, pam session for user \"andres\" on /run/media/andres/disk, this computer is \"Andre's ThinkPad\" to senders"
  stub journalctl 'case " $* " in
    *" -p warning "*) echo "2026-11-16T10:00:00+01:00 NetworkManager[700]: <warn> $SECRET_LINE" ;;
    *" -k "*) ;;
    *) printf "%s\n" \
      "2026-11-16T10:00:01+01:00 kernel: usb 3-9: $SECRET_LINE" \
      "2026-11-16T10:00:02+01:00 nova-powerd[900]: tier 2" \
      "    and a line that goes with it" \
      "2026-11-16T10:00:03+01:00 ModemManager[744]: <info> not Nova" \
      "2026-11-16T10:00:04+01:00 systemd[1]: nova-power.service: Deactivated successfully." \
      "2026-11-16T10:00:05+01:00 quickshell[1200]: the shell" ;;
  esac'
  stub coredumpctl 'echo "Sun 2026-11-16 10:00:00 CET 4242 1000 1000 SIGSEGV missing $HOME/bin/crashy"'
  stub snapper 'echo "No permissions."'
  stub lspci 'echo "00:1f.6 Ethernet controller [0200]: Intel Corporation Ethernet Connection [8086:15fc] (rev 20)"'
  stub lsusb 'echo "Bus 003 Device 008: ID 13d3:5271 IMC Networks Integrated RGB Camera"'
  stub pacman 'case $1 in
    -Qq) printf "%s\n" nova linux-nova hyprland quickshell firefox ;;
    -Q) shift; if (($#)); then for p; do echo "$p 1.0-1"; done; else echo "nova 1.0.0beta.1-1"; fi ;;
    -Qk) echo "nova: 1200 total files, 0 missing files" ;;
  esac'
}

unpacked() { # the report, unpacked into $SCRATCH/report; prints its folder
  mkdir -p "$SCRATCH/report"
  tar -C "$SCRATCH/report" -xzf "$1"
  echo "$SCRATCH/report"/nova-report-*
}

@test "--bundle: one file in the downloads folder, its path, then a line of what is in it" {
  bundle_world
  run doctor --bundle
  [ "$status" -eq 0 ]
  [[ ${lines[0]} =~ ^"$HOME/Fetched/nova-report-"[0-9-]+\.tar\.gz$ ]]
  [[ ${lines[1]} == "Inside: this check, the journal of this start and the last"*", crashes, snapshots, package versions, no boot menu (sudo adds it), the model, and its PCI and USB devices. Masked: "* ]]
  [ "${#lines[@]}" -eq 2 ]
  [ "$(stat -c %a "${lines[0]}")" = 600 ]
  local dir
  dir=$(unpacked "${lines[0]}")
  [ "$(cd "$dir" && ls | paste -sd' ')" = "boot-entries.txt crashes.txt doctor.txt journal-last-start-nova.txt journal-last-start-warnings.txt journal-this-start-nova.txt journal-this-start-warnings.txt model.txt packages.txt pci.txt snapshots.txt usb.txt" ]
  grep -q '^ok    / is writable btrfs' "$dir/doctor.txt"
  [ "$(cat "$dir/packages.txt")" = "nova 1.0-1
linux-nova 1.0-1
hyprland 1.0-1
quickshell 1.0-1" ]
  grep -qx 'product_version  ThinkPad P1 Gen 4i' "$dir/model.txt"
  grep -q 'Intel Corporation Ethernet Connection \[8086:15fc\]' "$dir/pci.txt"
  grep -q 'Integrated RGB Camera' "$dir/usb.txt"
  grep -qx 'No permissions.' "$dir/snapshots.txt"
  # Nova's own lines, the shell's and the kernel's, and nobody else's.
  grep -q 'nova-powerd\[900\]: tier 2' "$dir/journal-this-start-nova.txt"
  grep -qx '    and a line that goes with it' "$dir/journal-this-start-nova.txt"
  grep -q 'systemd\[1\]: nova-power.service: Deactivated' "$dir/journal-this-start-nova.txt"
  grep -q 'quickshell\[1200\]: the shell' "$dir/journal-this-start-nova.txt"
  grep -q 'kernel: usb 3-9' "$dir/journal-this-start-nova.txt"
  fails grep -q ModemManager "$dir/journal-this-start-nova.txt"
  grep -q 'NetworkManager\[700\]' "$dir/journal-this-start-warnings.txt"
}

@test "--bundle: nothing in it says whose computer it is" {
  bundle_world
  run doctor --bundle
  [ "$status" -eq 0 ]
  local dir secret
  dir=$(unpacked "${lines[0]}")
  for secret in a4:c3:f0:12:34:56 192.168.1.23 fe80::1c2b 3cff:fe4d HomeNet "$HOME" ABC123 356938035643809 \
    0d3c1f5e-7a2b 4c1e2a7b9d3f4e5a8b6c7d8e9f0a1b2c "Andre's ThinkPad" andres-p1 SERIAL-PRODUCT SERIAL-BOARD 4c4c4544; do
    fails grep -rqF -- "$secret" "$dir"
  done
  fails grep -rqiw a1b2 "$dir"
  fails grep -rqiF andres "$dir"
  grep -qF "XX:XX:XX:XX:XX:XX at <ip> and <ip>, SSID '<network>', ~/notes.txt, SerialNumber: <serial>, IMEI: <serial>, boot <uuid>, machine <id>, phone <phone>, host <computer>.local, pam session for user \"<user>\" on /run/media/<user>/disk, this computer is \"<name>\" to senders" "$dir/journal-this-start-warnings.txt"
  grep -qF '~/bin/crashy' "$dir/crashes.txt"
}

@test "--bundle into a folder, or into a file named" {
  bundle_world
  mkdir -p "$SCRATCH/out"
  run doctor --bundle "$SCRATCH/out"
  [ "$status" -eq 0 ]
  [[ ${lines[0]} =~ ^"$SCRATCH/out/nova-report-"[0-9-]+\.tar\.gz$ ]]
  [ -f "${lines[0]}" ]
  run doctor --bundle "$SCRATCH/out/mine.tar.gz"
  [ "${lines[0]}" = "$SCRATCH/out/mine.tar.gz" ]
  tar -tzf "$SCRATCH/out/mine.tar.gz" | grep -q '/doctor.txt$'
  # No downloads folder: the home.
  rm -rf "$HOME/Fetched" "$HOME/.config"
  run doctor --bundle
  [[ ${lines[0]} =~ ^"$HOME/nova-report-" ]]
  run doctor --bundle a b
  [ "$status" -eq 2 ]
}

@test "--bundle with the boot menu readable names its entries, never their command lines" {
  bundle_world
  write_file "$NOVA_BOOT_ESP/limine.conf" '/+Nova
  comment: machine-id=4c1e2a7b9d3f4e5a8b6c7d8e9f0a1b2c
  //linux-nova
    cmdline: root=UUID=0d3c1f5e-7a2b-4c9d-8e1f-2a3b4c5d6e7f rw
'
  run doctor --bundle
  [[ ${lines[1]} == *"the boot menu's entries"* ]]
  local dir
  dir=$(unpacked "${lines[0]}")
  [ "$(cat "$dir/boot-entries.txt")" = "/+Nova
//linux-nova" ]
}
