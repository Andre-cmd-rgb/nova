#!/usr/bin/env bats

# nova doctor against a stubbed system: each check's verdict, and that only a
# FAIL fails the run.

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" XDG_DATA_HOME="$SCRATCH/data" XDG_STATE_HOME="$SCRATCH/state"
  export NOVA_SYSFS_BTRFS="$SCRATCH/sys" NOVA_PAM_DIR="$SCRATCH/pam.d" NOVA_MODULES_DIR="$SCRATCH/modules"
  export NOVA_SNAPPER_CONFIG="$SCRATCH/snapper/root" NOVA_BOOT_ESP="$SCRATCH/esp"
  export NOVA_ARCH=x86_64
  unset WAYLAND_DISPLAY HYPRLAND_INSTANCE_SIGNATURE
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
  # No undervolt tool, rather than this computer's own undervolt.
  stub nova-power-undervolt 'exit 1'
  export PATH="$SCRATCH/bin:$PATH"
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

@test "a Raspberry Pi: its boot partition is checked as you, and no snapshots are asked for" {
  rm "$NOVA_SNAPPER_CONFIG"
  stub findmnt 'echo "ext4 $ROOT_OPTIONS f00d"'
  NOVA_ARCH=aarch64 run doctor
  [ "$status" -eq 0 ]
  [[ $output != *snapshot* && $output != *"boot menu"* ]]
  [[ $output == *"ok    / is writable (ext4)"* ]]
  [[ $output == *"ok    the boot partition holds the installed kernel"* ]]
}

@test "a Raspberry Pi whose boot partition lacks the installed kernel fails" {
  stub nova-boot-check 'printf "The boot partition is not ready to start this Pi:\n  the boot partition is not mounted at /boot (mount it: sudo mount /boot)\n"; exit 1'
  NOVA_ARCH=aarch64 run doctor
  [ "$status" -eq 1 ]
  [[ $output == *"FAIL  the Pi may not start the installed kernel"* ]]
  [[ $output == *"not mounted at /boot"* ]]
}

@test "a Raspberry Pi's full disk points at pacman's cache, not snapshots" {
  USED=96 NOVA_ARCH=aarch64 run doctor
  [[ $output == *"sudo pacman -Sc"* && $output != *snapper* ]]
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
