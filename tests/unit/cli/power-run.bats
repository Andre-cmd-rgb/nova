#!/usr/bin/env bats

# nova power run and prefer: a program on the discrete GPU, with what the
# session hides from everything else put back for it alone. The card's place
# on the bus is a folder in a scratch copy of sysfs.

load ../test_helper

setup() {
  setup_scratch
  export SYS_PCI=$SCRATCH/pci NVIDIA_PCI_CACHE=$SCRATCH/nvidia-pci
  export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
  export __GLX_VENDOR_LIBRARY_NAME=mesa VK_LOADER_DRIVERS_DISABLE='*nvidia*' FLATPAK_GL_DRIVERS=default:host
  mkdir -p "$SYS_PCI"
  # The address the boot found, for a machine with no NVIDIA card of its own.
  echo 0000:01:00.0 >"$NVIDIA_PCI_CACHE"
  POWER=$REPO_ROOT/src/power/bin/nova-power
  SHOW='echo "${__NV_PRIME_RENDER_OFFLOAD:-}|${__GLX_VENDOR_LIBRARY_NAME:-}|${__EGL_VENDOR_LIBRARY_FILENAMES:-}|${VK_LOADER_DRIVERS_DISABLE:-}|${FLATPAK_GL_DRIVERS:-}|$*"'
}

teardown() { teardown_scratch; }

# Where nova-power looks for the card: this machine's own NVIDIA GPU, found in
# the real sysfs as it finds it, else the address the boot kept.
card_at() {
  local dev
  for dev in /sys/bus/pci/devices/*/; do
    [[ $(cat "${dev}vendor" 2>/dev/null) == 0x10de ]] || continue
    case $(cat "${dev}class" 2>/dev/null) in 0x030000 | 0x030200) basename "$dev"; return ;; esac
  done
  echo 0000:01:00.0
}
card_on() { mkdir -p "$SYS_PCI/$(card_at)"; }

@test "run: on the card, with NVIDIA's EGL and Vulkan back, and the arguments as given" {
  card_on
  run "$POWER" run bash -c "$SHOW" x 'two words'
  [ "$status" -eq 0 ]
  [ "$output" = "1|nvidia||||two words" ]
}

@test "run: with the card off the bus it says so and runs nothing" {
  run "$POWER" run touch "$SCRATCH/ran"
  [ "$status" -ne 0 ]
  [[ $output == *"off the bus"* ]]
  [ ! -e "$SCRATCH/ran" ]
}

@test "prefer: on the card while it is on the bus, else as it is" {
  run "$POWER" prefer bash -c "$SHOW" x one
  [ "$status" -eq 0 ]
  [ "$output" = "|mesa|/usr/share/glvnd/egl_vendor.d/50_mesa.json|*nvidia*|default:host|one" ]
  card_on
  run "$POWER" prefer bash -c "$SHOW" x one
  [ "$output" = "1|nvidia||||one" ]
}

@test "prefer and run need no root, and a program" {
  run "$POWER" prefer
  [ "$status" -ne 0 ]
  [[ $output == *"prefer needs a program"* ]]
  [[ $output != *root* ]]
}
