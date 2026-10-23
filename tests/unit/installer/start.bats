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

@test "iwd_value: a password reaches iwd as it was typed" {
  [ "$(iwd_value 'plain pass')" = 'plain pass' ]
  [ "$(iwd_value ' leading')" = '\sleading' ]
  [ "$(iwd_value 'back\slash\s')" = 'back\\slash\\s' ]
  [ "$(iwd_value $'tab\there')" = 'tab\there' ]
}
