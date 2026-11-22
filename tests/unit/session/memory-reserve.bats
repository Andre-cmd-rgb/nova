#!/usr/bin/env bats

# nova-memory-reserve: vm.watermark_scale_factor from the size of the memory,
# written at boot where systemd-sysctl reads it. The gap between the kernel's
# low and min watermarks is 1.25% of memory on a computer up to 8 GB, as Nova
# has always had it, and the same 100 MiB on a larger one, where the share
# kept a gigabyte and more free at rest. Read from a /proc and a /run of the
# test's own.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_PROC=$SCRATCH/proc NOVA_RUN=$SCRATCH/run
  mkdir -p "$NOVA_PROC"
}

teardown() { teardown_scratch; }

TOOL="$REPO_ROOT/data/systemd/nova-memory-reserve"

memory() { printf 'MemTotal:       %d kB\nMemFree: 1 kB\n' "$1" >"$NOVA_PROC/meminfo"; }

factor_for() {
  memory "$1"
  run "$TOOL" --print
  [ "$status" -eq 0 ]
  echo "$output"
}

@test "a computer up to 8 GB keeps the 1.25% it always had" {
  [ "$(factor_for 1994752)" = 125 ]  # 2 GB
  [ "$(factor_for 3999744)" = 125 ]  # the install test's 4 GB
  [ "$(factor_for 7914176)" = 125 ]  # 8 GB, as one reports it
  [ "$(factor_for 8192000)" = 125 ]  # the last size at 125: 100 MiB is 1.25% of 8000 MiB
}

@test "a larger one keeps 100 MiB, not a share" {
  [ "$(factor_for 16108000)" = 64 ]   # 16 GB
  [ "$(factor_for 32555776)" = 31 ]   # the ThinkPad P1's 32 GB
  [ "$(factor_for 65700000)" = 16 ]   # 64 GB
  # The gap those factors make, in MiB, is the same within the rounding.
  for kb in 16108000 32555776 65700000; do
    gap=$((kb * $(factor_for "$kb") / 10000 / 1024))
    [ "$gap" -ge 96 ] && [ "$gap" -le 104 ]
  done
}

@test "never under the kernel's own 0.1%" {
  [ "$(factor_for 131900000)" = 10 ]  # 128 GB
  [ "$(factor_for 527000000)" = 10 ]  # 512 GB
}

@test "the setting is written where systemd-sysctl reads it, whole or not at all" {
  memory 32555776
  run "$TOOL"
  [ "$status" -eq 0 ]
  [ "$(grep -v '^#' "$NOVA_RUN/sysctl.d/90-nova-memory-reserve.conf")" = "vm.watermark_scale_factor = 31" ]
  [ ! -e "$NOVA_RUN/sysctl.d/90-nova-memory-reserve.conf.new" ]
  # A second boot's worth: the file is replaced, not added to.
  memory 7914176
  run "$TOOL"
  [ "$(grep -c watermark_scale_factor "$NOVA_RUN/sysctl.d/90-nova-memory-reserve.conf")" = 1 ]
  [ "$(grep -v '^#' "$NOVA_RUN/sysctl.d/90-nova-memory-reserve.conf")" = "vm.watermark_scale_factor = 125" ]
}

@test "no MemTotal: nothing is written, and the kernel's own setting stays" {
  : >"$NOVA_PROC/meminfo"
  run "$TOOL"
  [ "$status" -ne 0 ]
  [ ! -e "$NOVA_RUN/sysctl.d" ]
}

@test "installed: systemd-sysctl runs it first, and no static file sets the factor after it" {
  make -s -C "$REPO_ROOT" DESTDIR="$SCRATCH/root" install-systemd >/dev/null
  [ -x "$SCRATCH/root/usr/lib/nova/nova-memory-reserve" ]
  grep -qx 'ExecStartPre=-/usr/lib/nova/nova-memory-reserve' \
    "$SCRATCH/root/usr/lib/systemd/system/systemd-sysctl.service.d/10-nova-memory-reserve.conf"
  # A static vm.watermark_scale_factor in Nova's own sysctl.d would be read
  # after the one in /run (systemd-sysctl sorts the names as bytes, and
  # 90-nova.conf comes after 90-nova-memory-reserve.conf) and undo it.
  fails grep -rqE '^[[:space:]]*vm\.watermark_scale_factor' "$SCRATCH/root/usr/lib/sysctl.d"
}

# nova-memory-pressure (src/memory): the full reserve while memory is short.
# Its deciding and its timing are the crate's own tests; here, that it is on.
@test "installed: the pressure watcher starts after the reserve is set, on every computer, and only with a reserve of Nova's to manage" {
  mkdir -p "$SCRATCH/target/release"
  printf '#!/bin/sh\n' >"$SCRATCH/target/release/nova-memory-pressure"
  make -s -C "$REPO_ROOT" DESTDIR="$SCRATCH/root" CARGO_TARGET_DIR="$SCRATCH/target" install-memory >/dev/null
  unit=$SCRATCH/root/usr/lib/systemd/system/nova-memory-pressure.service
  [ -x "$SCRATCH/root/usr/lib/nova/nova-memory-pressure" ]
  [ "$(readlink "$SCRATCH/root/usr/lib/systemd/system/multi-user.target.wants/nova-memory-pressure.service")" = ../nova-memory-pressure.service ]
  grep -qx 'ExecStart=/usr/lib/nova/nova-memory-pressure' "$unit"
  grep -qx 'After=systemd-sysctl.service' "$unit"
  grep -qx 'ConditionPathExists=/run/sysctl.d/90-nova-memory-reserve.conf' "$unit"
  # Ended while the full reserve is in force, it is started again, and finds
  # the mark of its own raise in a directory kept until the next boot.
  grep -qx 'Restart=on-failure' "$unit"
  grep -qx 'RuntimeDirectory=nova-memory-pressure' "$unit"
  grep -qx 'RuntimeDirectoryPreserve=yes' "$unit"
  # It must be able to write the sysctl: nothing here makes /proc/sys read-only.
  fails grep -qE '^(ProtectKernelTunables|ProtectProc|ReadOnlyPaths)=' "$unit"
  # Of root's powers, only what the pressure trigger's one-second window takes.
  grep -qx 'CapabilityBoundingSet=CAP_SYS_RESOURCE' "$unit"
  for protection in PrivateDevices ProtectKernelModules ProtectKernelLogs ProtectControlGroups; do
    grep -qx "$protection=yes" "$unit"
  done
  # Not started where the boot's reserve is the full one already: memory up
  # to the condition's size gets 125 from nova-memory-reserve, a MiB more a
  # lean one.
  limit=$(sed -n 's/^ConditionMemory=>\([0-9]*\)M$/\1/p' "$unit")
  [ -n "$limit" ]
  memory $((limit * 1024))
  [ "$("$TOOL" --print)" -eq 125 ]
  memory $(((limit + 1) * 1024))
  [ "$("$TOOL" --print)" -lt 125 ]
  if command -v systemd-analyze >/dev/null; then
    run systemd-analyze verify --root="$SCRATCH/root" "$unit"
    [[ $output != *"nova-memory-pressure.service:"* ]]
  fi
}
