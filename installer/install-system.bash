# shellcheck shell=bash
# installer/install-system.bash: the new system set up: its boot line and
# boot loader, a portable install's own files, fstab, names and release
# pins, snapshots and services, and the last step, which unmounts it.
# Sourced by nova-install, never run.

# ------------------------------------------------------------- the boot line

# The machine-specific half of the kernel command line; the quiet-boot half is
# in /etc/limine-entry-tool.d/10-nova.conf. zswap is off because zram does the
# compressing. rootflags=subvol=@ is the form limine-snapper-sync rewrites to
# boot a snapshot. root is PARTUUID=<the partition's>, or, encrypted,
# /dev/mapper/nova-root, which rd.luks.name has the initramfs open with the
# passphrase it asks for; the swap file, and so resume, is inside it. A
# portable install has no swap file, so no resume either.
install_cmdline() { # root resume-offset|"" [luks-uuid]
  local root=$1 resume_offset=$2 luks=${3:-}
  [[ -z $luks ]] || printf 'rd.luks.name=%s=%s ' "$luks" "$BOOT_CRYPT_NAME"
  printf 'root=%s rootflags=subvol=@ rw rootfstype=btrfs zswap.enabled=0' "$root"
  [[ -z $resume_offset ]] || printf ' resume=%s resume_offset=%s' "$root" "$resume_offset"
}

# An encrypted install's initramfs asks for the passphrase (sd-encrypt), in
# the keyboard layout picked (sd-vconsole, from /etc/vconsole.conf): both put
# into Nova's own HOOKS line, wherever a later Nova moves the rest of it.
encrypt_mkinitcpio_conf() {
  cat <<'CONF'
# Written by nova-install: the root is encrypted. The initramfs asks for its
# passphrase, in the keyboard layout of /etc/vconsole.conf.
_nova_hooks=()
for _nova_hook in "${HOOKS[@]}"; do
  case $_nova_hook in
    keyboard) _nova_hooks+=(keyboard sd-vconsole) ;;
    block) _nova_hooks+=(block sd-encrypt) ;;
    *) _nova_hooks+=("$_nova_hook") ;;
  esac
done
HOOKS=("${_nova_hooks[@]}")
unset _nova_hooks _nova_hook
CONF
}

limine_install_conf() {
  local cmdline=$1 kernel=$2
  echo "# Written by nova-install for this machine's disk."
  printf 'KERNEL_CMDLINE[default]+=" %s"\n' "$cmdline"
  if [[ $kernel != linux-nova ]]; then
    if ((PORTABLE)); then
      echo "# Portable: Arch's kernel stands in for linux-nova, so any 64-bit CPU starts it."
    else
      echo "# This CPU predates x86-64-v3, so Arch's kernel stands in for linux-nova."
    fi
    echo "MKINITCPIO_FALLBACK=$kernel"
    echo "BOOT_ORDER=\"$kernel, *fallback, linux-lts, *, Snapshots\""
  fi
  if ((PORTABLE)); then
    # limine-install reads this at every run, the limine package's own hook
    # after an update included, so the promise holds for as long as the stick
    # is used, not only on the day it is made.
    echo "# Portable: Limine starts from EFI/BOOT/BOOTX64.EFI on the stick, and no"
    echo "# computer it meets gets a boot entry written into its firmware."
    echo "SKIP_UEFI=yes"
  fi
}

# The initramfs of a portable install is for every computer, not the one it
# was built on: without autodetect it holds every disk, USB and keyboard
# driver, so the stick starts, and its passphrase can be typed, anywhere.
# Without kms, about a third of the size: kms would add every GPU driver and
# its firmware, for the screen to change mode a second sooner. The video
# driver then loads from the stick.
portable_mkinitcpio_conf() {
  cat <<'CONF'
# Written by nova-install --portable: an initramfs for every computer this
# stick starts, not only the one it was made on.
_nova_hooks=()
for _nova_hook in "${HOOKS[@]}"; do
  case $_nova_hook in
    autodetect | nova-blacklist | kms) ;;
    *) _nova_hooks+=("$_nova_hook") ;;
  esac
done
HOOKS=("${_nova_hooks[@]}")
unset _nova_hooks _nova_hook
CONF
}

# No hibernation on a portable install: there is no swap file to write memory
# to, and an image written on one computer must never resume on another.
portable_sleep_conf() {
  cat <<'CONF'
# Written by nova-install --portable: sleep is suspend alone. A hibernated
# image must never resume on another computer, and there is no swap file to
# write one to.
[Sleep]
AllowHibernation=no
AllowSuspendThenHibernate=no
AllowHybridSleep=no
CONF
}

portable_marker() {
  cat <<'MARKER'
# Written by nova-install --portable. This Nova runs from a USB disk, on
# whatever computer it is plugged into, so nothing tuned for one model applies:
# nova-hw-apply puts no model's files in /etc, nova update adds no model's
# packages, and nova power undervolt stays off.
MARKER
}

# What makes a portable install one, written before pacstrap: the kernels'
# install hooks build the initramfs with the mkinitcpio drop-in, and the nova
# package's own hook (nova-hw-apply) reads the marker.
write_portable_config() {
  portable_marker | install -Dm644 /dev/stdin "$TARGET$PORTABLE_MARKER"
  portable_mkinitcpio_conf | install -Dm644 /dev/stdin "$TARGET/etc/mkinitcpio.conf.d/30-nova-portable.conf"
  portable_sleep_conf | install -Dm644 /dev/stdin "$TARGET/etc/systemd/sleep.conf.d/20-nova-portable.conf"
}

# Into portable mode, from --portable or an answers file's portable=yes. The
# container is opened under a name of its own: nova usb runs this on a running
# system, which may be a Nova with its own nova-root. Encryption starts ticked
# on screen: a stick is easy to lose.
portable_mode() {
  PORTABLE=1
  # shellcheck disable=SC2034 # install-disk.bash opens the container under it
  CRYPT_NAME=nova-usb-root
  ENCRYPT=yes
}

# genfstab writes subvolid= next to subvol=, and a subvolid pins the mount to
# one subvolume forever: rolling back to a snapshot would mount the old one.
strip_subvolid() {
  sed -E 's/,subvolid=[0-9]+//; s/subvolid=[0-9]+,//'
}

write_system_config() {
  local hostname=$1 timezone=$2 keymap=$3 arch_date=$4 nova_repo=$5 tag=$6
  say "Configuring the system"
  genfstab -U "$TARGET" | strip_subvolid >"$TARGET/etc/fstab"
  # genfstab lists the swap file it saw active; make sure it is there.
  if [[ -e $TARGET/swap/swapfile ]] && ! grep -q '/swap/swapfile' "$TARGET/etc/fstab"; then
    echo '/swap/swapfile none swap defaults 0 0' >>"$TARGET/etc/fstab"
  fi

  write_names "$hostname" "$timezone"
  sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' "$TARGET/etc/locale.gen"
  in_target locale-gen
  echo 'LANG=en_US.UTF-8' >"$TARGET/etc/locale.conf"
  write_keyboard "$keymap"

  install -Dm644 "$SHARE/pacman.conf" "$TARGET/etc/pacman.conf"
  write_release_pins "$arch_date" "$nova_repo" "$tag"
}

# The same two files nova update rewrites for every release, so the installed
# system starts on the release it was installed from.
write_release_pins() {
  local arch_date=$1 nova_repo=$2 tag=$3
  {
    echo '# Managed by nova update; the next update rewrites this file.'
    printf '# nova-release: %s\n# arch-date: %s\n' "$tag" "$arch_date"
    # shellcheck disable=SC2016 # $repo and $arch are pacman's to expand
    printf 'Server = https://archive.archlinux.org/repos/%s/$repo/os/$arch\n' "$arch_date"
  } >"$TARGET/etc/pacman.d/nova-mirrorlist"
  {
    echo '# Managed by nova update; the next update rewrites this file.'
    printf '# nova-release: %s\nServer = %s\n' "$tag" "$nova_repo"
  } >"$TARGET/etc/pacman.d/nova-repo"
}

configure_snapper() {
  # What `snapper create-config` writes, without the .snapshots subvolume it
  # would create: @snapshots is already mounted there, outside the root
  # subvolume, so a rollback does not take the snapshots with it.
  install -Dm644 "$TARGET/usr/share/snapper/config-templates/nova" "$TARGET/etc/snapper/configs/root"
  echo 'SNAPPER_CONFIGS="root"' >"$TARGET/etc/conf.d/snapper"
}

# Written before pacstrap, so that everything the boot loader step reads is
# in place however the packages' hooks go: the root and resume arguments,
# the keyboard layout an encrypted disk is opened with, the Limine header.
prepare_boot_config() {
  local disk=$1 kernel=$2 root partuuid offset='' luks cmdline
  root=$(partition_path "$disk" 2)
  if ((!PORTABLE)); then
    offset=$(btrfs inspect-internal map-swapfile -r "$TARGET/swap/swapfile")
    [[ $offset =~ ^[0-9]+$ ]] || die "could not find the swap file's offset"
  fi
  if [[ $ENCRYPT == yes ]]; then
    luks=$(cryptsetup luksUUID "$root")
    [[ -n $luks ]] || die "could not read the LUKS UUID of $root"
    cmdline=$(install_cmdline "/dev/mapper/$BOOT_CRYPT_NAME" "$offset" "$luks")
    encrypt_mkinitcpio_conf | install -Dm644 /dev/stdin "$TARGET/etc/mkinitcpio.conf.d/20-nova-encrypt.conf"
    # The initramfs opens the disk on the console, in the keyboard layout
    # picked: it has to be there before any is built.
    write_keyboard "$KEYMAP"
  else
    partuuid=$(blkid -s PARTUUID -o value "$root")
    [[ -n $partuuid ]] || die "could not read the PARTUUID of $root"
    cmdline=$(install_cmdline "PARTUUID=$partuuid" "$offset")
  fi
  mkdir -p "$TARGET/etc/limine-entry-tool.d"
  limine_install_conf "$cmdline" "$kernel" >"$TARGET/etc/limine-entry-tool.d/90-nova-install.conf"
  ((!PORTABLE)) || write_portable_config
  install -Dm644 "$SHARE/limine.conf" "$TARGET/boot/limine.conf"
}

install_bootloader() {
  say "Installing the boot loader"
  # --fallback also puts Limine at EFI/BOOT/BOOTX64.EFI, so the disk boots even
  # if the firmware forgets its boot entries. A portable stick starts from
  # there alone: its SKIP_UEFI=yes (limine_install_conf) already keeps this
  # computer's firmware out of it, and --no-efi-register says so here too.
  if ((PORTABLE)); then
    in_target limine-install --fallback --no-efi-register
  else
    in_target limine-install --fallback
  fi
  in_target limine-update
  # The same check nova update makes: every kernel has an entry, and every file
  # an entry loads is on the ESP.
  in_target /usr/lib/nova/bin/nova-boot-check post || die "the boot entries did not check out; the log is in $LOG"
}

enable_services() {
  say "Enabling services"
  iwd_to_networkmanager "$TARGET/etc/NetworkManager/system-connections"
  in_target systemctl enable greetd.service NetworkManager.service bluetooth.service \
    systemd-resolved.service systemd-timesyncd.service systemd-oomd.service \
    power-profiles-daemon.service fstrim.timer snapper-cleanup.timer limine-snapper-sync.service \
    avahi-daemon.service cups.socket btrfs-scrub@-.timer
  # A cellular modem's ModemManager, which comes with Nova: Arch enables
  # nothing a package brings, and mobile data cannot work without it.
  in_target /usr/lib/nova/bin/nova-modemmanager || warn "Could not turn on ModemManager; mobile data needs: sudo systemctl enable --now ModemManager.service"
}

finish() {
  # arch-chroot binds the live system's resolv.conf over the target's while it
  # runs, so the link to systemd-resolved is made from outside.
  ln -sf ../run/systemd/resolve/stub-resolv.conf "$TARGET/etc/resolv.conf"
  [[ ! -e $TARGET/swap/swapfile ]] || logged swapoff "$TARGET/swap/swapfile"
  sync
  # The new system keeps the log, with the table of the steps' times so far:
  # all but this last one, which only unmounts once the log is written.
  step_table >>"$LOG"
  install -Dm600 "$LOG" "$TARGET/var/log/nova-install.log"
  sync
  logged umount -R "$TARGET"
}
