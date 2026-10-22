#!/usr/bin/env bats

# The installer's half of nova usb: opening what was carried and putting it
# back. The archives are made by nova usb's own writer, from a scratch home.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_CARRY="$SCRATCH/carry"
  export NOVA_TARGET="$SCRATCH/target"
  export NOVA_DMI_PATH="$SCRATCH/dmi"
  export NOVA_IWD_DIR="$SCRATCH/iwd"
  export NOVA_INSTALL_LOG="$SCRATCH/install.log"
  export NOVA_INSTALLER_SHARE="$SCRATCH/share"
  OLD_HOME=$SCRATCH/old-home
  OLD_ROOT=$SCRATCH/old-root
  mkdir -p "$NOVA_CARRY/carry" "$NOVA_TARGET/etc" "$NOVA_DMI_PATH" "$OLD_HOME" "$OLD_ROOT" "$SCRATCH/plan" \
    "$NOVA_INSTALLER_SHARE/hardware"
  echo 4c4c4544 >"$NOVA_DMI_PATH/product_uuid"
  # The new account is this test's own user, so chown needs no root.
  printf 'nova:x:%s:%s::/home/nova:/bin/bash\n' "$(id -u)" "$(id -g)" >"$NOVA_TARGET/etc/passwd"
  mkdir -p "$NOVA_TARGET/home/nova"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/installer/nova-install"
}

teardown() { teardown_scratch; }

fails() { if "$@"; then return 1; fi; }

# carry <id>...: archives the items from the scratch old home and root with
# nova usb's writer, then the manifest and sums the way it writes them.
carry() {
  local id entries=()
  rm -f -- "$NOVA_CARRY"/carry/*
  for id in "$@"; do
    NOVA_USB_SYSROOT=$OLD_ROOT bash -c 'source "$1"; make_archive "$2" "$3" "$4" "$5"' _ \
      "$REPO_ROOT/installer/nova-usb" "$id" "$SCRATCH/plan" "$OLD_HOME" "$NOVA_CARRY/carry/$id.tar.zst"
    entries+=("$(jq -nc --arg id "$id" --arg kind "$(bash -c 'source "$1"; item_field "$2" 3' _ "$REPO_ROOT/installer/nova-usb" "$id")" \
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

@test "Wi-Fi for the live system: personal and open networks become iwd's" {
  local dir=$OLD_ROOT/etc/NetworkManager/system-connections
  mkdir -p "$dir"
  printf '[connection]\nid=Home\ntype=wifi\n\n[wifi]\nssid=Home Net\n\n[wifi-security]\nkey-mgmt=wpa-psk\npsk=hunter2 =x\n' >"$dir/Home.nmconnection"
  printf '[connection]\ntype=wifi\n[wifi]\nssid=Café\n[wifi-security]\nkey-mgmt=sae\npsk=s3cret\n' >"$dir/Cafe.nmconnection"
  printf '[connection]\ntype=wifi\n[wifi]\nssid=Library\n' >"$dir/Library.nmconnection"
  printf '[connection]\ntype=wifi\n[wifi]\nssid=Work\n[wifi-security]\nkey-mgmt=wpa-eap\n' >"$dir/Work.nmconnection"
  printf '[connection]\ntype=wifi\n[wifi]\nssid=Agent\n[wifi-security]\nkey-mgmt=wpa-psk\npsk-flags=1\n' >"$dir/Agent.nmconnection"
  printf '[connection]\ntype=ethernet\n' >"$dir/Wired.nmconnection"
  carry wifi
  carry_wifi_live
  [ "$(cat "$NOVA_IWD_DIR/Home Net.psk")" = "$(printf '[Security]\nPassphrase=hunter2 =x')" ]
  [ -f "$NOVA_IWD_DIR/=436166c3a9.psk" ]
  [ -f "$NOVA_IWD_DIR/Library.open" ]
  [ "$(stat -c %a "$NOVA_IWD_DIR/Home Net.psk")" = 600 ]
  [ "$(ls "$NOVA_IWD_DIR" | wc -l)" = 3 ]
}

@test "restore: home items land in the new account, owned by it" {
  mkdir -p "$OLD_HOME/.ssh" "$OLD_HOME/.local/state/omarchy-screentime/days"
  echo key >"$OLD_HOME/.ssh/id_ed25519"
  chmod 600 "$OLD_HOME/.ssh/id_ed25519"
  echo 60 >"$OLD_HOME/.local/state/omarchy-screentime/days/2026-10-19.tsv"
  carry ssh history
  restore_carry nova 2>/dev/null
  [ "$(cat "$NOVA_TARGET/home/nova/.ssh/id_ed25519")" = key ]
  [ "$(stat -c %a "$NOVA_TARGET/home/nova/.ssh/id_ed25519")" = 600 ]
  [ -f "$NOVA_TARGET/home/nova/.local/state/nova-screentime/days/2026-10-19.tsv" ]
  [ "$(stat -c %u "$NOVA_TARGET/home/nova/.ssh")" = "$(id -u)" ]
}

@test "restore: pairings and fingerprints only on the computer they came from" {
  mkdir -p "$OLD_ROOT/var/lib/bluetooth/AA:BB/CC:DD" "$OLD_ROOT/var/lib/fprint/andre/synaptics"
  echo paired >"$OLD_ROOT/var/lib/bluetooth/AA:BB/CC:DD/info"
  echo print >"$OLD_ROOT/var/lib/fprint/andre/synaptics/7"
  MACHINE=another-computer carry bluetooth fingerprints
  restore_carry nova 2>/dev/null
  [ ! -e "$NOVA_TARGET/var/lib/bluetooth" ]
  [ ! -e "$NOVA_TARGET/var/lib/fprint" ]
  carry bluetooth fingerprints
  restore_carry nova 2>/dev/null
  [ "$(cat "$NOVA_TARGET/var/lib/bluetooth/AA:BB/CC:DD/info")" = paired ]
  # Renamed to the new account's name.
  [ "$(cat "$NOVA_TARGET/var/lib/fprint/nova/synaptics/7")" = print ]
}

@test "restore: an Omarchy bar layout is renamed, and what Nova lacks dropped" {
  mkdir -p "$OLD_HOME/.config/omarchy" "$NOVA_TARGET/usr/share/nova/shell/plugins"
  cp -r "$REPO_ROOT"/src/shell/plugins/{bar,menu,batterylife} "$NOVA_TARGET/usr/share/nova/shell/plugins/"
  cat >"$OLD_HOME/.config/omarchy/shell.json" <<'EOF'
{"version":1,"idle":{"lock":600,"screensaver":150},"plugins":[{"id":"andrecmdrgb.batterylife","x":1},{"id":"omarchy.voxtype"}],
 "bar":{"position":"top","layout":{"left":[{"id":"omarchy.menu"}],"right":[{"id":"omarchy.tray"},{"id":"omarchy.agents"},{"id":"andrecmdrgb.batterylife","readout":"Time left"}]}}}
EOF
  carry bar
  restore_carry nova 2>/dev/null
  local file=$NOVA_TARGET/home/nova/.config/nova/shell.json
  [ "$(jq -c .bar.layout "$file")" = '{"left":[{"id":"nova.menu"}],"right":[{"id":"nova.tray"},{"id":"nova.batterylife","readout":"Time left"}]}' ]
  [ "$(jq -c .plugins "$file")" = '[{"id":"nova.batterylife","x":1}]' ]
  # Its idle times are kept: Nova has a screensaver too.
  [ "$(jq -c .idle "$file")" = '{"lock":600,"screensaver":150}' ]
  [ "$(jq -r .bar.position "$file")" = top ]
}

@test "restore: a bar layout that is not JSON gives way to Nova's" {
  mkdir -p "$NOVA_TARGET/home/nova/.config/nova"
  echo '{broken' >"$NOVA_TARGET/home/nova/.config/nova/shell.json"
  adopt_shell_config "$NOVA_TARGET/home/nova/.config/nova/shell.json" 2>/dev/null
  [ ! -e "$NOVA_TARGET/home/nova/.config/nova/shell.json" ]
}

@test "restore: a passwordless keyring is queued for the login keyring, an old login keyring kept aside" {
  mkdir -p "$OLD_HOME/.config/google-chrome/Default" "$OLD_HOME/.local/share/keyrings"
  echo cookies >"$OLD_HOME/.config/google-chrome/Default/Cookies"
  echo plain >"$OLD_HOME/.local/share/keyrings/Default_keyring.keyring"
  echo old >"$OLD_HOME/.local/share/keyrings/login.keyring"
  echo Default_keyring >"$OLD_HOME/.local/share/keyrings/default"
  carry chrome
  restore_carry nova 2>/dev/null
  local home=$NOVA_TARGET/home/nova
  [ -f "$home/.config/google-chrome/Default/Cookies" ]
  [ -f "$home/.local/state/nova/keyring-migrate-pending" ]
  [ ! -e "$home/.local/share/keyrings/login.keyring" ]
  [ "$(cat "$home/.local/share/keyrings/carried-login.keyring")" = old ]
  [ "$(cat "$home/.local/share/keyrings/default")" = Default_keyring ]
}

@test "restore: without a keyring there is nothing to migrate" {
  adopt_keyrings "$SCRATCH/none" "$SCRATCH/state"
  [ ! -e "$SCRATCH/state" ]
}

@test "restore: the package list waits in the account for the end of the install" {
  printf 'kicad\nsteam\n' >"$SCRATCH/plan/packages.txt"
  printf 'spotify\n' >"$SCRATCH/plan/aur.txt"
  carry packages
  restore_carry nova 2>/dev/null
  [ "$(cat "$NOVA_TARGET/home/nova/.local/state/nova/carried/packages.txt")" = "$(printf 'kicad\nsteam')" ]
  [ "$(cat "$NOVA_TARGET/home/nova/.local/state/nova/carried/aur.txt")" = spotify ]
}

@test "restore: nothing carried, nothing done" {
  rm -rf "$NOVA_CARRY"
  restore_carry nova
  [ "$(ls -A "$NOVA_TARGET/home/nova")" = "" ]
}

@test "keyfile_value and iwd_name" {
  printf '[wifi]\nssid=A=B\n[wifi-security]\npsk=x\n' >"$SCRATCH/k"
  [ "$(keyfile_value "$SCRATCH/k" wifi ssid)" = "A=B" ]
  [ "$(keyfile_value "$SCRATCH/k" wifi psk)" = "" ]
  [ "$(iwd_name "Home Net_2-g")" = "Home Net_2-g" ]
  [ "$(iwd_name "A=B")" = "=413d42" ]
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

@test "carried_fingerprints: only prints carried from this computer" {
  mkdir -p "$OLD_ROOT/var/lib/fprint/andre"
  echo print >"$OLD_ROOT/var/lib/fprint/andre/7"
  mkdir -p "$OLD_HOME/.ssh"
  echo key >"$OLD_HOME/.ssh/id_ed25519"
  fails carried_fingerprints
  carry ssh
  fails carried_fingerprints
  MACHINE=another-computer carry fingerprints
  fails carried_fingerprints
  carry fingerprints
  carried_fingerprints
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
