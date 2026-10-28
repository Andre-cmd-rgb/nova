#!/usr/bin/env bats

load ../test_helper

setup() {
  setup_scratch
  export NOVA_INSTALLER_SHARE="$SCRATCH/share"
  export NOVA_CPUINFO="$SCRATCH/cpuinfo"
  export NOVA_MEMINFO="$SCRATCH/meminfo"
  export NOVA_PCI_DEVICES_PATH="$SCRATCH/pci"
  export NOVA_OFFLINE_REPO="$SCRATCH/repo"
  export NOVA_RELEASE_FILE="$SCRATCH/release.toml"
  export NOVA_ZONEINFO="$SCRATCH/zoneinfo"
  mkdir -p "$NOVA_INSTALLER_SHARE/hardware" "$NOVA_PCI_DEVICES_PATH"
  cp "$REPO_ROOT/installer/packages" "$NOVA_INSTALLER_SHARE/packages"
  cp -r "$REPO_ROOT/data/hardware/thinkpad-p1-gen4i" "$NOVA_INSTALLER_SHARE/hardware/"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/installer/nova-install"
}

teardown() { teardown_scratch; }

GiB=$((1024 * 1024 * 1024))
V3_FLAGS="flags : fpu sse avx avx2 bmi1 bmi2 f16c fma abm movbe xsave"

pci() { # name class vendor device
  mkdir -p "$NOVA_PCI_DEVICES_PATH/$1"
  echo "$2" >"$NOVA_PCI_DEVICES_PATH/$1/class"
  echo "$3" >"$NOVA_PCI_DEVICES_PATH/$1/vendor"
  echo "$4" >"$NOVA_PCI_DEVICES_PATH/$1/device"
}

# lsblk -J for the disks on stdin, one per line: name size rm ro tran [model]
disks_json() {
  local name size rm ro tran model sep=
  printf '{"blockdevices":['
  while read -r name size rm ro tran model; do
    [[ $tran == null ]] || tran="\"$tran\""
    printf '%s{"name":"%s","path":"/dev/%s","size":%s,"model":"%s","serial":null,"type":"disk","rm":%s,"ro":%s,"tran":%s}' \
      "$sep" "$name" "$name" "$size" "$model" "$rm" "$ro" "$tran"
    sep=,
  done
  printf ']}\n'
}

@test "partition_path: NVMe and MMC disks get a p before the number" {
  [ "$(partition_path /dev/nvme0n1 2)" = /dev/nvme0n1p2 ]
  [ "$(partition_path /dev/mmcblk0 1)" = /dev/mmcblk0p1 ]
  [ "$(partition_path /dev/sda 2)" = /dev/sda2 ]
  [ "$(partition_path /dev/vda 1)" = /dev/vda1 ]
}

@test "human_size: the units a disk label uses" {
  [ "$(human_size 512110190592)" = "512.1 GB" ]
  [ "$(human_size 1000204886016)" = "1.0 TB" ]
  [ "$(human_size 2048)" = "2 KB" ]
}

@test "candidate_disks: offers an internal NVMe disk" {
  boot_disk() { echo /dev/sdb; }
  lsblk_disks() { disks_json <<<"nvme0n1 $((1000 * GiB)) false false nvme WD_Black"; }
  run candidate_disks
  [ "$status" -eq 0 ]
  [ "$output" = "/dev/nvme0n1"$'\t'"$((1000 * GiB))"$'\t'"WD_Black"$'\t-\t'"nvme" ]
}

@test "candidate_disks: never the stick it booted from, USB, removable, read-only, virtual or small disks" {
  boot_disk() { echo /dev/sdb; }
  lsblk_disks() {
    disks_json <<END
sdb $((64 * GiB)) false false sata stick
sdc $((500 * GiB)) false false usb external
sdd $((500 * GiB)) true false sata removable
sde $((500 * GiB)) false true sata readonly
sdf $((32 * GiB)) false false sata small
zram0 $((500 * GiB)) false false null
nvme0n1 $((512 * GiB)) false false nvme internal
END
  }
  run candidate_disks
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ $output == /dev/nvme0n1$'\t'* ]]
}

@test "candidate_disks: NOVA_ALLOW_USB=1 lets a USB disk through" {
  boot_disk() { :; }
  lsblk_disks() { disks_json <<<"sdc $((500 * GiB)) false false usb external"; }
  run candidate_disks
  [ -z "$output" ]
  NOVA_ALLOW_USB=1 run candidate_disks
  [[ $output == /dev/sdc$'\t'* ]]
}

@test "candidate_disks: unknown fields read as - so the columns never shift" {
  boot_disk() { :; }
  lsblk_disks() { disks_json <<<"vda $((100 * GiB)) false false null"; }
  run candidate_disks
  IFS=$'\t' read -r path size model serial tran <<<"$output"
  [ "$path" = /dev/vda ]
  [ "$size" = $((100 * GiB)) ]
  [ "$model" = - ]
  [ "$serial" = - ]
  [ "$tran" = - ]
}

@test "candidate_disks: exactly 64 GiB is enough" {
  boot_disk() { :; }
  lsblk_disks() { disks_json <<<"vda $((64 * GiB)) false false null"; }
  run candidate_disks
  [[ $output == /dev/vda$'\t'* ]]
}

@test "disk_in_use: a mounted partition or an LVM on it counts, an idle disk does not" {
  lsblk() {
    case "$*" in
      *MOUNTPOINTS*/dev/busy) printf '\n/run/media/x\n' ;;
      *MOUNTPOINTS*) printf '\n\n' ;;
      *TYPE*/dev/lvm) printf 'disk\npart\nlvm\n' ;;
      *TYPE*) printf 'disk\npart\n' ;;
    esac
  }
  disk_in_use /dev/busy
  disk_in_use /dev/lvm
  fails disk_in_use /dev/idle
}

@test "swap_gib: the size of RAM, rounded up to a GiB" {
  echo "MemTotal:       32562364 kB" >"$NOVA_MEMINFO"
  [ "$(swap_gib $((1000 * GiB)))" -eq 32 ]
}

@test "swap_gib: never more than an eighth of the disk" {
  echo "MemTotal:       67108864 kB" >"$NOVA_MEMINFO"
  [ "$(swap_gib $((128 * GiB)))" -eq 16 ]
}

@test "main_kernel: linux-nova on x86-64-v3, Arch's linux on anything older" {
  echo "$V3_FLAGS" >"$NOVA_CPUINFO"
  [ "$(main_kernel)" = linux-nova ]
  echo "flags : fpu sse avx" >"$NOVA_CPUINFO"
  [ "$(main_kernel)" = linux ]
  rm "$NOVA_CPUINFO"
  [ "$(main_kernel)" = linux ]
}

@test "hardware_packages: microcode and drivers from the CPU and the display controllers" {
  printf 'vendor_id\t: GenuineIntel\n' >"$NOVA_CPUINFO"
  pci 0000:00:02.0 0x030000 0x8086 0x9a60
  pci 0000:00:1f.3 0x040380 0x8086 0xa0c8
  pci 0000:01:00.0 0x030200 0x10de 0x25b8
  run hardware_packages linux-nova
  [ "$output" = "$(printf '%s\n' intel-ucode intel-media-driver vulkan-intel nvidia-open-nova nvidia-open-lts nvidia-utils nvidia-prime)" ]
  run hardware_packages linux
  [ "$output" = "$(printf '%s\n' intel-ucode intel-media-driver vulkan-intel nvidia-open nvidia-open-lts nvidia-utils nvidia-prime)" ]
}

@test "hardware_packages: an NVIDIA card on its own decodes video too" {
  printf 'vendor_id\t: AuthenticAMD\n' >"$NOVA_CPUINFO"
  pci 0000:01:00.0 0x030000 0x10de 0x2786
  run hardware_packages linux
  [ "$output" = "$(printf '%s\n' amd-ucode nvidia-open nvidia-open-lts nvidia-utils libva-nvidia-driver)" ]
}

@test "hardware_packages: a cellular modem gets ModemManager" {
  printf 'vendor_id\t: GenuineIntel\n' >"$NOVA_CPUINFO"
  pci 0000:00:02.0 0x030000 0x8086 0x9a60
  pci 0000:08:00.0 0x0d4000 0x105b 0xe0ab
  run hardware_packages linux-nova
  [ "$output" = "$(printf '%s\n' intel-ucode intel-media-driver vulkan-intel modemmanager)" ]
}

@test "hardware_packages: no open-module NVIDIA driver before Turing" {
  printf 'vendor_id\t: AuthenticAMD\n' >"$NOVA_CPUINFO"
  pci 0000:01:00.0 0x030000 0x10de 0x1c03
  run hardware_packages linux-nova
  [ "$output" = amd-ucode ]
}

@test "profile_packages: nvidia-open-nova becomes nvidia-open on Arch's kernel" {
  run profile_packages thinkpad-p1-gen4i linux
  grep -qx nvidia-open <<<"$output"
  fails grep -q nvidia-open-nova <<<"$output"
  fails grep -q '#' <<<"$output"
  run profile_packages thinkpad-p1-gen4i linux-nova
  grep -qx nvidia-open-nova <<<"$output"
  run profile_packages "" linux-nova
  [ -z "$output" ]
}

@test "package_set: the base list, both kernels and the hardware, each once" {
  { echo "$V3_FLAGS"; printf 'vendor_id\t: GenuineIntel\n'; } >"$NOVA_CPUINFO"
  pci 0000:00:02.0 0x030000 0x8086 0x9a60
  run package_set linux-nova thinkpad-p1-gen4i
  [ "$status" -eq 0 ]
  for p in base nova linux-nova linux-lts intel-ucode fprintd nvidia-open-nova; do
    grep -qx "$p" <<<"$output"
  done
  [ -z "$(sort <<<"$output" | uniq -d)" ]
  fails grep -q -e '#' -e '^$' <<<"$output"
}

@test "release_value: reads quoted values from release.toml" {
  printf 'version = "1.0.0-beta.1"\narch_date = "2026/10/19"\nnova_repo = "https://example.org/repo"\n' >"$NOVA_RELEASE_FILE"
  [ "$(release_value version)" = 1.0.0-beta.1 ]
  [ "$(release_value arch_date)" = 2026/10/19 ]
  [ -z "$(release_value missing)" ]
}

@test "pacstrap_conf: the stick's repository when it has one" {
  mkdir -p "$NOVA_OFFLINE_REPO"
  : >"$NOVA_OFFLINE_REPO/nova-offline.db"
  run pacstrap_conf 2026/10/19 https://example.org/repo
  [[ $output == *"[nova-offline]"$'\n'"Server = file://$NOVA_OFFLINE_REPO"* ]]
  [[ $output != *archive.archlinux.org* ]]
}

@test "pacstrap_conf: otherwise the pinned snapshot and the release repository" {
  run pacstrap_conf 2026/10/19 https://example.org/repo
  [[ $output == *"[nova]"$'\n'"SigLevel = Required"$'\n'"Server = https://example.org/repo"* ]]
  [[ $output == *'[core]'$'\n''Server = https://archive.archlinux.org/repos/2026/10/19/$repo/os/$arch'* ]]
  [[ $output == *"[multilib]"* ]]
  [[ $output != *nova-offline* ]]
}

@test "packages_available: both repositories are asked for the whole set before the erase" {
  LOG=$SCRATCH/log
  pacman() { # --config conf --dbpath db --logfile /dev/null operation...
    echo "pacman ${*:7}" >>"$SCRATCH/calls"
    grep -c '^SigLevel = Never$' "$2" >>"$SCRATCH/calls"
    echo "${2%/*}" >"$SCRATCH/dir"
    [[ $* != *" -Sp "* || $* != *missing-package* ]]
  }
  run packages_available linux "" 2026/10/19 https://example.org/repo fprintd
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$SCRATCH/calls")" = "pacman -Sy" ]
  [ "$(sed -n 2p "$SCRATCH/calls")" = 2 ]
  [[ $(sed -n 3p "$SCRATCH/calls") == "pacman -Sp --print-format %n base "*" fprintd" ]]
  run packages_available linux "" 2026/10/19 https://example.org/repo missing-package
  [ "$status" -ne 0 ]
  [ ! -e "$(cat "$SCRATCH/dir")" ]
}

@test "packages_available: the stick's repository needs no asking" {
  mkdir -p "$NOVA_OFFLINE_REPO"
  : >"$NOVA_OFFLINE_REPO/nova-offline.db"
  pacman() { echo called >>"$SCRATCH/calls"; }
  run packages_available linux "" 2026/10/19 https://example.org/repo
  [ "$status" -eq 0 ]
  [ ! -e "$SCRATCH/calls" ]
}

@test "install_cmdline: root and resume on the same partition, in limine-snapper-sync's form" {
  run install_cmdline PARTUUID=abcd-1234 1941442
  [ "$output" = "root=PARTUUID=abcd-1234 rootflags=subvol=@ rw rootfstype=btrfs zswap.enabled=0 resume=PARTUUID=abcd-1234 resume_offset=1941442" ]
}

@test "install_cmdline: encrypted, the initramfs opens the container, and root and resume are in it" {
  run install_cmdline /dev/mapper/nova-root 1941442 1111-2222
  [ "$output" = "rd.luks.name=1111-2222=nova-root root=/dev/mapper/nova-root rootflags=subvol=@ rw rootfstype=btrfs zswap.enabled=0 resume=/dev/mapper/nova-root resume_offset=1941442" ]
}

@test "encrypt_mkinitcpio_conf: sd-vconsole after keyboard and sd-encrypt after block, in Nova's own line" {
  encrypt_mkinitcpio_conf >"$SCRATCH/20.conf"
  run bash -c '. "$1"; . "$2"; echo "${HOOKS[*]}"' _ "$REPO_ROOT/data/boot/mkinitcpio/10-nova.conf" "$SCRATCH/20.conf"
  [ "$output" = "base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems sd-btrfs-overlayfs" ]
}

@test "prepare_boot_config: the command line, initramfs and layout of a plain and an encrypted root" {
  export NOVA_TARGET=$SCRATCH/mnt
  TARGET=$NOVA_TARGET
  mkdir -p "$TARGET/swap"
  printf 'cfg\n' >"$NOVA_INSTALLER_SHARE/limine.conf"
  btrfs() { echo 1941442; }
  blkid() { echo abcd-1234; }
  cryptsetup() { [[ $* == "luksUUID /dev/vda2" ]] && echo 1111-2222; }
  ENCRYPT=no
  prepare_boot_config /dev/vda linux-nova
  grep -q 'root=PARTUUID=abcd-1234 ' "$TARGET/etc/limine-entry-tool.d/90-nova-install.conf"
  [ ! -e "$TARGET/etc/mkinitcpio.conf.d/20-nova-encrypt.conf" ]
  [ ! -e "$TARGET/etc/vconsole.conf" ]
  ENCRYPT=yes KEYMAP=it
  prepare_boot_config /dev/vda linux-nova
  grep -q '" rd.luks.name=1111-2222=nova-root root=/dev/mapper/nova-root ' "$TARGET/etc/limine-entry-tool.d/90-nova-install.conf"
  grep -q 'sd-encrypt' "$TARGET/etc/mkinitcpio.conf.d/20-nova-encrypt.conf"
  grep -qx 'KEYMAP=it' "$TARGET/etc/vconsole.conf"
}

@test "limine_install_conf: adds to the command line, and swaps the kernel only when needed" {
  run limine_install_conf "root=X" linux-nova
  [[ $output == *'KERNEL_CMDLINE[default]+=" root=X"'* ]]
  [[ $output != *MKINITCPIO_FALLBACK* ]]
  run limine_install_conf "root=X" linux
  [[ $output == *"MKINITCPIO_FALLBACK=linux"* ]]
  [[ $output == *'BOOT_ORDER="linux, *fallback, linux-lts, *, Snapshots"'* ]]
}

@test "limine_install_conf: valid shell that appends to the line already set" {
  limine_install_conf "root=X rw" linux >"$SCRATCH/90.conf"
  run bash -c 'declare -A KERNEL_CMDLINE=([default]="quiet"); . "$1"; echo "${KERNEL_CMDLINE[default]}|$MKINITCPIO_FALLBACK"' _ "$SCRATCH/90.conf"
  [ "$output" = "quiet root=X rw|linux" ]
}

@test "strip_subvolid: genfstab's subvolid goes, subvol stays" {
  run strip_subvolid <<<"UUID=x / btrfs rw,noatime,compress=zstd:1,subvolid=256,subvol=/@ 0 0"
  [ "$output" = "UUID=x / btrfs rw,noatime,compress=zstd:1,subvol=/@ 0 0" ]
  run strip_subvolid <<<"UUID=x /home btrfs subvolid=257,subvol=/@home 0 0"
  [ "$output" = "UUID=x /home btrfs subvol=/@home 0 0" ]
}

@test "valid_username: Linux account names only, never root or the greeter" {
  valid_username andre
  valid_username _svc-1
  fails valid_username Andre
  fails valid_username 1andre
  fails valid_username root
  fails valid_username greeter
  fails valid_username "an dre"
  fails valid_username ""
  # System accounts exist in the new system too.
  fails valid_username bin
  fails valid_username nobody
}

@test "valid_fullname: anything useradd takes as the comment" {
  valid_fullname "Andre Rossi"
  valid_fullname "José Ñandú, jr."
  valid_fullname ""
  fails valid_fullname "Andre: P1"
  fails valid_fullname $'Andre\nRossi'
}

@test "release_target: a failed try's swap file and mounts are let go, so the disk can be picked" {
  export NOVA_TARGET="$SCRATCH/mnt" CALLS="$SCRATCH/calls"
  TARGET=$NOVA_TARGET
  swapon() { echo /dev/zram0; echo "$TARGET/swap/swapfile"; }
  swapoff() { echo "swapoff $*" >>"$CALLS"; }
  mountpoint() { return 0; }
  umount() { echo "umount $*" >>"$CALLS"; }
  release_target >/dev/null
  [ "$(paste -sd';' "$CALLS")" = "swapoff -- $TARGET/swap/swapfile;umount -R -- $TARGET" ]
}

@test "release_target: nothing left behind, nothing done" {
  export CALLS="$SCRATCH/calls"
  swapon() { echo /dev/zram0; }
  swapoff() { echo "swapoff $*" >>"$CALLS"; }
  mountpoint() { return 1; }
  umount() { echo "umount $*" >>"$CALLS"; }
  release_target
  [ ! -e "$CALLS" ]
}

@test "valid_hostname: letters, digits and inner hyphens" {
  valid_hostname nova
  valid_hostname thinkpad-p1
  fails valid_hostname -nova
  fails valid_hostname nova-
  fails valid_hostname "no va"
  fails valid_hostname ""
}

@test "valid_timezone: must exist, and cannot climb out of zoneinfo" {
  mkdir -p "$NOVA_ZONEINFO/Europe"
  : >"$NOVA_ZONEINFO/Europe/Rome"
  : >"$SCRATCH/passwd"
  valid_timezone Europe/Rome
  fails valid_timezone Europe/Atlantis
  fails valid_timezone ../passwd
  fails valid_timezone ""
}

@test "xkb_layout: console keymaps map to XKB layouts and variants" {
  KBD_MODEL_MAP="$SCRATCH/kbd-model-map"
  printf '%s\n' '# consolelayout xlayout xmodel xvariant xoptions' \
    'sv-latin1 se pc105 - terminate:ctrl_alt_bksp' \
    'sg ch pc105 de_nodeadkeys terminate:ctrl_alt_bksp' \
    'dvorak us pc105 dvorak terminate:ctrl_alt_bksp' \
    'dvorak us pc105 dvorak-alt-intl terminate:ctrl_alt_bksp' \
    'uk gb pc105 - terminate:ctrl_alt_bksp' >"$KBD_MODEL_MAP"
  [ "$(xkb_layout sv-latin1)" = "se$(printf '\t')" ]
  [ "$(xkb_layout sg)" = "ch$(printf '\t')de_nodeadkeys" ]
  [ "$(xkb_layout dvorak)" = "us$(printf '\t')dvorak" ]
  [ "$(xkb_layout uk)" = "gb$(printf '\t')" ]
  # Not in the table: the keymap's own name, less its suffix.
  [ "$(xkb_layout es)" = "es$(printf '\t')" ]
  [ "$(xkb_layout fr-latin9)" = "fr$(printf '\t')" ]
  rm "$KBD_MODEL_MAP"
  [ "$(xkb_layout de-latin1)" = "de$(printf '\t')" ]
}

@test "the installer prints its help, and refuses an unknown argument" {
  run "$REPO_ROOT/installer/nova-install" --help
  [ "$status" -eq 0 ]
  [[ $output == "nova-install: install Nova"* ]]
  run "$REPO_ROOT/installer/nova-install" --bogus
  [ "$status" -eq 1 ]
  [[ $output == *"unknown argument: --bogus"* ]]
}

answers() { # key=value...
  printf '%s\n' "$@" >"$SCRATCH/answers"
  ANSWERS=$SCRATCH/answers
}

# A live system with one disk, a few layouts and zones, and no carried things.
questions_setup() {
  export NOVA_CARRY="$SCRATCH/carry"
  CARRY=$NOVA_CARRY
  mkdir -p "$NOVA_ZONEINFO/Europe"
  touch "$NOVA_ZONEINFO/UTC" "$NOVA_ZONEINFO/Europe/Rome"
  echo "MemTotal: 16000000 kB" >"$NOVA_MEMINFO"
  valid_keymap() { [[ $1 =~ ^(us|es|de|it)$ ]]; }
  boot_disk() { :; }
  lsblk_disks() { disks_json <<<"vda $((80 * GiB)) false false virtio Disk"; }
  disk_contents() { echo 'vda1  80G  ext4  "old"'; }
  disk_in_use() { return 1; }
  timezones() { printf '%s\n' UTC Europe/Rome; }
  main_kernel() { echo linux-nova; }
  machine_hash() { :; }
}

@test "answers: each question answered from the file, its default where it says nothing" {
  questions_setup
  answers keymap=it disk=/dev/vda fullname="Ada Lovelace" password=s3cret-pass timezone=Europe/Rome
  answers_from_file
  [ "$KEYMAP" = it ]
  [ "${DISK_LINE%%$'\t'*}" = /dev/vda ]
  [ "$FULLNAME" = "Ada Lovelace" ]
  [ "$ACCOUNT" = ada ]
  [ "$PASSWORD" = s3cret-pass ]
  [ "$COMPUTER" = nova ]
  [ "$TIMEZONE" = Europe/Rome ]
  [ "$(answer_or apps yes)" = yes ]
  answers apps=no
  [ "$(answer_or apps yes)" = no ]
}

@test "answers: no encryption unless the file asks, and then a disk passphrase of 8 or more" {
  questions_setup
  answers disk=/dev/vda user=ada password=s3cret-pass
  answers_from_file
  [ "$ENCRYPT" = no ]
  [ -z "$DISK_PASSPHRASE" ]
  answers disk=/dev/vda user=ada password=s3cret-pass encrypt=yes disk_passphrase=disk-secret
  answers_from_file
  [ "$ENCRYPT" = yes ]
  [ "$DISK_PASSPHRASE" = disk-secret ]
  answers disk=/dev/vda user=ada password=s3cret-pass encrypt=yes disk_passphrase=short
  run answers_from_file
  [ "$status" -ne 0 ]
  [[ $output == *"encrypt=yes needs a disk_passphrase of at least 8 characters"* ]]
  answers disk=/dev/vda user=ada password=s3cret-pass encrypt=maybe
  run answers_from_file
  [[ $output == *"encrypt=yes or encrypt=no"* ]]
}

@test "answers: a wrong answer ends the install instead of asking again" {
  questions_setup
  answers keymap=xx disk=/dev/vda password=s3cret-pass
  run answers_from_file
  [ "$status" -ne 0 ]
  [[ $output == *"the answers file: no keyboard layout called 'xx'."* ]]
  answers disk=/dev/vda user=ada
  run answers_from_file
  [ "$status" -ne 0 ]
  [[ $output == *"the answers file has no password"* ]]
  answers disk=/dev/vda user=ada password=s3cret-pass timezone=Mars/Olympus
  run answers_from_file
  [[ $output == *"no time zone called 'Mars/Olympus'"* ]]
  answers disk=/dev/vda user=ada password=secret
  run answers_from_file
  [ "$status" -ne 0 ]
  [[ $output == *"a password of at least 8 characters"* ]]
}

@test "answers: the disk has to be one the installer would offer, and free" {
  questions_setup
  boot_disk() { echo /dev/sda; }
  lsblk_disks() { disks_json <<<"vda $((80 * GiB)) false false virtio"$'\n'"sda $((8 * GiB)) true false usb Stick"; }
  disk_in_use() { [[ $1 == /dev/vdb ]]; }
  answers disk=/dev/vda user=ada password=s3cret-pass
  answers_from_file
  [ "${DISK_LINE%%$'\t'*}" = /dev/vda ]
  answers disk=/dev/sda user=ada password=s3cret-pass
  run answers_from_file
  [ "$status" -ne 0 ]
  [[ $output == *"names no disk this can install on (disk=/dev/sda)"* ]]
}

@test "screens: a password shorter than 8 characters is asked again" {
  questions_setup
  NOVA_KEYMAP=es
  stub_gum 0 no "Ada Lovelace" "" short short s3cret-pass s3cret-pass "" Europe/Rome erase
  questions_on_screen no 2>"$SCRATCH/screens"
  [ "$(gum_replies_left)" = 0 ]
  [ "$PASSWORD" = s3cret-pass ]
  grep -q 'At least 8 characters.' "$SCRATCH/screens"
}

@test "screens: one question a screen, then erase typed back" {
  questions_setup
  NOVA_KEYMAP=es
  stub_gum 0 no "Ada Lovelace" "" s3cret-pass s3cret-pass "" Europe/Rome nope erase
  questions_on_screen no 2>"$SCRATCH/screens"
  [ "$(gum_replies_left)" = 0 ]
  [ "$KEYMAP" = es ]
  [ "${DISK_LINE%%$'\t'*}" = /dev/vda ]
  [ "$ACCOUNT" = ada ]
  [ "$PASSWORD" = s3cret-pass ]
  [ "$COMPUTER" = nova ]
  [ "$TIMEZONE" = Europe/Rome ]
  grep -q -- 'vda  85.9 GB  Disk  ·  vda1  80G  ext4  "old"' "$GUM_LOG"
  grep -q 'Erased       vda  85.9 GB  Disk' "$SCRATCH/screens"
  grep -q 'Account      ada (Ada Lovelace) on nova' "$SCRATCH/screens"
  grep -q 'Encryption   off: anyone with the disk can read it' "$SCRATCH/screens"
  grep -q 'That is not erase.' "$SCRATCH/screens"
  [ "$ENCRYPT" = no ]
}

@test "screens: encryption, asked for, takes a passphrase typed twice; Esc there goes back to the disk" {
  questions_setup
  NOVA_KEYMAP=es
  stub_gum 0 yes short short disk-secret disk-secret "Ada Lovelace" "" s3cret-pass s3cret-pass "" Europe/Rome erase
  questions_on_screen no 2>"$SCRATCH/screens"
  [ "$(gum_replies_left)" = 0 ]
  [ "$ENCRYPT" = yes ]
  [ "$DISK_PASSPHRASE" = disk-secret ]
  [ "$PASSWORD" = s3cret-pass ]
  grep -q 'Encryption   on: the passphrase at every start' "$SCRATCH/screens"
  grep -q '^choose .*Encrypt the disk?' "$GUM_LOG"
  # Esc on the question: the disk again.
  stub_gum 0 '!1' 0 no '!130'
  run questions_on_screen no
  [ "$(grep -c '^choose .*Which disk' "$GUM_LOG")" = 2 ]
}

@test "screens: Esc goes back a step, and on the first one changes nothing" {
  questions_setup
  NOVA_KEYMAP=es
  # The disk, Esc on the name: the disk again, then Esc there.
  stub_gum 0 '!1' '!1'
  run questions_on_screen no
  [ "$status" -eq 1 ]
  [[ $output == *"nothing was changed."* ]]
  [ "$(grep -c '^choose .*Which disk' "$GUM_LOG")" = 2 ]
}

@test "screens: Ctrl+C stops the installer, with nothing changed" {
  questions_setup
  NOVA_KEYMAP=es
  stub_gum 0 no "Ada" '!130'
  run questions_on_screen no
  [ "$status" -eq 130 ]
  [[ $output == *"The installer stopped; nothing was changed."* ]]
}

@test "screens: no layout from nova-install-start asks for one first" {
  questions_setup
  NOVA_KEYMAP='' 
  loadkeys() { :; }
  stub_gum "German (de)" '!1' '!1'
  run questions_on_screen no
  [ "$(sed -n 2p "$GUM_LOG" | cut -d' ' -f1)" = choose ]
}

@test "the keyboard layout: by name, the default on top, or typed in" {
  questions_setup
  stub_gum "German (de)"
  [ "$(choose_keymap es 2>/dev/null)" = de ]
  stub_gum "Another layout..." it
  [ "$(choose_keymap es 2>/dev/null)" = it ]
  # A layout not in the list is offered on top all the same.
  stub_gum '!1'
  run choose_keymap us-intl
  [ "$status" -eq 1 ]
  stub_gum "Another layout..." xx "Spanish (es)"
  run choose_keymap es
  [ "${lines[-1]}" = es ]
  [[ $output == *"No keyboard layout called 'xx'."* ]]
}

@test "the keyboard layout: Ctrl+C stops, also when typing one in, and --keymap says so" {
  questions_setup
  stub_gum '!130'
  run choose_keymap es
  [ "$status" -eq 130 ]
  stub_gum "Another layout..." '!130'
  run choose_keymap es
  [ "$status" -eq 130 ]
  stub_gum '!130'
  run main --keymap es
  [ "$status" -eq 130 ]
  [[ $output == *"The installer stopped; nothing was changed."* ]]
  # Esc keeps the default.
  stub_gum '!1'
  run main --keymap es
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = es ]
}

@test "the time zone: the carried one on top, else UTC, and the rest after" {
  questions_setup
  timezones() { printf '%s\n' Africa/Abidjan Europe/Rome UTC; }
  stub_gum UTC
  [ "$(choose_timezone "" 2>/dev/null)" = UTC ]
  [ "$(paste -sd' ' "$GUM_LOG.filter")" = "UTC Africa/Abidjan Europe/Rome" ]
  stub_gum Europe/Rome
  choose_timezone Europe/Rome >/dev/null 2>&1
  [ "$(paste -sd' ' "$GUM_LOG.filter")" = "Europe/Rome Africa/Abidjan UTC" ]
}

@test "the account and computer name default to what was carried from this computer" {
  questions_setup
  mkdir -p "$CARRY/carry"
  echo '{"source": {"user": "ada", "name": "Ada L", "host": "engine", "machine": "m1", "timezone": "Europe/Rome"}, "items": []}' \
    >"$CARRY/carry/manifest.json"
  [ "$(carried_default user)" = ada ]
  [ "$(carried_default name)" = "Ada L" ]
  [ "$(carried_default timezone)" = Europe/Rome ]
  [ "$(carried_default host)" = "" ]
  machine_hash() { echo m1; }
  [ "$(carried_default host)" = engine ]
}

@test "answers: the after= script runs in the new system, next to the answers file" {
  export NOVA_TARGET="$SCRATCH/target" NOVA_INSTALL_LOG="$SCRATCH/log"
  TARGET=$NOVA_TARGET LOG=$NOVA_INSTALL_LOG
  mkdir -p "$TARGET/root"
  in_target() { echo "in_target $*" >>"$SCRATCH/calls"; }
  run_after
  [ ! -e "$SCRATCH/calls" ]
  answers after=probe
  printf '#!/bin/bash\n' >"$SCRATCH/probe"
  run_after
  [ "$(cat "$SCRATCH/calls")" = "in_target /root/nova-after" ]
  [ ! -e "$TARGET/root/nova-after" ]
  answers after=missing
  run run_after
  [ "$status" -ne 0 ]
}

@test "as_user: the new account's commands get an environment of their own, not the live root's" {
  in_target() { printf '%s\n' "$@" >"$SCRATCH/args"; }
  XDG_RUNTIME_DIR=/run/user/0 as_user nova nova-theme set white
  run cat "$SCRATCH/args"
  [ "${lines[0]}" = runuser ] && [ "${lines[2]}" = nova ] && [ "${lines[4]}" = env ] && [ "${lines[5]}" = -i ]
  [[ $output == *"HOME=/home/nova"* && $output == *"PATH=/usr/lib/nova/bin:/usr/bin"* ]]
  [[ $output != *XDG_RUNTIME_DIR* ]]
  [ "${lines[-3]}" = nova-theme ] && [ "${lines[-1]}" = white ]
}
