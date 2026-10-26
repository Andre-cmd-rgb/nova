#!/usr/bin/env bats

load ../test_helper

check="$REPO_ROOT/data/raspberry-pi/bin/nova-boot-check"

setup() {
  setup_scratch
  export NOVA_ROOT="$SCRATCH/root"
  # findmnt answers for /boot what $SCRATCH/boot-fstype holds: vfat when the
  # boot partition is mounted, nothing when it is not.
  mkdir -p "$SCRATCH/bin"
  cat >"$SCRATCH/bin/findmnt" <<'EOF'
#!/bin/bash
[[ " $* " == *" --mountpoint $NOVA_ROOT/boot "* && -s $SCRATCH/boot-fstype ]] || exit 1
cat "$SCRATCH/boot-fstype"
EOF
  chmod +x "$SCRATCH/bin/findmnt"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

mounted() { write_file "$SCRATCH/boot-fstype" vfat; }

# A kernel image as linux-rpi-16k installs it: a banner with its version, and the
# modules that go with it.
kernel() { # version [image]
  write_file "$NOVA_ROOT/boot/${2:-kernel8.img}" $'\x00ARMd'"Linux version $1 (builder@alarm) #1 SMP PREEMPT"$'\x00'
  mkdir -p "$NOVA_ROOT/usr/lib/modules/$1"
}

firmware_config() {
  write_file "$NOVA_ROOT/boot/config.txt" $'initramfs initramfs-linux.img followkernel\narm_boost=1\n'
  write_file "$NOVA_ROOT/boot/initramfs-linux.img" x
}

@test "a mounted boot partition with the installed kernel checks out" {
  mounted
  kernel 6.18.58-1-rpi
  firmware_config
  run "$check" post
  [ "$status" -eq 0 ]
  run "$check" status
  [ "$status" -eq 0 ]
  [[ $output == *"holds the installed kernel"* ]]
}

@test "pre: no kernel change while /boot is not the boot partition" {
  kernel 6.18.58-1-rpi
  run "$check" pre
  [ "$status" -eq 1 ]
  [[ $output == *"not mounted at /boot"* ]]
}

@test "pre: a mounted boot partition is all it asks for" {
  mounted
  run "$check" pre
  [ "$status" -eq 0 ]
}

@test "post: a kernel image whose modules are gone is reported" {
  mounted
  kernel 6.18.58-1-rpi
  firmware_config
  rm -r "$NOVA_ROOT/usr/lib/modules/6.18.58-1-rpi"
  mkdir -p "$NOVA_ROOT/usr/lib/modules/6.18.60-1-rpi"
  run "$check" post
  [ "$status" -eq 1 ]
  [[ $output == *"kernel8.img is kernel 6.18.58-1-rpi, whose modules are not installed"* ]]
}

@test "post: every kernel image the firmware could pick is checked" {
  mounted
  kernel 6.18.58-1-rpi
  kernel 6.12.1-1-rpi-16k kernel_2712.img
  firmware_config
  rm -r "$NOVA_ROOT/usr/lib/modules/6.12.1-1-rpi-16k"
  run "$check" status
  [ "$status" -eq 1 ]
  [[ $output == *kernel_2712.img* ]]
  [[ $output != *kernel8.img* ]]
}

@test "post: an initramfs config.txt loads but is missing is reported" {
  mounted
  kernel 6.18.58-1-rpi
  firmware_config
  rm "$NOVA_ROOT/boot/initramfs-linux.img"
  run "$check" post
  [ "$status" -eq 1 ]
  [[ $output == *"initramfs-linux.img, which config.txt loads, is missing"* ]]
}

@test "post: a boot partition without a kernel is reported" {
  mounted
  firmware_config
  run "$check" status
  [ "$status" -eq 1 ]
  [[ $output == *"holds no kernel"* ]]
}

@test "NOVA_BOOT_CHECK=skip passes pre and post, but not status" {
  NOVA_BOOT_CHECK=skip run "$check" pre
  [ "$status" -eq 0 ]
  NOVA_BOOT_CHECK=skip run "$check" post
  [ "$status" -eq 0 ]
  NOVA_BOOT_CHECK=skip run "$check" status
  [ "$status" -eq 1 ]
}

@test "an unknown mode is a usage error" {
  run "$check" verify
  [ "$status" -eq 2 ]
}
