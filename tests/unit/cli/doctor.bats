#!/usr/bin/env bats

# nova doctor against a stubbed system: each check's verdict, and that only a
# FAIL fails the run.

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" XDG_DATA_HOME="$SCRATCH/data" XDG_STATE_HOME="$SCRATCH/state"
  export NOVA_SYSFS_BTRFS="$SCRATCH/sys" NOVA_PAM_DIR="$SCRATCH/pam.d" NOVA_MODULES_DIR="$SCRATCH/modules"
  export NOVA_SNAPPER_CONFIG="$SCRATCH/snapper/root" NOVA_BOOT_ESP="$SCRATCH/esp"
  unset WAYLAND_DISPLAY
  mkdir -p "$HOME" "$SCRATCH/bin" "$NOVA_MODULES_DIR/6.17.0-nova1" "$NOVA_BOOT_ESP"
  write_file "$NOVA_SYSFS_BTRFS/f00d/devinfo/1/error_stats" $'write_errs 0\nread_errs 0\nflush_errs 0\ncorruption_errs 0\ngeneration_errs 0\n'
  write_file "$NOVA_PAM_DIR/nova-lock-password"
  write_file "$NOVA_SNAPPER_CONFIG"

  export ROOT_OPTIONS=rw,noatime USED=41 MISSING=0 SYSTEM_FAILED='' USER_FAILED=''
  stub findmnt 'echo "btrfs $ROOT_OPTIONS f00d"'
  stub df 'printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 100 1 1 %s%% /\n" "$USED"'
  stub pacman 'case $1 in -Q) echo "nova 1.0.0beta.1-1" ;; -Qk) echo "nova: 1200 total files, $MISSING missing files" ;; esac'
  stub uname 'echo 6.17.0-nova1'
  stub systemctl 'case " $* " in
    *" --user "*"--failed"*) [[ -z $USER_FAILED ]] || echo "$USER_FAILED loaded failed failed A unit" ;;
    *"--failed"*) [[ -z $SYSTEM_FAILED ]] || echo "$SYSTEM_FAILED loaded failed failed A unit" ;;
  esac'
  stub timedatectl 'echo yes'
  stub nova-hw-detect 'exit 1'
  stub nova-boot-check 'exit 0'
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name [body]
  printf '#!/bin/bash\n%s\n' "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

doctor() { "$REPO_ROOT/src/cli/bin/nova-doctor"; }

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

@test "missing package files fail" {
  MISSING=3 run doctor
  [ "$status" -eq 1 ]
  [[ $output == *"FAIL  3 of nova's files are missing"* ]]
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

@test "the shell is checked inside a session" {
  stub nova-shell 'exit 1'
  WAYLAND_DISPLAY=wayland-1 run doctor
  [[ $output == *"warn  the shell is not running"* ]]
  stub nova-shell 'echo ok'
  WAYLAND_DISPLAY=wayland-1 run doctor
  [[ $output == *"ok    the shell is running"* ]]
}
