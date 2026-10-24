#!/usr/bin/env bats

# The installer's half of nova usb: opening what was carried and putting it
# back. The archives are made by nova usb's own writer, from a scratch home.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_CARRY="$SCRATCH/carry"
  export NOVA_TARGET="$SCRATCH/target"
  export NOVA_DMI_PATH="$SCRATCH/dmi"
  export NOVA_INSTALL_LOG="$SCRATCH/install.log"
  export NOVA_INSTALLER_SHARE="$SCRATCH/share"
  OLD_HOME=$SCRATCH/old-home
  mkdir -p "$NOVA_CARRY/carry" "$NOVA_TARGET/etc" "$NOVA_DMI_PATH" "$OLD_HOME" "$SCRATCH/plan" \
    "$NOVA_INSTALLER_SHARE/hardware"
  echo 4c4c4544 >"$NOVA_DMI_PATH/product_uuid"
  # The new account is this test's own user, so chown needs no root.
  printf 'nova:x:%s:%s::/home/nova:/bin/bash\n' "$(id -u)" "$(id -g)" >"$NOVA_TARGET/etc/passwd"
  mkdir -p "$NOVA_TARGET/home/nova"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/installer/nova-install"
}

teardown() { teardown_scratch; }

# carry <id>...: archives the items from the scratch old home with nova usb's
# writer (the files listed in $SCRATCH/plan/files.list), then the manifest and
# sums the way it writes them.
carry() {
  local id entries=()
  rm -f -- "$NOVA_CARRY"/carry/*
  for id in "$@"; do
    bash -c 'source "$1"; make_archive "$2" "$3" "$4" "$5"' _ \
      "$REPO_ROOT/installer/nova-usb" "$id" "$SCRATCH/plan" "$OLD_HOME" "$NOVA_CARRY/carry/$id.tar.zst"
    entries+=("$(jq -nc --arg id "$id" --arg kind "$(bash -c 'source "$1"; item_kind "$2"' _ "$REPO_ROOT/installer/nova-usb" "$id")" \
      '{id: $id, kind: $kind, label: $id, file: ($id + ".tar.zst"), bytes: 1}')")
  done
  (cd "$NOVA_CARRY/carry" && sha256sum -- *.tar.zst >SHA256SUMS)
  printf '%s\n' "${entries[@]}" | jq -s --arg machine "${MACHINE-$(machine_hash)}" \
    '{version: 1, source: {user: "andre", name: "Andre", host: "p1", machine: $machine}, items: .}' >"$NOVA_CARRY/carry/manifest.json"
}

@test "every_package: what any computer could need, once each" {
  cp "$REPO_ROOT/installer/packages" "$NOVA_INSTALLER_SHARE/packages"
  cp -r "$REPO_ROOT/data/hardware/thinkpad-p1-gen4i" "$REPO_ROOT/data/hardware/legion-5" "$NOVA_INSTALLER_SHARE/hardware/"
  run every_package
  [ "$status" -eq 0 ]
  for name in nova base linux-nova linux linux-lts intel-ucode amd-ucode vulkan-intel vulkan-radeon nvidia-open-nova nvidia-open nvidia-open-lts nvidia-utils nvidia-prime libva-nvidia-driver lsp-plugins-lv2; do
    grep -qx "$name" <<<"$output"
  done
  [ "$(sort <<<"$output" | uniq -d)" = "" ]
  [ "$(grep -c '#\|^$' <<<"$output")" = 0 ]
}

@test "carry_items and carry_value read the manifest" {
  mkdir -p "$OLD_HOME/.ssh"
  echo key >"$OLD_HOME/.ssh/id_ed25519"
  carry ssh
  carry_ready
  [ "$(carry_items)" = "$(printf 'ssh\thome\tssh.tar.zst\tssh')" ]
  [ "$(carry_value .source.host)" = p1 ]
  [ "$(carry_value .source.nothing)" = "" ]
}

@test "restore: the SSH keys and the files picked land in the new account, owned by it" {
  mkdir -p "$OLD_HOME/.ssh" "$OLD_HOME/Projects/app" "$OLD_HOME/Music"
  echo key >"$OLD_HOME/.ssh/id_ed25519"
  chmod 600 "$OLD_HOME/.ssh/id_ed25519"
  echo main >"$OLD_HOME/Projects/app/main.rs"
  echo todo >"$OLD_HOME/todo.txt"
  echo song >"$OLD_HOME/Music/song.flac"
  printf '%s\0' Projects todo.txt >"$SCRATCH/plan/files.list"
  carry ssh files
  restore_carry nova 2>/dev/null
  local home=$NOVA_TARGET/home/nova
  [ "$(cat "$home/.ssh/id_ed25519")" = key ]
  [ "$(stat -c %a "$home/.ssh/id_ed25519")" = 600 ]
  [ "$(cat "$home/Projects/app/main.rs")" = main ]
  [ "$(cat "$home/todo.txt")" = todo ]
  [ ! -e "$home/Music" ]
  [ "$(stat -c %u "$home/.ssh")" = "$(id -u)" ]
  [ "$(stat -c %u "$home/Projects/app/main.rs")" = "$(id -u)" ]
  [ "$(restorable_labels | paste -sd' ')" = "ssh files" ]
}

@test "restore: what an older nova usb carried besides keys and files stays on the stick" {
  mkdir -p "$OLD_HOME/.config/google-chrome" "$OLD_HOME/Projects/app" "$SCRATCH/old-root/etc/NetworkManager"
  echo cookies >"$OLD_HOME/.config/google-chrome/Cookies"
  echo main >"$OLD_HOME/Projects/app/main.rs"
  echo '[connection]' >"$SCRATCH/old-root/etc/NetworkManager/Home.nmconnection"
  tar -C "$OLD_HOME" -c .config | zstd -q -o "$NOVA_CARRY/carry/chrome.tar.zst"
  tar -C "$OLD_HOME" -c Projects | zstd -q -o "$NOVA_CARRY/carry/projects.tar.zst"
  tar -C "$SCRATCH/old-root" -c etc | zstd -q -o "$NOVA_CARRY/carry/wifi.tar.zst"
  jq -n '{version: 1, source: {user: "andre", host: "p1"}, items: [
    {id: "chrome", kind: "home", label: "Chrome", file: "chrome.tar.zst"},
    {id: "wifi", kind: "system", label: "Wi-Fi networks", file: "wifi.tar.zst"},
    {id: "projects", kind: "projects", label: "Projects", file: "projects.tar.zst"}]}' >"$NOVA_CARRY/carry/manifest.json"
  restore_carry nova 2>"$SCRATCH/screen"
  [ "$(cat "$NOVA_TARGET/home/nova/Projects/app/main.rs")" = main ]
  [ ! -e "$NOVA_TARGET/home/nova/.config" ]
  [ ! -e "$NOVA_TARGET/etc/NetworkManager" ]
  grep -q 'Chrome: left out' "$SCRATCH/screen"
  grep -q 'Wi-Fi networks: left out' "$SCRATCH/screen"
  [ "$(restorable_labels)" = Projects ]
}

@test "restore: nothing carried, nothing done" {
  rm -rf "$NOVA_CARRY"
  restore_carry nova
  [ "$(ls -A "$NOVA_TARGET/home/nova")" = "" ]
}

# The live system's fprintd and shadow tools, stubbed: busctl answers with the
# readers in $READERS, fprintd-enroll prints $ENROLL and files a print when the
# last line completes.
fingerprint_stubs() {
  export NOVA_FPRINT_DIR="$SCRATCH/fprint" READERS=1
  FPRINT_DIR=$NOVA_FPRINT_DIR
  mkdir -p "$SCRATCH/bin"
  printf '#!/bin/bash\n[[ $READERS == 0 ]] && echo "ao 0" || echo "ao 1 \\"/net/reactivated/Fprint/Device/0\\""\n' >"$SCRATCH/bin/busctl"
  printf '#!/bin/bash\nexit 1\n' >"$SCRATCH/bin/id"
  printf '#!/bin/bash\necho "useradd $*" >>"$SCRATCH/calls"\n' >"$SCRATCH/bin/useradd"
  cat >"$SCRATCH/bin/fprintd-enroll" <<'STUB'
#!/bin/bash
echo "fprintd-enroll $*" >>"$SCRATCH/calls"
printf '%s\n' "Using device /net/reactivated/Fprint/Device/0" "Enrolling right-index-finger finger." $ENROLL
if [[ $ENROLL == *enroll-completed ]]; then
  mkdir -p "$NOVA_FPRINT_DIR/${@: -1}/synaptics/0"
  echo print >"$NOVA_FPRINT_DIR/${@: -1}/synaptics/0/7"
fi
STUB
  chmod +x "$SCRATCH"/bin/*
  export PATH="$SCRATCH/bin:$PATH" SCRATCH
}

@test "fingerprint_reader: only a reader fprintd can drive counts" {
  fingerprint_stubs
  fingerprint_reader
  READERS=0 fails fingerprint_reader
}

@test "enroll_fingerprint: a stand-in account, the stages as words, and the print for the new system" {
  fingerprint_stubs
  export ENROLL="Enroll-result:enroll-stage-passed Enroll-result:enroll-retry-scan Enroll-result:enroll-completed"
  run enroll_fingerprint nova
  [ "$status" -eq 0 ]
  [[ $output == *"Got it. Again."*"That did not read."*"Done."* ]]
  grep -qx 'useradd -M -s /usr/bin/nologin nova' "$SCRATCH/calls"
  grep -qx 'fprintd-enroll -f right-index-finger nova' "$SCRATCH/calls"
  copy_fingerprints nova
  [ "$(cat "$NOVA_TARGET/var/lib/fprint/nova/synaptics/0/7")" = print ]
  [ "$(stat -c %a "$NOVA_TARGET/var/lib/fprint")" = 700 ]
}

@test "enroll_fingerprint: no print, no success, and nothing to copy" {
  fingerprint_stubs
  export ENROLL="Enroll-result:enroll-failed"
  run enroll_fingerprint nova
  [ "$status" -ne 0 ]
  copy_fingerprints nova
  [ ! -e "$NOVA_TARGET/var/lib/fprint" ]
}

@test "package_set: extra packages join the set, once" {
  cp "$REPO_ROOT/installer/packages" "$NOVA_INSTALLER_SHARE/packages"
  export NOVA_CPUINFO="$SCRATCH/cpuinfo" NOVA_PCI_DEVICES_PATH="$SCRATCH/pci"
  : >"$NOVA_CPUINFO"
  mkdir -p "$NOVA_PCI_DEVICES_PATH"
  run package_set linux "" fprintd fprintd
  [ "$(grep -cx fprintd <<<"$output")" = 1 ]
  [ "$(grep -c '^$' <<<"$output")" = 0 ]
}

@test "carry_unlock: Enter means installing without them, and is remembered" {
  rm -rf "$NOVA_CARRY"
  ANSWERS=$SCRATCH/answers
  : >"$ANSWERS"
  carry_partition() { echo /dev/fake2; }
  run carry_unlock
  [ "$status" -eq 1 ]
  [ -e "$CARRY_DECLINED" ]
}

@test "carry_unlock: on screen, a wrong passphrase asks again, and Esc goes on without them" {
  rm -rf "$NOVA_CARRY"
  carry_partition() { echo /dev/fake2; }
  cryptsetup() { return 1; }
  stub_gum wrong '!1'
  run carry_unlock
  [ "$status" -eq 1 ]
  [[ $output == *"That is not the passphrase."* ]]
  [ -e "$CARRY_DECLINED" ]
  [ "$(gum_replies_left)" = 0 ]
}

@test "carry_unlock: unattended, a passphrase that does not open it stops the install" {
  rm -rf "$NOVA_CARRY"
  ANSWERS=$SCRATCH/answers
  printf 'passphrase=wrong\n' >"$ANSWERS"
  carry_partition() { echo /dev/fake2; }
  cryptsetup() { return 1; }
  run carry_unlock
  [ "$status" -eq 1 ]
  [[ $output == *"does not open what this stick carries"* ]]
  [ ! -e "$CARRY_DECLINED" ]
}

@test "carry_unlock: Ctrl+C at the passphrase stops, rather than going on without them" {
  rm -rf "$NOVA_CARRY"
  carry_partition() { echo /dev/fake2; }
  stub_gum '!130'
  run carry_unlock
  [ "$status" -eq 130 ]
  [ ! -e "$CARRY_DECLINED" ]
}

@test "a warning is kept for the next screen when there is one" {
  UI_NOTES=$SCRATCH/notes
  : >"$UI_NOTES"
  warn "The stick would not open." 2>/dev/null
  [ "$(cat "$UI_NOTES")" = "The stick would not open." ]
}
