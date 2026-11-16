# shellcheck shell=bash
# installer/install-machine.bash: nova-install's look at this computer:
# whether it can start Nova (UEFI, and Secure Boot off), the kernel its CPU
# takes, and the packages its hardware and its model's profile add.
# Sourced by nova-install, never run.

# ------------------------------------------------------------- the machine

cpu_has_x86_64_v3() {
  local flags f
  flags=$(grep -m 1 '^flags' "$CPUINFO" 2>/dev/null) || return 1
  for f in avx avx2 bmi1 bmi2 f16c fma abm movbe xsave; do
    [[ " ${flags#*:} " == *" $f "* ]] || return 1
  done
}

cpu_vendor() {
  awk -F': ' '/^vendor_id/ { print $2; exit }' "$CPUINFO" 2>/dev/null
}

# Whether the firmware has Secure Boot on. Its SecureBoot variable is four
# bytes of attributes and one of value, 1 when on. Firmware without it has no
# Secure Boot to be on, and one that cannot be read counts as off: this stops
# an install, so only a plain yes does.
secure_boot_on() {
  local value
  value=$(od -An -tu1 -j4 -N1 -- "$EFI/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c" 2>/dev/null) || return 1
  [[ ${value//[[:space:]]/} == 1 ]]
}

# What turning Secure Boot off costs a PC with Windows on it.
BITLOCKER_NOTE=$'A PC with Windows and BitLocker or Device Encryption asks for its recovery\nkey at its next start once Secure Boot is off: have the key at hand first.'

# This computer has to be set otherwise before Nova can go on it: said on a
# screen of its own, before any question, with nothing changed. Exits 3, so
# nova-install-start knows trying again as it is would not help.
not_ready() { # setting what [note...]
  local note
  if [[ -z $ANSWERS ]]; then screen '' "$1"; else echo >&2; fi
  ui_error "$2"
  for note in "${@:3}"; do
    echo >&2
    ui_note "$note"
  done
  exit 3
}

# Nova goes only onto a computer that will start it: one that booted the stick
# with UEFI, and with Secure Boot off, since Limine and the kernels Nova
# installs are not signed for it. A portable install is made here and started
# elsewhere, so this computer's settings are no matter to it; its last screen
# says what the PCs it starts need.
computer_ready() {
  ((!PORTABLE)) || return 0
  [[ -d $EFI ]] ||
    not_ready UEFI "This computer started the stick in legacy BIOS mode; Nova needs UEFI." \
      $'Turn on UEFI boot in the firmware settings, then start this stick again.\nNothing was changed.'
  if secure_boot_on; then
    not_ready "Secure Boot" "Secure Boot is on, so this computer would not start Nova once installed." \
      $'Nova\'s boot loader is not signed for it. Turn Secure Boot off in the\nfirmware settings: restart, press the setup key as the computer starts (F2,\nF1, Del or Esc on most; Enter, then F1, on a ThinkPad), set Secure Boot to\nDisabled under Security or Boot, save, and start this stick again.\nNothing was changed.' \
      "$BITLOCKER_NOTE"
  fi
}

# The kernel Nova boots: linux-nova is built for x86-64-v3, so an older CPU
# gets Arch's own kernel instead. linux-lts is installed either way as the
# fallback entry. A portable install cannot know which CPU it will start on
# next, so it always has Arch's.
main_kernel() {
  if ((!PORTABLE)) && cpu_has_x86_64_v3; then echo linux-nova; else echo linux; fi
}

# A portable install starts a different computer each time, so it has what any
# of them needs: both microcodes (the initramfs loads the one that fits) and
# the Intel and AMD video drivers. NVIDIA cards run on nouveau, with NVK for
# Vulkan: NVIDIA's own driver blacklists nouveau and drives nothing older than
# Turing, so on the computers it does not fit it would leave no driver at all.
portable_packages() {
  printf '%s\n' intel-ucode amd-ucode "${GPU_INTEL[@]}" "${GPU_AMD[@]}" "${GPU_NOUVEAU[@]}"
}

# Packages this hardware needs, from the CPU, and the display controllers
# and camera in sysfs (never lspci, which wakes a sleeping GPU). The
# model's own profile adds to this; see profile_packages. A portable install's
# are portable_packages.
hardware_packages() {
  local kernel=$1 dev vendor device dgpu=0 igpu=0 camera=0
  if ((PORTABLE)); then
    portable_packages
    return 0
  fi
  case $(cpu_vendor) in
    GenuineIntel) echo intel-ucode ;;
    AuthenticAMD) echo amd-ucode ;;
  esac
  for dev in "$PCI_DEVICES"/*; do
    [[ -r $dev/class ]] || continue
    vendor=$(<"$dev/vendor")
    if [[ $vendor == 0x8086 && $IPU_IDS == *" $(<"$dev/device") "* ]]; then camera=1; continue; fi
    [[ $(<"$dev/class") == 0x03* ]] || continue
    case $vendor in
      0x8086) printf '%s\n' "${GPU_INTEL[@]}"; igpu=1 ;;
      0x1002) printf '%s\n' "${GPU_AMD[@]}"; igpu=1 ;;
      0x10de)
        device=$(<"$dev/device")
        # The open modules need GSP firmware, which starts with Turing. The
        # LTS fallback kernel gets its own build, so it can drive the card too.
        if ((device >= 0x1e00)); then
          if [[ $kernel == linux-nova ]]; then echo nvidia-open-nova; else echo nvidia-open; fi
          echo nvidia-open-lts
          echo nvidia-utils
          dgpu=1
        fi
        ;;
    esac
  done
  # With an integrated GPU beside it, the desktop and the browser run on that
  # one, and prime-run puts a game on the NVIDIA card. Whichever card drives
  # the monitors decodes video, which the session decides as it starts
  # (data/hypr/gpu.lua): a desktop with its iGPU on and its monitors on the
  # NVIDIA card has VA-API pointed at NVIDIA's driver, so it is always there.
  if ((dgpu && igpu)); then echo nvidia-prime; fi
  if ((dgpu)); then echo libva-nvidia-driver; fi
  if ((camera)); then printf '%s\n' "${CAMERA_IPU[@]}"; fi
}

# This computer's model, as its maker names it; `fallback` when no DMI field
# does.
computer_model() { # fallback
  NOVA_DMI_PATH=$DMI "$SHARE/hardware/nova-hw-model" 2>/dev/null || echo "$1"
}

# The model's profile, which a portable install never takes: the computer it
# is made on is only the first of many.
hardware_profile() {
  ((!PORTABLE)) || return 0
  NOVA_HARDWARE=$SHARE/hardware "$SHARE/hardware/nova-hw-detect" 2>/dev/null || true
}

# The model profile's package list. nvidia-open-nova only exists for linux-nova,
# so an older CPU gets Arch's nvidia-open in its place.
profile_packages() {
  local profile=$1 kernel=$2 name
  [[ -n $profile && -r $SHARE/hardware/$profile/packages ]] || return 0
  while IFS= read -r name; do
    name=${name%%#*}
    name=${name//[[:space:]]/}
    [[ -n $name ]] || continue
    if [[ $name == nvidia-open-nova && $kernel != linux-nova ]]; then name=nvidia-open; fi
    echo "$name"
  done <"$SHARE/hardware/$profile/packages"
}

# Every package an install on any computer could ask for, for the offline
# repository nova usb puts on a stick: one stick installs any machine.
every_package() {
  local list
  {
    grep -v -e '^#' -e '^[[:space:]]*$' "$SHARE/packages"
    printf '%s\n' linux-nova linux linux-lts intel-ucode amd-ucode "${GPU_INTEL[@]}" "${GPU_AMD[@]}" "${GPU_NOUVEAU[@]}" \
      nvidia-open-nova nvidia-open nvidia-open-lts nvidia-utils nvidia-prime libva-nvidia-driver "${CAMERA_IPU[@]}"
    for list in "$SHARE"/hardware/*/packages; do
      [[ -r $list ]] || continue
      sed 's/#.*//; s/[[:space:]]//g; /^$/d' "$list"
    done
  } | awk '!seen[$0]++'
}

# Everything pacstrap installs, one per line, without duplicates.
package_set() { # kernel profile [package...]
  local kernel=$1 profile=$2
  {
    grep -v -e '^#' -e '^[[:space:]]*$' "$SHARE/packages"
    echo "$kernel"
    echo linux-lts
    hardware_packages "$kernel"
    profile_packages "$profile" "$kernel"
    printf '%s\n' "${@:3}"
  } | awk 'NF && !seen[$0]++'
}
