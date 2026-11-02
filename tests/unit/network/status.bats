#!/usr/bin/env bats

# nova-network-status, the line the bar's network widget reads, against stubs
# of ip, nmcli and iw. A Wi-Fi route needs a wireless interface in /sys, so
# those tests take this computer's and are skipped where there is none.

load ../test_helper

setup() {
  setup_scratch
  mkdir -p "$SCRATCH/bin"
  wifi=""
  for dir in /sys/class/net/*/wireless; do
    if [[ -d $dir ]]; then
      wifi=${dir%/wireless}
      wifi=${wifi##*/}
      break
    fi
  done
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name body
  printf '#!/bin/bash\n%s\n' "$2" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

route_via() { # device
  stub ip "[[ \$1 == route ]] && echo '1.1.1.1 via 192.168.1.1 dev $1 src 192.168.1.42 uid 1000'"
}

status() { "$REPO_ROOT/src/cli/bin/nova-network-status" "$@"; }

@test "a network whose name has a backslash and a colon is named whole" {
  [[ -n $wifi ]] || skip "no wireless interface on this computer"
  route_via "$wifi"
  # -e no leaves the values as they are; -t would escape the : and the \.
  stub nmcli 'case "$*" in
    "-e no -g GENERAL.STATE,GENERAL.CONNECTION dev show "*) printf "100 (connected)\nCaf\\\\e:Gast\n" ;;
    *"dev wifi list"*) printf " :100\n*:77\n :55\n" ;;
  esac'
  stub iw 'printf "Connected to 00:11:22:33:44:55 (on x)\n\tSSID: Caf\\\\e:Gast\n\tfreq: 5745.0\n\tsignal: -60 dBm\n"'
  run status
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'wifi\tCaf\\e:Gast\t77\t5745.0')" ]
}

@test "Wi-Fi that is not connected yet is disconnected" {
  [[ -n $wifi ]] || skip "no wireless interface on this computer"
  route_via "$wifi"
  stub nmcli 'printf "30 (disconnected)\n\n"'
  stub iw 'exit 1'
  run status
  [ "$output" = "$(printf 'disconnected\t\t\t')" ]
}

@test "a route through a wired device is ethernet, and none is disconnected" {
  route_via lo
  run status
  [ "$output" = "$(printf 'ethernet\tlo\t\t')" ]
  stub ip 'exit 2'
  run status
  [ "$output" = "$(printf 'disconnected\t\t\t')" ]
}

@test "with no route out the verbose reading fails" {
  stub ip 'exit 2'
  run status --verbose
  [ "$status" -eq 1 ]
  run status --bogus
  [ "$status" -eq 2 ]
}
