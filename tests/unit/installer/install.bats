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

# A bare `! cmd` never fails a bats test; this does.
fails() { if "$@"; then return 1; fi; }

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

@test "install_cmdline: root and resume on the same partition, in limine-snapper-sync's form" {
  run install_cmdline abcd-1234 1941442
  [ "$output" = "root=PARTUUID=abcd-1234 rootflags=subvol=@ rw rootfstype=btrfs zswap.enabled=0 resume=PARTUUID=abcd-1234 resume_offset=1941442" ]
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

@test "answers: each question answered from the file, its default where it says nothing" {
  answers keymap=it user=first user=nova password=secret
  [ "$(ask keymap Layout us)" = it ]
  [ "$(ask user Username x)" = nova ]
  [ "$(ask hostname "Computer name" nova)" = nova ]
  [ "$(ask_password)" = secret ]
  [ "$(answer_or apps yes)" = yes ]
  answers apps=no
  [ "$(answer_or apps yes)" = no ]
}

@test "answers: a wrong answer ends the install instead of asking again" {
  answers
  run retry "No keyboard layout called 'xx'."
  [ "$status" -ne 0 ]
  [[ $output == *"the answers file: No keyboard layout called 'xx'."* ]]
  run ask_password
  [ "$status" -ne 0 ]
}

@test "answers: the disk has to be one the installer would offer, and free" {
  boot_disk() { echo /dev/sda; }
  lsblk_disks() { disks_json <<<"vda $((80 * GiB)) false false virtio"$'\n'"sda $((8 * GiB)) true false usb Stick"; }
  disk_in_use() { [[ $1 == /dev/vdb ]]; }
  answers disk=/dev/vda
  run choose_disk
  [ "$status" -eq 0 ]
  [ "${output%%$'\t'*}" = /dev/vda ]
  answers disk=/dev/sda
  run choose_disk
  [ "$status" -ne 0 ]
  [[ $output == *"names no disk this can install on (disk=/dev/sda)"* ]]
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
