#!/usr/bin/env bats

# nova patch and its root half, against a scratch /etc and /var/lib, a fake
# /sys (this computer's serial numbers) and /proc (the command line and the
# memory test's total), with pkexec, limine-update, systemctl and udevadm
# stubbed.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_ROOT=$SCRATCH/root NOVA_SYS=$SCRATCH/sys NOVA_PROC=$SCRATCH/proc CALLS=$SCRATCH/calls
  export NOVA_PATCH_APPLY=$REPO_ROOT/src/patch/bin/nova-patch-apply
  mkdir -p "$SCRATCH/bin" "$NOVA_ROOT/etc/limine-entry-tool.d" "$NOVA_PROC"
  write_file "$NOVA_SYS/class/dmi/id/product_uuid" $'4c4c4544-0051-3010-8052-b4c04f4e4d32\n'
  write_file "$NOVA_SYS/class/dmi/id/product_serial" $'PF3XYZ12\n'
  : >"$CALLS"
  printf '#!/bin/bash\nexec "$@"\n' >"$SCRATCH/bin/pkexec"
  chmod +x "$SCRATCH/bin/pkexec"
  stub limine-update
  stub systemctl
  stub udevadm
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s${*:+ $*}" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

nova_patch() { "$REPO_ROOT/src/patch/bin/nova-patch" "$@"; }
apply() { "$NOVA_PATCH_APPLY" "$@"; }

this_machine() { printf '%s' '4c4c4544-0051-3010-8052-b4c04f4e4d32/PF3XYZ12///' | sha256sum | cut -c1-16; }

# A patch folder of one file: make <folder> <machine> <path under etc> [content]
make_patch() {
  write_file "$1/patch" "description=Fixes ${1##*/}
machine=$2
"
  write_file "$1/etc/$3" "${4:-options btusb enable_autosuspend=0}"
}

etc() { cat "$NOVA_ROOT/etc/$1"; }

@test "a patch made by hand goes into /etc, for this computer, and its boot entries are rebuilt" {
  make_patch "$SCRATCH/mine/bluetooth" this modprobe.d/90-nova-patch-bluetooth.conf
  run nova_patch add "$SCRATCH/mine/bluetooth"
  [ "$status" -eq 0 ]
  [[ $output == *"Added bluetooth: Fixes bluetooth"* ]]
  [[ $output == *"+ /etc/modprobe.d/90-nova-patch-bluetooth.conf"* ]]
  [ "$(etc modprobe.d/90-nova-patch-bluetooth.conf)" = "options btusb enable_autosuspend=0" ]
  grep -qx "machine=$(this_machine)" "$NOVA_ROOT/etc/nova/patches/bluetooth/patch"
  [ "$(cat "$NOVA_ROOT/var/lib/nova/patch-files")" = "modprobe.d/90-nova-patch-bluetooth.conf" ]
  grep -qx 'limine-update' "$CALLS"
  [ -z "$(find "$NOVA_ROOT/etc/nova/patches" -name '.add.*')" ]
  run nova_patch
  [ "$output" = "$(printf 'bluetooth, on\n    Fixes bluetooth')" ]
}

@test "a patch holds only files, each named after it" {
  make_patch "$SCRATCH/mine/bluetooth" this modprobe.d/btusb.conf
  run nova_patch add "$SCRATCH/mine/bluetooth"
  [ "$status" -eq 1 ]
  [[ $output == *"etc/modprobe.d/btusb.conf: each file's name holds nova-patch-bluetooth"* ]]

  make_patch "$SCRATCH/link/sudo" this sudoers.d/nova-patch-sudo-x
  ln -s /etc/shadow "$SCRATCH/link/sudo/etc/sudoers.d/nova-patch-sudo"
  run nova_patch add "$SCRATCH/link/sudo"
  [ "$status" -eq 1 ]
  [[ $output == *"a link or a device"* ]]

  make_patch "$SCRATCH/odd/Odd" this modprobe.d/nova-patch-Odd.conf
  run nova_patch add "$SCRATCH/odd/Odd"
  [ "$status" -eq 1 ]

  [ -z "$(ls -A "$NOVA_ROOT/etc/nova/patches")" ]
  [ ! -e "$NOVA_ROOT/etc/modprobe.d" ]
  [ ! -s "$CALLS" ]
}

@test "a patch for another computer is kept, but off" {
  make_patch "$SCRATCH/mine/bluetooth" 0123456789abcdef modprobe.d/90-nova-patch-bluetooth.conf
  run nova_patch add "$SCRATCH/mine/bluetooth"
  [ "$status" -eq 0 ]
  [ ! -e "$NOVA_ROOT/etc/modprobe.d/90-nova-patch-bluetooth.conf" ]
  run nova_patch
  [ "${lines[0]}" = "bluetooth, off: it was made for another computer" ]
}

@test "a patch never replaces a file it did not put there, nor another patch's" {
  write_file "$NOVA_ROOT/etc/modprobe.d/90-nova-patch-bluetooth.conf" "mine"
  make_patch "$SCRATCH/mine/bluetooth" this modprobe.d/90-nova-patch-bluetooth.conf
  run nova_patch add "$SCRATCH/mine/bluetooth"
  [ "$status" -eq 0 ]
  [ "$(etc modprobe.d/90-nova-patch-bluetooth.conf)" = "mine" ]
  run nova_patch
  [ "${lines[0]}" = "bluetooth, off: /etc/modprobe.d/90-nova-patch-bluetooth.conf is there already, and not from a patch" ]

  make_patch "$SCRATCH/mine/bt" this modprobe.d/91-nova-patch-bt-wake.conf one
  make_patch "$SCRATCH/mine/bt-wake" any modprobe.d/91-nova-patch-bt-wake.conf two
  run nova_patch add "$SCRATCH/mine/bt" "$SCRATCH/mine/bt-wake"
  [ "$(etc modprobe.d/91-nova-patch-bt-wake.conf)" = "one" ]
  run nova_patch
  [[ $output == *"bt-wake, off: /etc/modprobe.d/91-nova-patch-bt-wake.conf is patch bt's too"* ]]
}

@test "removing a patch takes what it put in /etc out" {
  make_patch "$SCRATCH/mine/bluetooth" this modprobe.d/90-nova-patch-bluetooth.conf
  make_patch "$SCRATCH/mine/wake" this udev/rules.d/90-nova-patch-wake.rules 'ACTION=="add"'
  nova_patch add "$SCRATCH/mine/bluetooth" "$SCRATCH/mine/wake"
  : >"$CALLS"
  run nova_patch remove bluetooth
  [ "$status" -eq 0 ]
  [ ! -e "$NOVA_ROOT/etc/modprobe.d/90-nova-patch-bluetooth.conf" ]
  [ -e "$NOVA_ROOT/etc/udev/rules.d/90-nova-patch-wake.rules" ]
  [ ! -e "$NOVA_ROOT/etc/nova/patches/bluetooth" ]
  [ "$(cat "$CALLS")" = "limine-update" ]
  run nova_patch remove nothing
  [ "$status" -eq 1 ]
}

@test "applying again changes nothing, and rebuilds nothing, when nothing changed" {
  make_patch "$SCRATCH/mine/wake" this udev/rules.d/90-nova-patch-wake.rules 'ACTION=="add"'
  nova_patch add "$SCRATCH/mine/wake"
  grep -qx 'udevadm control --reload' "$CALLS"
  : >"$CALLS"
  run nova_patch apply
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$CALLS" ]
  printf 'ACTION=="change"' >"$NOVA_ROOT/etc/nova/patches/wake/etc/udev/rules.d/90-nova-patch-wake.rules"
  run nova_patch apply
  [ "$(etc udev/rules.d/90-nova-patch-wake.rules)" = 'ACTION=="change"' ]
}

@test "export, then add the zip, brings the same patches back" {
  make_patch "$SCRATCH/mine/bluetooth" this modprobe.d/90-nova-patch-bluetooth.conf
  make_patch "$SCRATCH/mine/wake" any udev/rules.d/90-nova-patch-wake.rules 'ACTION=="add"'
  write_file "$SCRATCH/mine/wake/README.md" "Why it wakes."
  nova_patch add "$SCRATCH/mine/bluetooth" "$SCRATCH/mine/wake"
  run nova_patch export "$SCRATCH/patches.zip"
  [ "$status" -eq 0 ]
  [[ $output == "Exported bluetooth wake to $SCRATCH/patches.zip."* ]]
  nova_patch remove bluetooth wake
  [ ! -e "$NOVA_ROOT/etc/modprobe.d/90-nova-patch-bluetooth.conf" ]

  run nova_patch add "$SCRATCH/patches.zip"
  [ "$status" -eq 0 ]
  [ "$(etc modprobe.d/90-nova-patch-bluetooth.conf)" = "options btusb enable_autosuspend=0" ]
  [ "$(etc udev/rules.d/90-nova-patch-wake.rules)" = 'ACTION=="add"' ]
  [ "$(cat "$NOVA_ROOT/etc/nova/patches/wake/README.md")" = "Why it wakes." ]
  grep -qx "machine=$(this_machine)" "$NOVA_ROOT/etc/nova/patches/bluetooth/patch"
  grep -qx "machine=any" "$NOVA_ROOT/etc/nova/patches/wake/patch"
}

@test "a portable Nova takes no patches, and gives back those it had" {
  make_patch "$SCRATCH/mine/bluetooth" this modprobe.d/90-nova-patch-bluetooth.conf
  nova_patch add "$SCRATCH/mine/bluetooth"
  write_file "$NOVA_ROOT/etc/nova/portable"
  run nova_patch add "$SCRATCH/mine/bluetooth"
  [ "$status" -eq 1 ]
  run nova_patch apply
  [ ! -e "$NOVA_ROOT/etc/modprobe.d/90-nova-patch-bluetooth.conf" ]
  run nova_patch ram test
  [ "$status" -eq 1 ]
}

@test "no patches: says how to make one" {
  run nova_patch
  [ "$status" -eq 0 ]
  [[ $output == "No patches on this computer."* ]]
}

# The memory patch.

ram_conf() { cat "$NOVA_ROOT/etc/limine-entry-tool.d/85-nova-patch-ram.conf"; }
ram_description() { sed -n 's/^description=//p' "$NOVA_ROOT/etc/nova/patches/ram/patch"; }

# A start with the memory test on its command line, which kept <KiB> and
# logged the lines given.
tested_start() { # <KiB> [log line...]
  echo 'root=PARTUUID=x rw quiet memtest=4' >"$NOVA_PROC/cmdline"
  printf 'MemTotal:       32555792 kB\nEarlyMemtestBad:   %5s kB\n' "$1" >"$NOVA_PROC/meminfo"
  {
    echo 'early_memtest: # of tests: 4'
    echo '  0x0000000000100000 - 0x0000000001000000 pattern aaaaaaaaaaaaaaaa'
    printf '%s\n' "${@:2}"
  } >"$SCRATCH/kernel.log"
  export NOVA_KERNEL_LOG=$SCRATCH/kernel.log
}

@test "nova patch ram test puts the memory test on the next start's command line" {
  run nova_patch ram test
  [ "$status" -eq 0 ]
  grep -qx 'KERNEL_CMDLINE\[default\]+=" memtest=4"' "$NOVA_ROOT/etc/limine-entry-tool.d/85-nova-patch-ram-test.conf"
  grep -qx 'limine-update' "$CALLS"
  [ "$(ram_description)" = "Tests the memory at the next start" ]
  [ -s "$NOVA_ROOT/etc/nova/patches/ram/README.md" ]
}

@test "the start that runs the test keeps the bad spots it found out of use, a page each" {
  nova_patch ram test
  tested_start 1 \
    '  0000000000000000 bad mem addr 0x00000001d4e1a008 - 0x00000001d4e1a010 reserved' \
    '  5555555555555555 bad mem addr 0x00000001d4e1a008 - 0x00000001d4e1a010 reserved' \
    '  0000000000000000 bad mem addr 0x0000000412345678 - 0x0000000412345680 reserved'
  : >"$CALLS"
  run apply ram-finish
  [ "$status" -eq 0 ]
  [ "$(ram_conf | grep -v '^#')" = "$(printf '%s\n' 'KERNEL_CMDLINE[default]+=" memmap=4K$0x1d4e1a000"' 'KERNEL_CMDLINE[default]+=" memmap=4K$0x412345000"')" ]
  [ ! -e "$NOVA_ROOT/etc/limine-entry-tool.d/85-nova-patch-ram-test.conf" ]
  [ "$(ram_description)" = "Keeps 2 bad spots in memory (8 KiB) out of use; the memory test of $(date +%F) found 2" ]
  [ "$(cat "$CALLS")" = "limine-update" ]
}

@test "a test again keeps the spots found before, and joins those close together" {
  nova_patch ram 0x1d4e1a008
  nova_patch ram test
  tested_start 1 '  0000000000000000 bad mem addr 0x00000001d4e9a008 - 0x00000001d4e9a010 reserved'
  run apply ram-finish
  [ "$status" -eq 0 ]
  [ "$(ram_conf | grep -v '^#')" = 'KERNEL_CMDLINE[default]+=" memmap=516K$0x1d4e1a000"' ]
  [ "$(ram_description)" = "Keeps 1 bad spot in memory (516 KiB) out of use; the memory test of $(date +%F) found 1" ]
}

@test "a test that found nothing says so, and keeps nothing out of use" {
  nova_patch ram test
  tested_start 0
  run apply ram-finish
  [ "$status" -eq 0 ]
  [ ! -e "$NOVA_ROOT/etc/limine-entry-tool.d/85-nova-patch-ram.conf" ]
  [ ! -e "$NOVA_ROOT/etc/limine-entry-tool.d/85-nova-patch-ram-test.conf" ]
  [ "$(ram_description)" = "The memory test of $(date +%F) found nothing bad" ]
}

@test "a start without the test on its command line leaves it for the next" {
  nova_patch ram test
  tested_start 1 '  0000000000000000 bad mem addr 0x00000001d4e1a008 - 0x00000001d4e1a010 reserved'
  echo 'root=PARTUUID=x rw quiet' >"$NOVA_PROC/cmdline"
  run apply ram-finish
  [ "$status" -eq 0 ]
  [ -e "$NOVA_ROOT/etc/limine-entry-tool.d/85-nova-patch-ram-test.conf" ]
  [ ! -e "$NOVA_ROOT/etc/limine-entry-tool.d/85-nova-patch-ram.conf" ]
}

@test "bad spots the kernel's log lost, or too many, are not guessed at" {
  nova_patch ram test
  tested_start 8 '  0000000000000000 bad mem addr 0x00000001d4e1a008 - 0x00000001d4e1a010 reserved'
  run apply ram-finish
  [ "$status" -eq 0 ]
  [ ! -e "$NOVA_ROOT/etc/limine-entry-tool.d/85-nova-patch-ram.conf" ]
  [[ $(ram_description) == *"found more bad memory than the kernel's log could hold (8 KiB)"* ]]

  nova_patch ram test
  local i lines=()
  for ((i = 0; i < 17; i++)); do
    lines+=("$(printf '  0000000000000000 bad mem addr 0x%016x - 0x%016x reserved' $((0x100000000 + i * 0x400000)) $((0x100000000 + i * 0x400000 + 1024)))")
  done
  tested_start 17 "${lines[@]}"
  run apply ram-finish
  [ ! -e "$NOVA_ROOT/etc/limine-entry-tool.d/85-nova-patch-ram.conf" ]
  [[ $(ram_description) == *"found bad memory in 17 places: too many to keep out of use"* ]]
}

@test "a kernel that cannot test memory says so" {
  nova_patch ram test
  tested_start 0
  printf 'MemTotal:       32555792 kB\n' >"$NOVA_PROC/meminfo"
  run apply ram-finish
  [ "$(ram_description)" = "The memory test of $(date +%F) did not run: this kernel cannot test memory" ]
  [ ! -e "$NOVA_ROOT/etc/limine-entry-tool.d/85-nova-patch-ram-test.conf" ]
}

@test "nova patch ram <address> keeps the pages at those addresses out of use" {
  run nova_patch ram 0x1d4e1a008 1d4e1b000-1d4e1bfff
  [ "$status" -eq 0 ]
  [ "$(ram_conf | grep -v '^#')" = 'KERNEL_CMDLINE[default]+=" memmap=8K$0x1d4e1a000"' ]
  [ "$(ram_description)" = "Keeps 1 bad spot in memory (8 KiB) out of use" ]
  run nova_patch ram 0xZZ
  [ "$status" -eq 1 ]
  [[ $output == *"'0xZZ' is not a memory address"* ]]
  run nova_patch ram 0x2000-0x1000
  [ "$status" -eq 1 ]
}

@test "the memory patch is this computer's only" {
  nova_patch ram 0x1d4e1a008
  write_file "$NOVA_SYS/class/dmi/id/product_uuid" 'another'
  run apply apply
  [ ! -e "$NOVA_ROOT/etc/limine-entry-tool.d/85-nova-patch-ram.conf" ]
  run nova_patch ram test
  [ "$status" -eq 1 ]
  [[ $output == *"the ram patch here is another computer's"* ]]
}

@test "the memory test is not offered where Limine does not start the computer" {
  rm -r "$NOVA_ROOT/etc/limine-entry-tool.d"
  run nova_patch ram test
  [ "$status" -eq 1 ]
  [[ $output == *"needs Limine's boot entries"* ]]
}
