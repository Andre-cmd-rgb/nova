#!/usr/bin/env bats

# The connectivity policy is a package-owned NetworkManager drop-in. Nothing
# in this test loads it into the running NetworkManager.

load ../test_helper

setup() { setup_scratch; }
teardown() { teardown_scratch; }

@test "the network install owns the connectivity policy under usr/lib" {
  run make -C "$REPO_ROOT" -f data/network/install.mk install-network \
    DESTDIR="$SCRATCH/root" PREFIX=/usr NOVA_BIN=/usr/lib/nova/bin
  [ "$status" -eq 0 ]
  conf=$SCRATCH/root/usr/lib/NetworkManager/conf.d/30-nova-connectivity.conf
  [ -f "$conf" ]
  [ ! -e "$SCRATCH/root/etc/NetworkManager" ]
  cmp "$REPO_ROOT/data/network/NetworkManager/30-nova-connectivity.conf" "$conf"
  [ "$(stat -c %a "$conf")" = 644 ]
  [ "$(sed '/^#/d; /^$/d' "$conf")" = "$(printf '[connectivity]\nenabled=true\nuri=http://ping.archlinux.org/nm-check.txt\nresponse=NetworkManager is online\ninterval=300')" ]
}
