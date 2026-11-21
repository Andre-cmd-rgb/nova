#!/usr/bin/env bats
# nova-hw-packages: the packages a computer's hardware needs, from a sysfs and
# a cpuinfo of the test's own.

load ../test_helper

packages="$REPO_ROOT/data/hardware/bin/nova-hw-packages"

setup() {
  setup_scratch
  export NOVA_CPUINFO="$SCRATCH/cpuinfo" NOVA_PCI_DEVICES_PATH="$SCRATCH/pci"
  mkdir -p "$NOVA_PCI_DEVICES_PATH"
}

teardown() { teardown_scratch; }

pci() { # name class vendor device
  mkdir -p "$NOVA_PCI_DEVICES_PATH/$1"
  echo "$2" >"$NOVA_PCI_DEVICES_PATH/$1/class"
  echo "$3" >"$NOVA_PCI_DEVICES_PATH/$1/vendor"
  echo "$4" >"$NOVA_PCI_DEVICES_PATH/$1/device"
}

cpu() { printf 'vendor_id\t: %s\n' "$1" >"$NOVA_CPUINFO"; }

lines() { printf '%s\n' "$@"; }

# The machines Nova installs on: an Intel laptop, an AMD desktop, an NVIDIA
# card alone, and the ThinkPad P1 Gen 4i (Tiger Lake's Iris Xe and an RTX
# A2000 beside it).
intel_only() { cpu GenuineIntel; pci 0000:00:02.0 0x030000 0x8086 0x9a49; }
amd_only() { cpu AuthenticAMD; pci 0000:03:00.0 0x030000 0x1002 0x73df; }
nvidia_only() { cpu AuthenticAMD; pci 0000:01:00.0 0x030000 0x10de 0x2786; }
p1() {
  cpu GenuineIntel
  pci 0000:00:02.0 0x030000 0x8086 0x9a60
  pci 0000:00:1f.3 0x040380 0x8086 0xa0c8
  pci 0000:01:00.0 0x030200 0x10de 0x25b8
}

@test "Intel alone: Mesa's drivers, and nothing of NVIDIA's" {
  intel_only
  run "$packages"
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines intel-ucode intel-media-driver vulkan-intel)" ]
  run "$packages" --graphics
  [ "$output" = "$(lines mesa vulkan-intel)" ]
  run "$packages" --lib32
  [ "$output" = "$(lines lib32-mesa lib32-vulkan-intel)" ]
}

@test "AMD alone: RADV, 64- and 32-bit" {
  amd_only
  run "$packages"
  [ "$output" = "$(lines amd-ucode vulkan-radeon)" ]
  run "$packages" --graphics
  [ "$output" = "$(lines mesa vulkan-radeon)" ]
  run "$packages" --lib32
  [ "$output" = "$(lines lib32-mesa lib32-vulkan-radeon)" ]
}

@test "an NVIDIA card alone: NVIDIA's driver for OpenGL and Vulkan, no Mesa driver to pick" {
  nvidia_only
  run "$packages" --kernel linux
  [ "$output" = "$(lines amd-ucode nvidia-open nvidia-open-lts nvidia-utils libva-nvidia-driver)" ]
  run "$packages" --graphics
  [ "$output" = nvidia-utils ]
  run "$packages" --lib32
  [ "$output" = lib32-nvidia-utils ]
}

@test "the P1: the Intel GPU's drivers and NVIDIA's, both, 64- and 32-bit" {
  p1
  run "$packages"
  [ "$output" = "$(lines intel-ucode intel-media-driver vulkan-intel nvidia-open-nova nvidia-open-lts nvidia-utils nvidia-prime libva-nvidia-driver)" ]
  run "$packages" --graphics
  [ "$output" = "$(lines mesa vulkan-intel nvidia-utils)" ]
  # The desktop and the Steam client run on the Intel GPU, a game on the
  # NVIDIA card when plugged in: 32-bit Vulkan on both.
  run "$packages" --lib32
  [ "$output" = "$(lines lib32-mesa lib32-vulkan-intel lib32-nvidia-utils)" ]
}

@test "an NVIDIA card older than Turing is nouveau's: NVK, never nvidia-utils" {
  cpu AuthenticAMD
  pci 0000:01:00.0 0x030000 0x10de 0x1c03
  run "$packages"
  [ "$output" = "$(lines amd-ucode vulkan-nouveau)" ]
  run "$packages" --lib32
  [ "$output" = "$(lines lib32-mesa lib32-vulkan-nouveau)" ]
}

@test "a virtual machine's display: Mesa's software Vulkan for an app that needs one, nothing for the installer" {
  cpu GenuineIntel
  pci 0000:00:01.0 0x030000 0x1af4 0x1050
  run "$packages"
  [ "$output" = intel-ucode ]
  run "$packages" --graphics
  [ "$output" = "$(lines mesa vulkan-swrast)" ]
  run "$packages" --lib32
  [ "$output" = "$(lines lib32-mesa lib32-vulkan-swrast)" ]
  # No display controller at all reads the same.
  rm -r "$NOVA_PCI_DEVICES_PATH/0000:00:01.0"
  run "$packages" --lib32
  [ "$output" = "$(lines lib32-mesa lib32-vulkan-swrast)" ]
}

@test "two cards of a kind are one driver" {
  amd_only
  pci 0000:04:00.0 0x038000 0x1002 0x744c
  run "$packages" --lib32
  [ "$output" = "$(lines lib32-mesa lib32-vulkan-radeon)" ]
}

@test "--portable: every Mesa driver, whatever this computer has, and never NVIDIA's" {
  p1
  run "$packages" --portable --kernel linux
  [ "$output" = "$(lines intel-ucode amd-ucode intel-media-driver vulkan-intel vulkan-radeon vulkan-nouveau)" ]
  run "$packages" --portable --lib32
  [ "$output" = "$(lines lib32-mesa lib32-vulkan-intel lib32-vulkan-radeon lib32-vulkan-nouveau)" ]
  [[ $output != *nvidia* ]]
}

@test "--every: what any computer's first mode can print" {
  run "$packages" --every
  [ "$status" -eq 0 ]
  [ -z "$(sort <<<"$output" | uniq -d)" ]
  local every=$output machine
  for machine in intel_only amd_only nvidia_only p1; do
    rm -rf "$NOVA_PCI_DEVICES_PATH" && mkdir -p "$NOVA_PCI_DEVICES_PATH"
    "$machine"
    for kernel in linux-nova linux; do
      while IFS= read -r p; do
        grep -qx -- "$p" <<<"$every"
      done < <("$packages" --kernel "$kernel")
    done
    while IFS= read -r p; do
      grep -qx -- "$p" <<<"$every"
    done < <("$packages" --portable)
  done
  # A camera's too.
  pci 0000:00:05.0 0x048000 0x8086 0xa75d
  "$packages" | grep -qx pipewire-libcamera
  grep -qx pipewire-libcamera <<<"$every"
}

@test "arguments: one mode, a kernel's name, nothing else" {
  intel_only
  run "$packages" --graphics --lib32
  [ "$status" -eq 2 ]
  run "$packages" --kernel '--lib32'
  [ "$status" -eq 2 ]
  run "$packages" --kernel '../x'
  [ "$status" -eq 2 ]
  run "$packages" lib32
  [ "$status" -eq 2 ]
  run "$packages" --help
  [ "$status" -eq 0 ]
  [[ $output == *--lib32* ]]
}

# The bug this is for: Steam needs vulkan-driver and lib32-vulkan-driver, and
# pacman, left to pick, takes NVIDIA's on any computer. Given the drivers in
# the same transaction, it takes those. Real pacman, on package lists of the
# test's own.
@test "with the drivers beside it, pacman resolves Steam to them and pulls no NVIDIA package" {
  command -v pacman >/dev/null || skip "no pacman"
  local db=$SCRATCH/db sync=$SCRATCH/sync
  mkdir -p "$db/local" "$db/sync" "$sync"
  fake() { # name provides depends
    mkdir -p "$sync/$1-1-1"
    {
      printf '%%NAME%%\n%s\n\n%%VERSION%%\n1-1\n\n%%ARCH%%\nany\n\n%%FILENAME%%\n%s-1-1-any.pkg.tar\n\n' "$1" "$1"
      [[ -z $2 ]] || printf '%%PROVIDES%%\n%s\n\n' "$2"
      [[ -z $3 ]] || printf '%%DEPENDS%%\n%s\n\n' "$3"
    } >"$sync/$1-1-1/desc"
  }
  # As Arch's repositories list them, the NVIDIA providers first by name.
  fake lib32-nvidia-utils lib32-vulkan-driver nvidia-utils
  fake nvidia-utils vulkan-driver ''
  fake lib32-vulkan-intel lib32-vulkan-driver ''
  fake lib32-vulkan-radeon lib32-vulkan-driver ''
  fake lib32-mesa '' ''
  fake mesa '' ''
  fake vulkan-intel vulkan-driver ''
  fake vulkan-radeon vulkan-driver ''
  fake steam '' "$(printf '%s\n' vulkan-driver lib32-vulkan-driver)"
  (cd "$sync" && bsdtar -czf "$db/sync/test.db" -- *)
  printf '[options]\nArchitecture = auto\nSigLevel = Never\n\n[test]\nServer = file:///nonexistent\n' >"$SCRATCH/pacman.conf"
  resolve() { pacman --config "$SCRATCH/pacman.conf" --dbpath "$db" --logfile /dev/null --noconfirm -Sp --print-format %n "$@"; }

  # Left alone, pacman takes NVIDIA's: the bug.
  run resolve steam
  [ "$status" -eq 0 ]
  [[ $output == *nvidia-utils* ]]

  local machine
  for machine in intel_only amd_only; do
    rm -rf "$NOVA_PCI_DEVICES_PATH" && mkdir -p "$NOVA_PCI_DEVICES_PATH"
    "$machine"
    mapfile -t drivers < <("$packages" --graphics; "$packages" --lib32)
    run resolve steam "${drivers[@]}"
    [ "$status" -eq 0 ]
    [[ $output != *nvidia* ]]
    grep -qx 'lib32-vulkan-\(intel\|radeon\)' <<<"$output"
  done
}

@test "the P1 on battery: the NVIDIA card nova power took off the bus is still counted" {
  cpu GenuineIntel
  pci 0000:00:02.0 0x030000 0x8086 0x9a60
  printf '0000:01:00.0\n' >"$SCRATCH/nvidia-pci"
  run "$packages" --lib32
  [ "$output" = "$(lines lib32-mesa lib32-vulkan-intel)" ]
  NOVA_POWER_NVIDIA_CACHE=$SCRATCH/nvidia-pci run "$packages" --lib32
  [ "$output" = "$(lines lib32-mesa lib32-vulkan-intel lib32-nvidia-utils)" ]
  # Back on the bus, it is read from there; a line that is no address is no card.
  pci 0000:01:00.0 0x030200 0x10de 0x25b8
  NOVA_POWER_NVIDIA_CACHE=$SCRATCH/nvidia-pci run "$packages" --graphics
  [ "$output" = "$(lines mesa vulkan-intel nvidia-utils)" ]
  rm -r "$NOVA_PCI_DEVICES_PATH/0000:01:00.0"
  printf '../../etc\n' >"$SCRATCH/nvidia-pci"
  NOVA_POWER_NVIDIA_CACHE=$SCRATCH/nvidia-pci run "$packages" --graphics
  [ "$output" = "$(lines mesa vulkan-intel)" ]
}
