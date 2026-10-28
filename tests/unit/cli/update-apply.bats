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

# The check alone, as nova update --check-boot runs it, with the fallback's
# check next to the script as it is installed.
check_boot_alone() { # fallback check's status
  mkdir -p "$SCRATCH/lib"
  cp "$REPO_ROOT/src/cli/bin/nova-update-apply" "$SCRATCH/lib/"
  printf '#!/bin/bash\necho "nova-boot-check $*" >>"$SCRATCH/calls"\nexit %s\n' "$1" >"$SCRATCH/lib/nova-boot-check"
  chmod +x "$SCRATCH"/lib/*
  "$SCRATCH/lib/nova-update-apply" --check-boot
}

@test "--check-boot checks the entries and the fallback, and changes nothing" {
  run check_boot_alone 0
  [ "$status" -eq 0 ]
  [[ $output == *"Boot entries look right"* ]]
  [ "$(cat "$SCRATCH/calls")" = "nova-boot-check status" ]
  [ ! -e "$NOVA_ROOT/etc/pacman.d" ]
}

@test "--check-boot says when the entries do not check out, and how to look again" {
  rm "$NOVA_ROOT/boot/EFI/Linux/nova_linux-nova.efi"
  run check_boot_alone 0
  [ "$status" -eq 3 ]
  [[ $output == *"do NOT check out"* ]]
  [[ $output == *"sudo limine-update, then nova update --check-boot"* ]]
  run check_boot_alone 1
  [ "$status" -eq 3 ]
}

@test "a boot partition fstab names but nobody mounted is caught, with what to do" {
  findmnt() { return 0; }
  mountpoint() { return 1; }
  ROOT='' run esp_unmounted /boot
  [ "$status" -eq 0 ]
  ROOT='' run boot_advice 12
  [[ $output == *"Mount the boot partition (sudo mount /boot)"* ]]
  [[ $output == *"Snapshot 12 is the state before this update."* ]]
  mountpoint() { return 0; }
  ROOT='' run esp_unmounted /boot
  [ "$status" -eq 1 ]
}

@test "the update's snapshots are kept apart from the ones around every pacman run" {
  snapper() { echo "snapper $*"; }
  run snapshot "nova update v1.0.0 -> v1.1.0" --type pre
  [[ $output == *"--cleanup-algorithm number --userdata important=yes"* ]]
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
prepare_pi_update() { # boot-check status
  mkdir -p "$SCRATCH/lib" "$SCRATCH/bin" "$NOVA_ROOT/etc/pacman.d"
  cp "$REPO_ROOT/src/cli/bin/nova-update-apply" "$SCRATCH/lib/"
  printf '#!/bin/bash\nexit 1\n' >"$SCRATCH/lib/nova-hw-detect"
  printf '#!/bin/bash\necho "nova-boot-check $*" >>"$SCRATCH/calls"\nexit %s\n' "$1" >"$SCRATCH/lib/nova-boot-check"
  printf '#!/bin/bash\necho "${0##*/} $*" >>"$SCRATCH/calls"\n' >"$SCRATCH/bin/pacman"
  cp "$SCRATCH/bin/pacman" "$SCRATCH/bin/snapper"
  chmod +x "$SCRATCH"/lib/* "$SCRATCH"/bin/*
}

run_pi_update() {
  PATH="$SCRATCH/bin:$PATH" NOVA_ARCH=aarch64 "$SCRATCH/lib/nova-update-apply" --tag v1.1.0 --version 1.1.0 \
    --arch-date 2026/10/19 --nova-repo https://example.org/repo \
    --alarm-date 2026/10/20 --alarm-pool https://example.org/alarm/aarch64 --noconfirm
}

pi_update() { # boot-check status
  prepare_pi_update "$1"
  run_pi_update
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

@test "a failed second pin write restores both pins before any pacman runs" {
  put "$NOVA_ROOT/etc/pacman.d/nova-alarm" 'old alarm'
  put "$REPOFILE" 'old repo'
  put "$SYNC_DIR/core.db" 'old core'
  mkdir -p "$SCRATCH/bin"
  cat >"$SCRATCH/bin/mv" <<'STUB'
#!/bin/bash
if [[ ${3:-} == "$NOVA_ROOT/etc/pacman.d/nova-repo" && ${2:-} != *.nova-prev ]]; then
  echo 'mv: No space left on device' >&2
  exit 1
fi
exec /usr/bin/mv "$@"
STUB
  chmod +x "$SCRATCH/bin/mv"
  run pi_update 0
  [ "$status" -ne 0 ]
  [[ $output == *"No space left on device"* ]]
  [ "$(cat "$NOVA_ROOT/etc/pacman.d/nova-alarm")" = 'old alarm' ]
  [ "$(cat "$REPOFILE")" = 'old repo' ]
  [ "$(cat "$SYNC_DIR/core.db")" = 'old core' ]
  [ ! -e "$SCRATCH/calls" ]
}

@test "boot verification must finish before recovery copies are dropped" {
  put "$REPOFILE" 'old repo'
  run pi_update 1
  [ "$status" -eq 3 ]
  [ "$(cat "$REPOFILE.nova-prev")" = 'old repo' ]
  run pi_update 0
  [ "$status" -eq 0 ]
  [ ! -e "$REPOFILE.nova-prev" ]
  [ ! -e "$NOVA_ROOT/etc/pacman.d/nova-alarm.nova-absent" ]
}

@test "restoring a pin that did not exist removes the new file" {
  mkdir -p "$NOVA_ROOT/etc/pacman.d"
  backup_config
  put "$MIRRORLIST" 'new mirror'
  put "$REPOFILE" 'new repo'
  restore_config
  [ ! -e "$MIRRORLIST" ]
  [ ! -e "$REPOFILE" ]
  [ ! -e "$REPOFILE.nova-absent" ]
}

@test "a second update cannot change pins while the first verifies boot" {
  prepare_pi_update 0
  mkfifo "$SCRATCH/entered" "$SCRATCH/release"
  cat >"$SCRATCH/lib/nova-boot-check" <<'STUB'
#!/bin/bash
echo ready >"$SCRATCH/entered"
read -r -t 10 reply <"$SCRATCH/release"
STUB
  run_pi_update >"$SCRATCH/first.log" 2>&1 &
  local first_pid=$!
  # Hold the first process in verification, after pacman released its lock.
  read -r -t 10 reply <"$SCRATCH/entered"
  run run_pi_update
  local second_status=$status second_output=$output
  echo done >"$SCRATCH/release"
  wait "$first_pid"
  [ "$second_status" -ne 0 ]
  [[ $second_output == *"another Nova update is running"* ]]
  [ "$(grep -c '^pacman -Syy' "$SCRATCH/calls")" -eq 1 ]
  [ "$(grep -c '^pacman -Su ' "$SCRATCH/calls")" -eq 1 ]
  # Exiting releases the lock, so the next attempt is allowed.
  printf '#!/bin/bash\nexit 0\n' >"$SCRATCH/lib/nova-boot-check"
  run run_pi_update
  [ "$status" -eq 0 ]
}

# Chrome and VS Code, built by nova update for Settings before it asks for
# root, go in with the same authentication.
built_package() { # file name -> its path
  mkdir -p "$SCRATCH/build"
  : >"$SCRATCH/build/$1"
  echo "$SCRATCH/build/$1"
}

# One repository, whose package list is there.
lists_read() {
  printf '#!/bin/bash\necho core\n' >"$SCRATCH/bin/pacman-conf"
  chmod +x "$SCRATCH/bin/pacman-conf"
  mkdir -p "$SYNC_DIR"
  : >"$SYNC_DIR/core.db"
}

@test "--packages-only installs a copy of the built packages, which only root could change" {
  prepare_pi_update 0
  lists_read
  local chrome
  chrome=$(built_package google-chrome-141.0.7390.54-1-x86_64.pkg.tar.zst)
  run env PATH="$SCRATCH/bin:$PATH" PKEXEC_UID="$(id -u)" "$SCRATCH/lib/nova-update-apply" --packages-only --package "$chrome"
  [ "$status" -eq 0 ]
  [[ $(cat "$SCRATCH/calls") =~ ^"pacman -U --needed --noconfirm $NOVA_ROOT/var/tmp/nova-update."[A-Za-z0-9]+"/google-chrome-141.0.7390.54-1-x86_64.pkg.tar.zst"$ ]]
  [[ $output == *"Installing google-chrome"* ]]
  # The copy goes once it is in.
  [ -z "$(ls "$NOVA_ROOT/var/tmp")" ]
}

@test "--packages-only reads the package lists first on a system that has none" {
  prepare_pi_update 0
  printf '#!/bin/bash\necho core\n' >"$SCRATCH/bin/pacman-conf"
  chmod +x "$SCRATCH/bin/pacman-conf"
  local chrome
  chrome=$(built_package google-chrome-141.0-1-x86_64.pkg.tar.lz4)
  run env PATH="$SCRATCH/bin:$PATH" "$SCRATCH/lib/nova-update-apply" --packages-only --package "$chrome"
  [ "$status" -eq 0 ]
  [ "$(grep -oE '^pacman -[A-Za-z]+' "$SCRATCH/calls" | paste -sd' ')" = "pacman -Sy pacman -U" ]
}

@test "a release goes in with the built packages after it, under one authentication" {
  prepare_pi_update 0
  local code
  code=$(built_package visual-studio-code-bin-1.106.0-1-aarch64.pkg.tar.zst)
  run env PATH="$SCRATCH/bin:$PATH" NOVA_ARCH=aarch64 "$SCRATCH/lib/nova-update-apply" --tag v1.1.0 --version 1.1.0 \
    --arch-date 2026/10/19 --nova-repo https://example.org/repo \
    --alarm-date 2026/10/20 --alarm-pool https://example.org/alarm/aarch64 --noconfirm --package "$code"
  [ "$status" -eq 0 ]
  [[ $(cat "$SCRATCH/calls") =~ ^"pacman -Syy --needed --noconfirm archlinuxarm-keyring nova-keyring
pacman -Su --noconfirm
pacman -U --needed --noconfirm $NOVA_ROOT/var/tmp/nova-update."[A-Za-z0-9]+"/visual-studio-code-bin-1.106.0-1-aarch64.pkg.tar.zst
nova-boot-check status"$ ]]
}

@test "an app that will not go in leaves the release installed" {
  prepare_pi_update 0
  printf '#!/bin/bash\necho "${0##*/} $*" >>"$SCRATCH/calls"\n[[ $1 != -U ]]\n' >"$SCRATCH/bin/pacman"
  local chrome
  chrome=$(built_package google-chrome-141.0-1-x86_64.pkg.tar.zst)
  run env PATH="$SCRATCH/bin:$PATH" NOVA_ARCH=aarch64 "$SCRATCH/lib/nova-update-apply" --tag v1.1.0 --version 1.1.0 \
    --arch-date 2026/10/19 --nova-repo https://example.org/repo \
    --alarm-date 2026/10/20 --alarm-pool https://example.org/alarm/aarch64 --noconfirm --package "$chrome"
  [ "$status" -eq 0 ]
  [[ $output == *"could not install google-chrome; nova apps install tries again"* ]]
  [[ $output == *"Nova is now on v1.1.0."* ]]
}

@test "anything but a package file is refused before anything changes" {
  prepare_pi_update 0
  local chrome
  chrome=$(built_package google-chrome-141.0-1-x86_64.pkg.tar.zst)
  ln -s "$chrome" "$SCRATCH/build/link-1-1-x86_64.pkg.tar.zst"
  for bad in /etc/passwd "build/google-chrome-141.0-1-x86_64.pkg.tar.zst" "$SCRATCH/build/link-1-1-x86_64.pkg.tar.zst" \
    "$SCRATCH/build/missing-1-1-x86_64.pkg.tar.zst"; do
    run env PATH="$SCRATCH/bin:$PATH" "$SCRATCH/lib/nova-update-apply" --packages-only --package "$bad"
    [ "$status" -ne 0 ]
    [[ $output == *"bad --package: $bad"* ]]
  done
  run env PATH="$SCRATCH/bin:$PATH" "$SCRATCH/lib/nova-update-apply" --packages-only
  [ "$status" -ne 0 ]
  [ ! -e "$SCRATCH/calls" ]
}

@test "only Chrome and VS Code, and only the authenticating user's own files" {
  prepare_pi_update 0
  local pam chrome
  pam=$(built_package pam-1.7.1-1-x86_64.pkg.tar.zst)
  run env PATH="$SCRATCH/bin:$PATH" "$SCRATCH/lib/nova-update-apply" --packages-only --package "$pam"
  [ "$status" -ne 0 ]
  [[ $output == *"bad --package: $pam"* ]]
  chrome=$(built_package google-chrome-141.0-1-x86_64.pkg.tar.zst)
  run env PATH="$SCRATCH/bin:$PATH" PKEXEC_UID=$(($(id -u) + 1)) "$SCRATCH/lib/nova-update-apply" --packages-only --package "$chrome"
  [ "$status" -ne 0 ]
  [[ $output == *"bad --package: $chrome"* ]]
  [ ! -e "$SCRATCH/calls" ]
  [ -z "$(ls "$NOVA_ROOT/var/tmp" 2>/dev/null)" ]
}
