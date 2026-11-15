#!/usr/bin/env bats

# The stick's first console: the Wi-Fi networks as iwd lists them, and joining
# one from its screen.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_INSTALLER_SHARE="$REPO_ROOT/installer"
  export NOVA_IWD_DIR="$SCRATCH/iwd"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/installer/iso/airootfs/usr/local/bin/nova-install-start"
  sleep() { :; }
  rfkill() { :; }
}

teardown() { teardown_scratch; }

# What `iwctl station wlan0 get-networks` prints, colours and all.
IWCTL_LIST=$'\n'$'\e[1;90m                               Available networks                             \e[0m\n'\
$'--------------------------------------------------------------------------------\n'\
$'\e[1;90m      Network name                      Security            Signal\e[0m\n'\
$'--------------------------------------------------------------------------------\n'\
$'  \e[1;90m> \e[0m  Home  Wi-Fi                       psk                 \e[1;90m****\e[0m\n'\
$'      Cafe                              open                \e[1;90m***\e[0m*\n'\
$'      eduroam                           8021x               **\n'

@test "wifi_networks: names with spaces, the joined one marked, enterprise ones left out" {
  iwctl() { printf '%s' "$IWCTL_LIST"; }
  run wifi_networks wlan0
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = $'Home  Wi-Fi\tpsk' ]
  [ "${lines[1]}" = $'Cafe\topen' ]
  [ "${#lines[@]}" -eq 2 ]
}

@test "connect_wifi: a network picked from the list, joined with its password, which is never an argument" {
  iwctl() {
    case "$*" in
      *get-networks*) printf '%s' "$IWCTL_LIST" ;;
      *connect*) echo "$*" >>"$SCRATCH/joined" ;;
    esac
  }
  wait_online() { :; }
  stub_gum 0 hunter22
  connect_wifi wlan0 2>/dev/null
  [ "$(cat "$SCRATCH/joined")" = "--dont-ask station wlan0 connect Home  Wi-Fi" ]
  [ "$(cat "$NOVA_IWD_DIR/Home  Wi-Fi.psk")" = "$(printf '[Security]\nPassphrase=hunter22')" ]
  [ "$(stat -c %a "$NOVA_IWD_DIR/Home  Wi-Fi.psk")" = 600 ]
  grep -q 'Cafe  (open)' "$GUM_LOG"
}

@test "connect_wifi: a wrong password asks again; going on without a network is a choice" {
  iwctl() {
    case "$*" in
      *get-networks*) printf '%s' "$IWCTL_LIST" ;;
      *connect*) return 1 ;;
    esac
  }
  stub_gum 0 wrong none
  run connect_wifi wlan0
  [ "$status" -eq 1 ]
  [[ $output == *"Could not connect to Home  Wi-Fi."* ]]
  [ "$(gum_replies_left)" = 0 ]
  [ -z "$(ls -A "$NOVA_IWD_DIR")" ]
}

@test "connect_wifi: an open network needs no password, a hidden one is joined by name" {
  iwctl() {
    case "$*" in
      *get-networks*) printf '%s' "$IWCTL_LIST" ;;
      *connect*) echo "$*" >>"$SCRATCH/joined" ;;
    esac
  }
  wait_online() { :; }
  stub_gum 1
  connect_wifi wlan0 2>/dev/null
  stub_gum hidden Attic secret
  connect_wifi wlan0 2>/dev/null
  [ "$(sed -n 1p "$SCRATCH/joined")" = "--dont-ask station wlan0 connect Cafe" ]
  [ "$(sed -n 2p "$SCRATCH/joined")" = "--dont-ask station wlan0 connect-hidden Attic" ]
  [ "$(cat "$NOVA_IWD_DIR/Attic.psk")" = "$(printf '[Security]\nPassphrase=secret\n\n[Settings]\nHidden=true')" ]
}

@test "iwd_name: a plain name as it is, any other in hex" {
  [ "$(iwd_name "Home Net_2-g")" = "Home Net_2-g" ]
  [ "$(iwd_name "A=B")" = "=413d42" ]
}

@test "iwd_value: a password reaches iwd as it was typed" {
  [ "$(iwd_value 'plain pass')" = 'plain pass' ]
  [ "$(iwd_value ' leading')" = '\sleading' ]
  [ "$(iwd_value 'back\slash\s')" = 'back\\slash\\s' ]
  [ "$(iwd_value $'tab\there')" = 'tab\there' ]
}

@test "iwd_to_networkmanager: the stick's networks as NetworkManager files, 600, passphrase as typed" {
  iwd_write_psk "Home Net" 'p\ss	word'
  iwd_write_psk "A=B" secret hidden
  mkdir -p "$NOVA_IWD_DIR"
  : >"$NOVA_IWD_DIR/Cafe.open"
  printf '[Security]\nPreSharedKey=abcd\n' >"$NOVA_IWD_DIR/Office.psk"
  iwd_to_networkmanager "$SCRATCH/nm"
  [ "$(stat -c %a "$SCRATCH/nm/Home Net.nmconnection")" = 600 ]
  grep -qx 'ssid=Home Net' "$SCRATCH/nm/Home Net.nmconnection"
  grep -qxF 'psk=p\\ss\tword' "$SCRATCH/nm/Home Net.nmconnection"
  grep -qx 'hidden=false' "$SCRATCH/nm/Home Net.nmconnection"
  grep -qx 'ssid=65;61;66;' "$SCRATCH/nm/=413d42.nmconnection"
  grep -qx 'id=A=B' "$SCRATCH/nm/=413d42.nmconnection"
  grep -qx 'hidden=true' "$SCRATCH/nm/=413d42.nmconnection"
  ! grep -q 'wifi-security' "$SCRATCH/nm/Cafe.nmconnection"
  # No passphrase to give NetworkManager: left for the person to join again.
  [ ! -e "$SCRATCH/nm/Office.nmconnection" ]
  grep -qx 'uuid=[0-9a-f-]\{36\}' "$SCRATCH/nm/Cafe.nmconnection"
}

@test "iwd_to_networkmanager: no networks joined, no files" {
  iwd_to_networkmanager "$SCRATCH/nm"
  [ ! -e "$SCRATCH/nm" ]
}

@test "where Nova goes: asked only with a USB disk beside the stick to put it on" {
  mkdir -p "$SCRATCH/bin"
  printf '#!/bin/bash\n[[ $1 == --portable-disks ]] && cat "%s/portable-disks"\n' "$SCRATCH" >"$SCRATCH/bin/nova-install"
  chmod +x "$SCRATCH/bin/nova-install"
  PATH="$SCRATCH/bin:$PATH"
  : >"$SCRATCH/portable-disks"
  stub_gum
  where_nova_goes 2>/dev/null
  [ "$WHERE" = install ]
  fails grep -q 'Where does Nova go' "$GUM_LOG"
  echo /dev/sdb >"$SCRATCH/portable-disks"
  stub_gum portable
  where_nova_goes 2>/dev/null
  [ "$WHERE" = portable ]
  grep -q 'Where does Nova go' "$GUM_LOG"
  stub_gum '!1'
  fails where_nova_goes 2>/dev/null
}

@test "run_install: a stop says where the log is, but not after a computer Nova cannot go on" {
  mkdir -p "$SCRATCH/bin"
  printf '#!/bin/bash\necho "$*" >>"%s/ran"\nexit "$(cat "%s/status")"\n' "$SCRATCH" "$SCRATCH" >"$SCRATCH/bin/nova-install"
  chmod +x "$SCRATCH/bin/nova-install"
  PATH="$SCRATCH/bin:$PATH"
  systemctl() { echo "systemctl $*" >>"$SCRATCH/ran"; }
  WHERE=install
  echo 1 >"$SCRATCH/status"
  run run_install
  [[ $output == *"The install stopped. Its log is /var/log/nova-install.log."* ]]
  # Secure Boot on (3), or Ctrl+C (130): nova-install has said why.
  echo 3 >"$SCRATCH/status"
  run run_install
  [ -z "$output" ]
  echo 130 >"$SCRATCH/status"
  run run_install
  [ -z "$output" ]
  WHERE=portable
  echo 1 >"$SCRATCH/status"
  run run_install
  [[ $output == *"Nova was not put on the USB disk."* ]]
  [ "$(tail -n 1 "$SCRATCH/ran")" = --portable ]
  echo 0 >"$SCRATCH/status"
  stub_gum 0
  run_install 2>/dev/null
  [ "$(tail -n 1 "$SCRATCH/ran")" = "systemctl reboot" ]
}

@test "get_online: with no link, straight to Wi-Fi; with one, the address is waited for" {
  export NOVA_NET_DIR=$SCRATCH/net
  NET_DIR=$NOVA_NET_DIR
  mkdir -p "$NET_DIR/lo" "$NET_DIR/enp1s0" "$NET_DIR/wlan0"
  echo 1 >"$NET_DIR/lo/carrier"
  echo 0 >"$NET_DIR/enp1s0/carrier"
  # A link that is down has no carrier to read.
  screen() { :; }
  ui_note() { :; }
  wifi_device() { echo wlan0; }
  connect_wifi() { echo "wifi $1"; }
  wait_online() { echo "waited $1"; return 1; }
  run get_online
  [ "$output" = "wifi wlan0" ]
  echo 1 >"$NET_DIR/enp1s0/carrier"
  run get_online
  [ "${lines[0]}" = "waited 8" ]
  [ "${lines[1]}" = "wifi wlan0" ]
  wait_online() { return 0; }
  run get_online
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
