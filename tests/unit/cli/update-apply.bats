#!/usr/bin/env bats

# nova-update-apply, the root half of nova update, under a scratch root
# (NOVA_ROOT): the boot entries it checks after an update, what a failed
# pacman leaves behind, and the Raspberry Pi's way of doing both.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_ROOT=$SCRATCH/root NOVA_ARCH=x86_64
  kver=7.2.11-arch1-1-nova
  put "$NOVA_ROOT/usr/lib/modules/$kver/pkgbase" linux-nova
  put "$NOVA_ROOT/usr/lib/modules/$kver/vmlinuz"
  put "$NOVA_ROOT/boot/limine.conf" '/+Nova
  //linux-nova
    protocol: efi
    path: boot():/EFI/Linux/nova_linux-nova.efi
  //linux-nova (fallback)
    protocol: efi
    path: boot():/EFI/Linux/nova_linux-nova-fallback.efi
'
  uki "nova_linux-nova.efi" "$kver"
  uki "nova_linux-nova-fallback.efi" "$kver"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/cli/bin/nova-update-apply"
}

teardown() { teardown_scratch; }

# The script has a write_file of its own, so the files here come from put.
put() { # path [content]
  mkdir -p -- "$(dirname -- "$1")"
  printf '%s' "${2:-}" >"$1"
}

uki() { # name kernel-version: an image whose setup header names that kernel
  mkdir -p "$NOVA_ROOT/boot/EFI/Linux"
  printf 'MZ\0\0%s (linux@archlinux) #1 SMP PREEMPT_DYNAMIC\0' "$2" >"$NOVA_ROOT/boot/EFI/Linux/$1"
}

@test "boot entries: every kernel has an entry and current images" {
  run verify_boot_entries
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "boot entries: an image the kernel hook did not rebuild is caught" {
  uki "nova_linux-nova-fallback.efi" 7.2.10-arch1-1-nova
  run verify_boot_entries
  [ "$status" -eq 1 ]
  [[ $output == *"EFI/Linux/nova_linux-nova-fallback.efi was not rebuilt for the installed linux-nova ($kver)"* ]]
}

@test "boot entries: a missing image and a kernel without an entry are caught" {
  rm "$NOVA_ROOT/boot/EFI/Linux/nova_linux-nova.efi"
  put "$NOVA_ROOT/usr/lib/modules/6.18.57-2-lts/pkgbase" linux-lts
  put "$NOVA_ROOT/usr/lib/modules/6.18.57-2-lts/vmlinuz"
  run verify_boot_entries
  [ "$status" -eq 1 ]
  [[ $output == *"loads /EFI/Linux/nova_linux-nova.efi but"* ]]
  [[ $output == *"no boot entry for the installed kernel linux-lts"* ]]
}

@test "boot entries: linux is not mistaken for linux-nova or linux-lts" {
  put "$NOVA_ROOT/usr/lib/modules/7.2.11-arch1-1/pkgbase" linux
  put "$NOVA_ROOT/usr/lib/modules/7.2.11-arch1-1/vmlinuz"
  run verify_boot_entries
  [ "$status" -eq 1 ]
  [[ $output == *"no boot entry for the installed kernel linux"* ]]
}

@test "a failed pacman puts back the mirror files and the databases that went with them" {
  put "$MIRRORLIST" 'old mirror'
  put "$REPOFILE" 'old repo'
  put "$SYNC_DIR/core.db" 'old core'
  backup_config
  put "$MIRRORLIST" 'new mirror'
  put "$SYNC_DIR/core.db" 'new core'
  put "$SYNC_DIR/extra.db" 'new extra'
  run restore_config
  [ "$(cat "$MIRRORLIST")" = 'old mirror' ]
  [ "$(cat "$REPOFILE")" = 'old repo' ]
  [ "$(cat "$SYNC_DIR/core.db")" = 'old core' ]
  [ ! -e "$SYNC_DIR/extra.db" ]
  [ ! -e "$SYNC_DIR.nova-prev" ]
}

@test "an update that never finished keeps what was there before it to go back to" {
  put "$MIRRORLIST" 'old mirror'
  put "$REPOFILE" 'old repo'
  put "$SYNC_DIR/core.db" 'old core'
  backup_config
  # The power goes after the new files are written.
  put "$MIRRORLIST" 'half mirror'
  put "$SYNC_DIR/core.db" 'half core'
  run backup_config
  [[ $output == *"did not finish"* ]]
  put "$MIRRORLIST" 'new mirror'
  restore_config 2>/dev/null
  [ "$(cat "$MIRRORLIST")" = 'old mirror' ]
  [ "$(cat "$SYNC_DIR/core.db")" = 'old core' ]
  [ ! -e "$SYNC_DIR.nova-prev" ] && [ ! -e "$SYNC_DIR.nova-old" ]
}

@test "a successful update drops the copies" {
  put "$MIRRORLIST" 'old mirror'
  put "$SYNC_DIR/core.db" 'old core'
  backup_config
  drop_backup
  [ ! -e "$MIRRORLIST.nova-prev" ]
  [ ! -e "$SYNC_DIR.nova-prev" ]
  [ "$(cat "$SYNC_DIR/core.db")" = 'old core' ]
}

# The script as a Raspberry Pi runs it.
on_a_pi() {
  NOVA_ARCH=aarch64
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/cli/bin/nova-update-apply"
  tag=v1.1.0 nova_repo=https://example.org/repo alarm_date=2026/10/20 alarm_pool=https://example.org/alarm/aarch64
  mkdir -p "$NOVA_ROOT/etc/pacman.d"
}

@test "a Pi is pointed at its release's Arch Linux ARM packages and aarch64 folder" {
  on_a_pi
  write_config
  [ "$(cat "$ALARMFILE")" = "# Managed by nova update; the next update rewrites this file.
# nova-release: v1.1.0
# alarm-date: 2026/10/20
CacheServer = https://example.org/alarm/aarch64
Server = https://example.org/repo/aarch64" ]
  grep -qx 'Server = https://example.org/repo/aarch64' "$REPOFILE"
  [ ! -e "$MIRRORLIST" ]
}

@test "a failed pacman on a Pi puts back its own files" {
  on_a_pi
  put "$ALARMFILE" 'old alarm'
  put "$REPOFILE" 'old repo'
  put "$SYNC_DIR/nova-alarm.db" 'old set'
  backup_config
  write_config
  put "$SYNC_DIR/nova-alarm.db" 'new set'
  run restore_config
  [ "$(cat "$ALARMFILE")" = 'old alarm' ]
  [ "$(cat "$REPOFILE")" = 'old repo' ]
  [ "$(cat "$SYNC_DIR/nova-alarm.db")" = 'old set' ]
  drop_backup
  [ ! -e "$ALARMFILE.nova-prev" ] && [ ! -e "$REPOFILE.nova-prev" ]
}

# A whole update on a Pi, with the helpers next to the script as they are
# installed, and pacman, snapper and the boot check stubbed.
pi_update() { # boot-check status
  mkdir -p "$SCRATCH/lib" "$SCRATCH/bin" "$NOVA_ROOT/etc/pacman.d"
  cp "$REPO_ROOT/src/cli/bin/nova-update-apply" "$SCRATCH/lib/"
  printf '#!/bin/bash\nexit 1\n' >"$SCRATCH/lib/nova-hw-detect"
  printf '#!/bin/bash\necho "nova-boot-check $*" >>"$SCRATCH/calls"\nexit %s\n' "$1" >"$SCRATCH/lib/nova-boot-check"
  printf '#!/bin/bash\necho "${0##*/} $*" >>"$SCRATCH/calls"\n' >"$SCRATCH/bin/pacman"
  cp "$SCRATCH/bin/pacman" "$SCRATCH/bin/snapper"
  chmod +x "$SCRATCH"/lib/* "$SCRATCH"/bin/*
  PATH="$SCRATCH/bin:$PATH" NOVA_ARCH=aarch64 "$SCRATCH/lib/nova-update-apply" --tag v1.1.0 --version 1.1.0 \
    --arch-date 2026/10/19 --nova-repo https://example.org/repo \
    --alarm-date 2026/10/20 --alarm-pool https://example.org/alarm/aarch64 --noconfirm
}

@test "an update on a Pi: its keyring, no snapshots, and the boot partition checked" {
  run pi_update 0
  [ "$status" -eq 0 ]
  [ "$(cat "$SCRATCH/calls")" = "pacman -Syy --needed --noconfirm archlinuxarm-keyring nova-keyring
pacman -Su --noconfirm
nova-boot-check status" ]
  [[ $output == *"Arch Linux ARM packages of 2026/10/20 and v1.1.0"* ]]
  [[ $output == *"Nova is now on v1.1.0."* ]]
  [[ $output != *"without snapshots"* ]]
}

@test "an update on a Pi whose boot partition does not hold the new kernel says so" {
  run pi_update 1
  [ "$status" -eq 3 ]
  [[ $output == *"Do not restart yet"* ]]
}

@test "a Pi's update needs the release's Arch Linux ARM set" {
  on_a_pi
  run main --tag v1.1.0 --version 1.1.0 --arch-date 2026/10/19 --nova-repo https://example.org/repo
  [ "$status" -ne 0 ]
  [[ $output == *"bad --alarm-date"* ]]
}
