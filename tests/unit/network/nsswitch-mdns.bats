#!/usr/bin/env bats

# nova-nsswitch-mdns: mdns_minimal in the hosts line, once, after mymachines
# and before resolve, so a printer's .local name resolves through Avahi.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_NSSWITCH=$SCRATCH/nsswitch.conf
  helper=$REPO_ROOT/data/network/bin/nova-nsswitch-mdns
}

teardown() { teardown_scratch; }

@test "Arch's hosts line gets mdns_minimal before resolve, and only once" {
  printf 'passwd: files systemd\nhosts: mymachines resolve [!UNAVAIL=return] files myhostname dns\nnetworks: files\n' >"$NOVA_NSSWITCH"
  "$helper"
  "$helper"
  [ "$(sed -n 2p "$NOVA_NSSWITCH")" = 'hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns' ]
  [ "$(sed -n 1p "$NOVA_NSSWITCH")" = 'passwd: files systemd' ]
  [ "$(sed -n 3p "$NOVA_NSSWITCH")" = 'networks: files' ]
}

@test "a hosts line without mymachines gets it first" {
  printf 'hosts: files dns\n' >"$NOVA_NSSWITCH"
  "$helper"
  [ "$(cat "$NOVA_NSSWITCH")" = 'hosts: mdns_minimal [NOTFOUND=return] files dns' ]
}

@test "a hosts line with mdns already, or none at all, is left alone" {
  printf 'hosts: files mdns4_minimal [NOTFOUND=return] dns\n' >"$NOVA_NSSWITCH"
  cp "$NOVA_NSSWITCH" "$SCRATCH/before"
  "$helper"
  cmp "$SCRATCH/before" "$NOVA_NSSWITCH"
  printf 'passwd: files\n' >"$NOVA_NSSWITCH"
  "$helper"
  [ "$(cat "$NOVA_NSSWITCH")" = 'passwd: files' ]
  rm "$NOVA_NSSWITCH"
  run "$helper"
  [ "$status" -eq 0 ]
}

@test "resolved answers no LLMNR and leaves mDNS to Avahi" {
  conf=$REPO_ROOT/data/network/resolved/10-nova.conf
  grep -qx '\[Resolve\]' "$conf"
  grep -qx 'LLMNR=no' "$conf"
  grep -qx 'MulticastDNS=no' "$conf"
}
