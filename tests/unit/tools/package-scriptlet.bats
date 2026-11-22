#!/usr/bin/env bats

# packaging/nova/nova.install: what pacman runs around an upgrade of nova.
# Here on a stand-in for / (NOVA_ROOT), with systemctl, getent and setpriv
# stubs that note each call; nothing of the computer it runs on is touched.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_ROOT=$SCRATCH/root CALLS=$SCRATCH/calls ACTIVE=$SCRATCH/active
  mkdir -p "$NOVA_ROOT" "$SCRATCH/bin"
  : >"$CALLS"
  cat >"$SCRATCH/bin/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >>"$CALLS"
[[ $1 == list-units && -f $ACTIVE ]] && cat "$ACTIVE"
exit 0
STUB
  # The accounts: two people, a system account and nobody.
  cat >"$SCRATCH/passwd" <<EOF
root:x:0:0::/root:/bin/bash
andre:x:1000:1000:Andre:$SCRATCH/home/andre:/bin/bash
guest:x:1001:1001::$SCRATCH/home/guest:/bin/bash
colord:x:977:977::$SCRATCH/home/colord:/usr/bin/nologin
nobody:x:65534:65534::/:/usr/bin/nologin
EOF
  printf '#!/bin/bash\n[[ $1 == passwd ]] && cat "%s"\n' "$SCRATCH/passwd" >"$SCRATCH/bin/getent"
  # As the account: noted, then run as this one.
  cat >"$SCRATCH/bin/setpriv" <<'STUB'
#!/bin/bash
echo "setpriv $*" >>"$CALLS"
while [[ $1 == --* ]]; do shift; done
exec "$@"
STUB
  chmod +x "$SCRATCH/bin/"*
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

pre_upgrade() {
  run sh -c '. "$1"; pre_upgrade 1.0.0rc.15-1 1.0.0rc.14-1' _ "$REPO_ROOT/packaging/nova/nova.install"
}

# A computer on rc.14: AirDrop's units installed, the doorbell switched on
# for andre (its link and its wake unit's four), what AirDrop keeps in /run
# and in andre's and guest's homes and runtime folders, and beside them what
# is not AirDrop's.
rc14() {
  local units=$NOVA_ROOT/usr/lib/systemd/system etc=$NOVA_ROOT/etc/systemd/system target
  mkdir -p "$units"
  : >"$units/nova-airdrop@.service"
  : >"$units/nova-airdrop-bell@.service"
  : >"$units/nova-airdrop-bell-wake@.service"
  mkdir -p "$etc/user@1000.service.wants" "$etc/multi-user.target.wants"
  ln -s /usr/lib/systemd/system/nova-airdrop-bell@.service "$etc/user@1000.service.wants/nova-airdrop-bell@1000.service"
  for target in suspend hibernate hybrid-sleep suspend-then-hibernate; do
    mkdir -p "$etc/$target.target.wants"
    ln -s /usr/lib/systemd/system/nova-airdrop-bell-wake@.service "$etc/$target.target.wants/nova-airdrop-bell-wake@1000.service"
  done
  ln -s /usr/lib/systemd/system/nova-powerd.service "$etc/multi-user.target.wants/nova-powerd.service"
  write_file "$NOVA_ROOT/run/nova-airdrop/wifi" wlan0
  write_file "$NOVA_ROOT/run/nova-airdrop/last" 'The Wi-Fi is back.'
  write_file "$SCRATCH/home/andre/.local/state/nova/airdrop/phones" 'a1b2 c3d4 e5f6 0718'
  write_file "$SCRATCH/home/andre/.local/state/nova/airdrop/identity.pem" key
  write_file "$SCRATCH/home/andre/.local/state/nova/monitors.json" '{}'
  write_file "$SCRATCH/home/guest/.local/state/nova/airdrop/identity.pem" key
  write_file "$SCRATCH/home/colord/.local/state/nova/airdrop/phones" 'not a person'
  local run=$NOVA_ROOT/run/user/1000/nova
  write_file "$run/airdrop.sock"
  write_file "$run/airdrop-bell.sock"
  write_file "$run/airdrop-bell.monitors" 3
  write_file "$run/airdrop-pictures/7-1.jpg"
  write_file "$run/dictation.sock"
}

@test "from a release with AirDrop on: the doorbell stops, then the receiver, while their programs are there" {
  rc14
  echo 'nova-airdrop@1000.service loaded active running AirDrop' >"$ACTIVE"
  pre_upgrade
  [ "$status" -eq 0 ]
  [ "$output" = "AirDrop is on, and this release has none: it ends now, and gives the Wi-Fi back to the network." ]
  [ "$(cat "$CALLS" | grep '^systemctl')" = "systemctl list-units --plain --no-legend --state=active,activating,deactivating nova-airdrop@*.service
systemctl stop nova-airdrop-bell-wake@*.service nova-airdrop-bell@*.service
systemctl stop nova-airdrop@*.service
systemctl daemon-reload
systemctl reset-failed nova-airdrop@*.service nova-airdrop-bell@*.service nova-airdrop-bell-wake@*.service" ]
}

@test "from a release with AirDrop: no link of its doorbell is left, and nothing else's goes" {
  rc14
  pre_upgrade
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ -z "$(find "$NOVA_ROOT/etc" -name 'nova-airdrop*')" ]
  [ -L "$NOVA_ROOT/etc/systemd/system/multi-user.target.wants/nova-powerd.service" ]
  grep -qx 'systemctl daemon-reload' "$CALLS"
}

@test "from a release with AirDrop: what it kept in /run and in each person's account goes, removed as that account" {
  rc14
  pre_upgrade
  [ "$status" -eq 0 ]
  [ ! -e "$NOVA_ROOT/run/nova-airdrop" ]
  [ ! -e "$SCRATCH/home/andre/.local/state/nova/airdrop" ] && [ ! -e "$SCRATCH/home/guest/.local/state/nova/airdrop" ]
  [ -z "$(find "$NOVA_ROOT/run/user" -name 'airdrop*')" ]
  # What is not AirDrop's stays, and a system account's is no person's.
  [ -f "$SCRATCH/home/andre/.local/state/nova/monitors.json" ] && [ -e "$NOVA_ROOT/run/user/1000/nova/dictation.sock" ]
  [ -f "$SCRATCH/home/colord/.local/state/nova/airdrop/phones" ]
  [ "$(grep '^setpriv' "$CALLS")" = "setpriv --reuid=1000 --regid=1000 --init-groups rm -rf -- $SCRATCH/home/andre/.local/state/nova/airdrop
setpriv --reuid=1000 --regid=1000 --init-groups rm -rf -- $NOVA_ROOT/run/user/1000/nova/airdrop.sock
setpriv --reuid=1000 --regid=1000 --init-groups rm -rf -- $NOVA_ROOT/run/user/1000/nova/airdrop-bell.sock
setpriv --reuid=1000 --regid=1000 --init-groups rm -rf -- $NOVA_ROOT/run/user/1000/nova/airdrop-bell.monitors
setpriv --reuid=1000 --regid=1000 --init-groups rm -rf -- $NOVA_ROOT/run/user/1000/nova/airdrop-pictures
setpriv --reuid=1001 --regid=1001 --init-groups rm -rf -- $SCRATCH/home/guest/.local/state/nova/airdrop" ]
}

@test "from a release with AirDrop off and its doorbell never on: it stops nothing that runs, says nothing, reloads nothing" {
  rc14
  find "$NOVA_ROOT/etc" -name 'nova-airdrop*' -delete
  pre_upgrade
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  fails grep -qx 'systemctl daemon-reload' "$CALLS"
  [ ! -e "$SCRATCH/home/andre/.local/state/nova/airdrop" ]
}

@test "from a release without AirDrop: nothing is asked, nothing is removed" {
  rc14
  rm "$NOVA_ROOT/usr/lib/systemd/system/nova-airdrop@.service"
  pre_upgrade
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
  [ -e "$NOVA_ROOT/run/nova-airdrop/wifi" ] && [ -e "$SCRATCH/home/andre/.local/state/nova/airdrop/phones" ]
}

@test "not as root and with no stand-in for /, it does nothing at all" {
  rc14
  unset NOVA_ROOT
  pre_upgrade
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}
