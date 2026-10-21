#!/usr/bin/env bats

# nova-update-apply, the root half of nova update, under a scratch root
# (NOVA_ROOT): the boot entries it checks after an update, and what a failed
# pacman leaves behind.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_ROOT=$SCRATCH/root
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

@test "a successful update drops the copies" {
  put "$MIRRORLIST" 'old mirror'
  put "$SYNC_DIR/core.db" 'old core'
  backup_config
  drop_backup
  [ ! -e "$MIRRORLIST.nova-prev" ]
  [ ! -e "$SYNC_DIR.nova-prev" ]
  [ "$(cat "$SYNC_DIR/core.db")" = 'old core' ]
}
