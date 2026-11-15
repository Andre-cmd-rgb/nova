#!/usr/bin/env bats

# nova-wireless-regdom: the time zone's country taken in
# /etc/conf.d/wireless-regdom, in place of its commented line, once; a
# country set by hand, or a zone of no country, left alone.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_REGDOM_CONF=$SCRATCH/wireless-regdom
  export NOVA_LOCALTIME=$SCRATCH/localtime
  export NOVA_ZONE_TAB=$SCRATCH/zone.tab
  helper=$REPO_ROOT/data/network/bin/nova-wireless-regdom
  printf '#WIRELESS_REGDOM="DE"\n#WIRELESS_REGDOM="IT"\n#WIRELESS_REGDOM="US"\n' >"$NOVA_REGDOM_CONF"
  printf '# comment\nIT\t+4154+01229\tEurope/Rome\nUS\t+404251-0740023\tAmerica/New_York\tEastern (most areas)\n' >"$NOVA_ZONE_TAB"
}

teardown() { teardown_scratch; }

zone() { ln -sfn "$1" "$NOVA_LOCALTIME"; }

@test "the zone's country is taken in its own line, and only once" {
  zone /usr/share/zoneinfo/Europe/Rome
  "$helper"
  "$helper"
  [ "$(cat "$NOVA_REGDOM_CONF")" = "$(printf '#WIRELESS_REGDOM="DE"\nWIRELESS_REGDOM="IT"\n#WIRELESS_REGDOM="US"')" ]
}

@test "a relative link, and a country with no line of its own" {
  zone ../usr/share/zoneinfo/America/New_York
  printf '# none listed\n' >"$NOVA_REGDOM_CONF"
  "$helper"
  [ "$(tail -n 1 "$NOVA_REGDOM_CONF")" = 'WIRELESS_REGDOM="US"' ]
}

@test "a country set by hand, a zone of no country, or no file: nothing changes" {
  zone /usr/share/zoneinfo/Europe/Rome
  printf 'WIRELESS_REGDOM="DE"\n' >"$NOVA_REGDOM_CONF"
  "$helper"
  [ "$(cat "$NOVA_REGDOM_CONF")" = 'WIRELESS_REGDOM="DE"' ]
  printf '#WIRELESS_REGDOM="IT"\n' >"$NOVA_REGDOM_CONF"
  zone /usr/share/zoneinfo/UTC
  "$helper"
  [ "$(cat "$NOVA_REGDOM_CONF")" = '#WIRELESS_REGDOM="IT"' ]
  rm "$NOVA_LOCALTIME"
  run "$helper"
  [ "$status" -eq 0 ]
  rm "$NOVA_REGDOM_CONF"
  run "$helper"
  [ "$status" -eq 0 ]
}
