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

@test "pacman's lock left from before this boot is taken away; one made since is not" {
  put "$SCRATCH/stat" "$(printf 'cpu 1 2 3\nbtime 2000000000\n')"
  export NOVA_PROC_STAT=$SCRATCH/stat
  put "$NOVA_ROOT/var/lib/pacman/db.lck"
  touch -d @1999999000 "$NOVA_ROOT/var/lib/pacman/db.lck"
  run take_lock
  [ "$status" -eq 0 ]
  [[ $output == *"pacman's lock was left by a computer that stopped"* ]]
  [ ! -e "$NOVA_ROOT/var/lib/pacman/db.lck" ]
  put "$NOVA_ROOT/var/lib/pacman/db.lck"
  touch -d @2000000100 "$NOVA_ROOT/var/lib/pacman/db.lck"
  run take_lock
  [ "$status" -eq 0 ]
  [ -e "$NOVA_ROOT/var/lib/pacman/db.lck" ]
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

@test "an update points pacman at the release's Arch snapshot and [nova] repository" {
  mkdir -p "$NOVA_ROOT/etc/pacman.d"
  tag=v1.1.0 arch_date=2026/10/19 nova_repo=https://example.org/repo write_config
  [ "$(cat "$MIRRORLIST")" = '# Managed by nova update; the next update rewrites this file.
# nova-release: v1.1.0
# arch-date: 2026/10/19
Server = https://archive.archlinux.org/repos/2026/10/19/$repo/os/$arch' ]
  [ "$(cat "$REPOFILE")" = "# Managed by nova update; the next update rewrites this file.
# nova-release: v1.1.0
Server = https://example.org/repo" ]
}

# A whole update, with the helpers next to the script as they are installed,
# and pacman, snapper (snapshot 7) and limine-update stubbed.
prepare_update() {
  mkdir -p "$SCRATCH/lib" "$SCRATCH/bin" "$NOVA_ROOT/etc/pacman.d"
  cp "$REPO_ROOT/src/cli/bin/nova-update-apply" "$SCRATCH/lib/"
  printf '#!/bin/bash\nexit 1\n' >"$SCRATCH/lib/nova-hw-detect"
  printf '#!/bin/bash\necho "${0##*/} $*" >>"$SCRATCH/calls"\n' >"$SCRATCH/bin/pacman"
  cp "$SCRATCH/bin/pacman" "$SCRATCH/bin/limine-update"
  printf '#!/bin/bash\necho 7\n' >"$SCRATCH/bin/snapper"
  chmod +x "$SCRATCH"/lib/* "$SCRATCH"/bin/*
}

run_update() {
  PATH="$SCRATCH/bin:$PATH" "$SCRATCH/lib/nova-update-apply" --tag v1.1.0 --version 1.1.0 \
    --arch-date 2026/10/19 --nova-repo https://example.org/repo --noconfirm "$@"
}

whole_update() {
  prepare_update
  run_update
}

@test "an update: the keyrings, then pacman, then the boot entries checked" {
  run whole_update
  [ "$status" -eq 0 ]
  [ "$(cat "$SCRATCH/calls")" = "pacman -Syy --needed --noconfirm archlinux-keyring nova-keyring
pacman -Su --noconfirm" ]
  [[ $output == *"Snapshot 7 taken"* ]]
  [[ $output == *"Arch snapshot 2026/10/19 and v1.1.0"* ]]
  [[ $output == *"Boot entries look right"* ]]
  [[ $output == *"Nova is now on v1.1.0."* ]]
}

@test "an update whose boot entries limine-update cannot repair says so" {
  uki "nova_linux-nova.efi" 7.2.10-arch1-1-nova
  run whole_update
  [ "$status" -eq 3 ]
  grep -qx 'limine-update ' "$SCRATCH/calls"
  [[ $output == *"do NOT check out"* ]]
  [[ $output == *"Snapshot 7 is the state before this update."* ]]
}

# nova update stopped, at a logout say, or a `| tee` ended: the rest of the
# output finds no reader. Killed by SIGPIPE, the update used to stop between
# pacman's two runs, its new pins in place and none of its checks done.
@test "an update whose output's reader goes away goes on to its end, into the log" {
  prepare_update
  printf '#!/bin/bash\necho "${0##*/} $*" >>"$SCRATCH/calls"\nsleep 0.3\n' >"$SCRATCH/bin/pacman"
  mkdir -p "$NOVA_ROOT/var/log"
  run_update 2>&1 | head -n 1 >/dev/null
  [ "${PIPESTATUS[0]}" -eq 0 ]
  [ "$(cat "$SCRATCH/calls")" = "pacman -Syy --needed --noconfirm archlinux-keyring nova-keyring
pacman -Su --noconfirm" ]
  grep -q "what read the output went away; continuing here" "$NOVA_ROOT/var/log/nova-update.log"
  grep -q "Nova is now on v1.1.0." "$NOVA_ROOT/var/log/nova-update.log"
  [ ! -e "$MIRRORLIST.nova-prev" ]
}

# The move back from a snapshot that split a package in two, as openssl 4.1 did
# on 2026-11-10: openssl-3 came in as a dependency and owns the libcrypto.so.3
# the older openssl has itself. pacman answers as it would there; the app and
# its helper built by hand were in no repository before either.
prepare_move_back() { # status of pacman -R [how pacman -Qlq answers, asked what every package owns]
  local all=${2-"printf '/%s\n' usr/ usr/lib/ usr/lib/libcrypto.so.3 usr/share/ usr/share/licenses/"}
  prepare_update
  cat >"$SCRATCH/bin/pacman" <<STUB
#!/bin/bash
echo "pacman \$*" >>"$SCRATCH/calls"
case "\$*" in
  -Qqm) printf '%s\n' google-chrome chrome-helper ;;
  -Qqdm) printf '%s\n' chrome-helper openssl-3 ;;
  '-Qlq openssl-3') printf '/%s\n' usr/ usr/lib/ usr/lib/libcrypto.so.3 usr/share/ usr/share/licenses/ usr/share/licenses/openssl-3/ 'usr/share/licenses/openssl-3/LICENSE[1]' ;;
  -Qlq) $all ;;
  -R*) exit $1 ;;
esac
STUB
  put "$NOVA_ROOT/usr/lib/libcrypto.so.3" 'the older openssl'
  put "$NOVA_ROOT/usr/share/licenses/openssl-3/LICENSE[1]"
  put "$NOVA_ROOT/usr/share/licenses/openssl/LICENSE"
}

@test "going back to an older release takes with it what only the newer one had" {
  prepare_move_back 0
  run run_update --allow-downgrade
  [ "$status" -eq 0 ]
  [ "$(cat "$SCRATCH/calls")" = "pacman -Qqm
pacman -Syy --needed --noconfirm archlinux-keyring nova-keyring
pacman -Qqdm
pacman -Qlq openssl-3
pacman -Suu --noconfirm --overwrite usr/lib/libcrypto.so.3 --overwrite usr/share/licenses/openssl-3/LICENSE\\[1\\]
pacman -R --dbonly --noconfirm openssl-3
pacman -Qlq" ]
  [[ $output == *"The older release has no openssl-3: taken out with the move"* ]]
  # What the older packages own stays; what it alone owned is gone, folder too.
  [ "$(cat "$NOVA_ROOT/usr/lib/libcrypto.so.3")" = 'the older openssl' ]
  [ ! -e "$NOVA_ROOT/usr/share/licenses/openssl-3" ]
  [ -e "$NOVA_ROOT/usr/share/licenses/openssl/LICENSE" ]
}

@test "one that something installed still needs stays, files and all, and the update goes on" {
  prepare_move_back 1
  run run_update --allow-downgrade
  [ "$status" -eq 0 ]
  [[ $output == *"openssl-3 could not be taken out"* ]]
  [[ $output == *"Nova is now on v1.1.0."* ]]
  [ -e "$NOVA_ROOT/usr/share/licenses/openssl-3/LICENSE[1]" ]
  ! grep -qx 'pacman -Qlq' "$SCRATCH/calls"
}

# Every file would look like one nobody owns, the older openssl's library too.
@test "with no list of what the packages own, no file is taken off the disk" {
  local answer
  for answer in 'exit 1' true; do
    rm -f "$SCRATCH/calls"
    prepare_move_back 0 "$answer"
    run run_update --allow-downgrade
    [ "$status" -eq 0 ]
    [[ $output == *"the files of openssl-3 stay where they are"* ]]
    [ "$(cat "$NOVA_ROOT/usr/lib/libcrypto.so.3")" = 'the older openssl' ]
    [ -e "$NOVA_ROOT/usr/share/licenses/openssl-3/LICENSE[1]" ]
  done
}

@test "a move back with nothing of the newer release's alone is pacman -Suu as before" {
  prepare_update
  run run_update --allow-downgrade
  [ "$status" -eq 0 ]
  [ "$(cat "$SCRATCH/calls")" = "pacman -Qqm
pacman -Syy --needed --noconfirm archlinux-keyring nova-keyring
pacman -Qqdm
pacman -Suu --noconfirm" ]
}

# tail sees the update gone within a second; a restart asked for in that
# second, as a script's next line is, was refused in the update's name.
@test "the hold on shutting down is let go as the update leaves, and waited for" {
  sleep 30 3>&- &
  local hold=$!
  shutdown_hold=$hold
  on_exit
  ! kill -0 "$hold" 2>/dev/null
  [ -z "$shutdown_hold" ]
  # With none taken, as in a scratch root, leaving is all there is to do.
  on_exit
}

@test "a failed second pin write restores both pins before any pacman runs" {
  put "$MIRRORLIST" 'old mirror'
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
  run whole_update
  [ "$status" -ne 0 ]
  [[ $output == *"No space left on device"* ]]
  [ "$(cat "$MIRRORLIST")" = 'old mirror' ]
  [ "$(cat "$REPOFILE")" = 'old repo' ]
  [ "$(cat "$SYNC_DIR/core.db")" = 'old core' ]
  [ ! -e "$SCRATCH/calls" ]
}

@test "a copy of the pins that cannot be made stops the update before they change" {
  put "$MIRRORLIST" 'old mirror'
  put "$REPOFILE" 'old repo'
  mkdir -p "$SCRATCH/bin"
  cat >"$SCRATCH/bin/cp" <<'STUB'
#!/bin/bash
if [[ ${*: -1} == *.nova-prev.tmp ]]; then
  echo 'cp: No space left on device' >&2
  exit 1
fi
exec /usr/bin/cp "$@"
STUB
  chmod +x "$SCRATCH/bin/cp"
  run whole_update
  [ "$status" -ne 0 ]
  [[ $output == *"No space left on device"* ]]
  [ "$(cat "$MIRRORLIST")" = 'old mirror' ]
  [ "$(cat "$REPOFILE")" = 'old repo' ]
  [ ! -e "$SCRATCH/calls" ]
}

@test "boot verification must finish before recovery copies are dropped" {
  put "$REPOFILE" 'old repo'
  uki "nova_linux-nova.efi" 7.2.10-arch1-1-nova
  run whole_update
  [ "$status" -eq 3 ]
  [ "$(cat "$REPOFILE.nova-prev")" = 'old repo' ]
  uki "nova_linux-nova.efi" "$kver"
  run whole_update
  [ "$status" -eq 0 ]
  [ ! -e "$REPOFILE.nova-prev" ]
  [ ! -e "$MIRRORLIST.nova-absent" ]
}

@test "--check-boot ends an update that only its boot entries held up, and no other" {
  put "$REPOFILE" 'old repo'
  uki "nova_linux-nova.efi" 7.2.10-arch1-1-nova
  run whole_update
  [ "$status" -eq 3 ]
  # Not yet repaired: the copies stay.
  run check_boot_alone 0
  [ "$status" -eq 3 ]
  [ "$(cat "$REPOFILE.nova-prev")" = 'old repo' ]
  uki "nova_linux-nova.efi" "$kver"
  run check_boot_alone 0
  [ "$status" -eq 0 ]
  [[ $output == *"The update is finished"* ]]
  [ ! -e "$REPOFILE.nova-prev" ]
  [ ! -e "$MIRRORLIST.nova-absent" ]
  [ ! -e "$REPOFILE.nova-boot-unchecked" ]
  # The copies of an update the power cut short say its packages may be half
  # in: boot entries that check out do not end that one.
  put "$REPOFILE.nova-prev" 'older repo'
  run check_boot_alone 0
  [ "$status" -eq 0 ]
  [[ $output != *"The update is finished"* ]]
  [ "$(cat "$REPOFILE.nova-prev")" = 'older repo' ]
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
  prepare_update
  # The first finds an image not rebuilt, and is held in limine-update, which
  # then writes it.
  cp "$NOVA_ROOT/boot/EFI/Linux/nova_linux-nova.efi" "$SCRATCH/rebuilt.efi"
  uki "nova_linux-nova.efi" 7.2.10-arch1-1-nova
  mkfifo "$SCRATCH/entered" "$SCRATCH/release"
  cat >"$SCRATCH/bin/limine-update" <<'STUB'
#!/bin/bash
echo ready >"$SCRATCH/entered"
read -r -t 10 reply <"$SCRATCH/release"
cp "$SCRATCH/rebuilt.efi" "$NOVA_ROOT/boot/EFI/Linux/nova_linux-nova.efi"
STUB
  run_update >"$SCRATCH/first.log" 2>&1 &
  local first_pid=$!
  # Hold the first process in verification, after pacman released its lock.
  read -r -t 10 reply <"$SCRATCH/entered"
  run run_update
  local second_status=$status second_output=$output
  echo done >"$SCRATCH/release"
  wait "$first_pid"
  [ "$second_status" -ne 0 ]
  [[ $second_output == *"another Nova update is running"* ]]
  [ "$(grep -c '^pacman -Syy' "$SCRATCH/calls")" -eq 1 ]
  [ "$(grep -c '^pacman -Su ' "$SCRATCH/calls")" -eq 1 ]
  # Exiting releases the lock, so the next attempt is allowed.
  run run_update
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
  prepare_update
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
  prepare_update
  printf '#!/bin/bash\necho core\n' >"$SCRATCH/bin/pacman-conf"
  chmod +x "$SCRATCH/bin/pacman-conf"
  local chrome
  chrome=$(built_package google-chrome-141.0-1-x86_64.pkg.tar.lz4)
  run env PATH="$SCRATCH/bin:$PATH" "$SCRATCH/lib/nova-update-apply" --packages-only --package "$chrome"
  [ "$status" -eq 0 ]
  [ "$(grep -oE '^pacman -[A-Za-z]+' "$SCRATCH/calls" | paste -sd' ')" = "pacman -Sy pacman -U" ]
}

@test "a release goes in with the built packages after it, under one authentication" {
  prepare_update
  local code
  code=$(built_package visual-studio-code-bin-1.106.0-1-x86_64.pkg.tar.zst)
  run run_update --package "$code"
  [ "$status" -eq 0 ]
  [[ $(cat "$SCRATCH/calls") =~ ^"pacman -Syy --needed --noconfirm archlinux-keyring nova-keyring
pacman -Su --noconfirm
pacman -U --needed --noconfirm $NOVA_ROOT/var/tmp/nova-update."[A-Za-z0-9]+"/visual-studio-code-bin-1.106.0-1-x86_64.pkg.tar.zst"$ ]]
}

@test "an app that will not go in leaves the release installed" {
  prepare_update
  printf '#!/bin/bash\necho "${0##*/} $*" >>"$SCRATCH/calls"\n[[ $1 != -U ]]\n' >"$SCRATCH/bin/pacman"
  local chrome
  chrome=$(built_package google-chrome-141.0-1-x86_64.pkg.tar.zst)
  run run_update --package "$chrome"
  [ "$status" -eq 0 ]
  [[ $output == *"could not install google-chrome; nova apps install tries again"* ]]
  [[ $output == *"Nova is now on v1.1.0."* ]]
}

@test "anything but a package file is refused before anything changes" {
  prepare_update
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
  prepare_update
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

# A model's packages after an update, with nova-hw-detect beside the script
# naming the model and pacman stubbed: -T says each one is missing.
hardware_update() {
  mkdir -p "$SCRATCH/lib" "$SCRATCH/bin"
  cp "$REPO_ROOT/src/cli/bin/nova-update-apply" "$SCRATCH/lib/"
  printf '#!/bin/bash\necho thinkpad-p1-gen4i\n' >"$SCRATCH/lib/nova-hw-detect"
  printf '#!/bin/bash\nif [[ $1 == -T ]]; then shift; printf "%%s\\n" "$@"; exit 127; fi\necho "pacman $*" >>"%s/calls"\n' "$SCRATCH" >"$SCRATCH/bin/pacman"
  chmod +x "$SCRATCH/lib/nova-hw-detect" "$SCRATCH/bin/pacman"
  put "$NOVA_ROOT/usr/share/nova/hardware/thinkpad-p1-gen4i/packages" $'# the P1\nnvidia-open-nova\nfprintd\n'
  # $0 beside the script, so its nova-hw-detect is found and its main stays put.
  PATH="$SCRATCH/bin:$PATH" bash -c 'source "$1"; install_hardware_packages 1' "$SCRATCH/lib/test" "$SCRATCH/lib/nova-update-apply"
}

@test "an update installs what the computer's model needs and is missing" {
  run hardware_update
  [ "$status" -eq 0 ]
  [[ $output == *"Installing for this computer: nvidia-open-nova fprintd"* ]]
  grep -qx 'pacman -S --needed --noconfirm nvidia-open-nova fprintd' "$SCRATCH/calls"
}

@test "a portable Nova takes no model's packages, whichever computer it is updated on" {
  put "$NOVA_ROOT/etc/nova/portable" "# portable"
  run hardware_update
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$SCRATCH/calls" ]
}

# What Nova stopped needing, after an update: pacman stubbed, with -Qdtq naming
# the packages in $UNNEEDED as dependencies nothing needs.
retired_update() {
  mkdir -p "$SCRATCH/lib" "$SCRATCH/bin"
  cp "$REPO_ROOT/src/cli/bin/nova-update-apply" "$SCRATCH/lib/"
  cat >"$SCRATCH/bin/pacman" <<'STUB'
#!/bin/bash
if [[ $1 == -Qdtq ]]; then
  [[ " $UNNEEDED " == *" $2 "* ]] && echo "$2" && exit 0
  exit 1
fi
echo "pacman $*" >>"$CALLS"
exit "${PACMAN_FAILS:-0}"
STUB
  chmod +x "$SCRATCH/bin/pacman"
  CALLS="$SCRATCH/calls" PATH="$SCRATCH/bin:$PATH" bash -c 'source "$1"; drop_retired' "$SCRATCH/lib/test" "$SCRATCH/lib/nova-update-apply"
}

@test "an update removes what Nova stopped needing, where nothing else needs it" {
  put "$NOVA_ROOT/usr/share/nova/retired" $'# what went\nold-effects   # why\nold-library\nkept-by-hand\n'
  UNNEEDED="old-effects old-library" run retired_update
  [ "$status" -eq 0 ]
  [[ $output == *"Removing what Nova no longer needs: old-effects old-library"* ]]
  grep -qx 'pacman -Rns --noconfirm old-effects old-library' "$SCRATCH/calls"
}

@test "what was installed by name, or is still needed, or is not there, stays" {
  put "$NOVA_ROOT/usr/share/nova/retired" $'old-effects\nold-library\n'
  UNNEEDED="" run retired_update
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$SCRATCH/calls" ]
  rm "$NOVA_ROOT/usr/share/nova/retired"
  UNNEEDED="old-effects" run retired_update
  [ "$status" -eq 0 ]
  [ ! -e "$SCRATCH/calls" ]
}

@test "a name that is no package's is passed over, and a removal that fails says how to try again" {
  put "$NOVA_ROOT/usr/share/nova/retired" $'--nodeps\nold-effects; rm -rf /\nold-library\n'
  UNNEEDED="old-library --nodeps" PACMAN_FAILS=1 run retired_update
  [ "$status" -eq 0 ]
  grep -qx 'pacman -Rns --noconfirm old-library' "$SCRATCH/calls"
  [[ $output == *"could not remove old-library; try again with: sudo pacman -Rns old-library"* ]]
}

@test "the retired list names packages, one a line, and none Nova still depends on" {
  local name
  while read -r name _; do
    [[ -n $name && $name != \#* ]] || continue
    [[ $name =~ ^[a-z0-9@._+-]+$ ]]
    ! grep -qE "^  $name( |\$)" "$REPO_ROOT/packaging/nova/PKGBUILD"
  done <"$REPO_ROOT/src/cli/retired"
}
