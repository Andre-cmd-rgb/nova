#!/usr/bin/env bats

# PID 1 arms no hardware watchdog for a restart: systemd's default closes
# /dev/watchdog still running on the way down, and the kernel prints
# "watchdog did not stop!" on the console each time. Read as systemd reads
# its config, from an installed tree.

load ../test_helper

setup() {
  setup_scratch
  make -s -C "$REPO_ROOT" DESTDIR="$SCRATCH/root" install-systemd >/dev/null
}

teardown() { teardown_scratch; }

@test "the restart watchdog is off, in the config systemd reads" {
  command -v systemd-analyze >/dev/null || skip "no systemd-analyze"
  run systemd-analyze cat-config --root="$SCRATCH/root" systemd/system.conf
  [ "$status" -eq 0 ]
  [[ $output == *"/usr/lib/systemd/system.conf.d/10-nova.conf"* ]]
  [ "$(grep -E '^[[:space:]]*RebootWatchdogSec=' <<<"$output" | tail -1)" = "RebootWatchdogSec=off" ]
}

@test "and nothing turns the lockup detectors or the watchdog drivers off" {
  fails grep -rqs 'nowatchdog' "$REPO_ROOT/data/boot"
  fails grep -rqsE 'blacklist +(iTCO_wdt|intel_oc_wdt|sp5100_tco|mei_wdt)' "$REPO_ROOT/data"
}
