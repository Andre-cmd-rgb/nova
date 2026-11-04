#!/usr/bin/env bats

# What the helpers read about the machine: whether it is a laptop, its lid
# shut, a display plugged in, its backlight, its model, and which commands
# are installed. /proc and /sys are directories here, through the NOVA_*_PATH
# each helper takes.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_LID_PATH="$SCRATCH/lid" NOVA_DMI_PATH="$SCRATCH/dmi" NOVA_DRM_PATH="$SCRATCH/drm" NOVA_BACKLIGHT_PATH="$SCRATCH/backlight"
  mkdir -p "$NOVA_DMI_PATH" "$NOVA_DRM_PATH" "$NOVA_BACKLIGHT_PATH"
  export PATH="$REPO_ROOT/src/cli/bin:/usr/bin"
}

teardown() { teardown_scratch; }

lid() { write_file "$NOVA_LID_PATH/LID0/state" "state:      $1"$'\n'; }
connector() { write_file "$NOVA_DRM_PATH/$1/status" "$2"$'\n'; }

@test "laptop: a lid says so, and without one the chassis type" {
  fails nova-hw-laptop
  lid open
  nova-hw-laptop
  rm -r "$NOVA_LID_PATH"
  for chassis in 8 9 10 14 30 31 32; do
    echo "$chassis" >"$NOVA_DMI_PATH/chassis_type"
    nova-hw-laptop
  done
  for chassis in 3 13 35 "8 9" ""; do
    echo "$chassis" >"$NOVA_DMI_PATH/chassis_type"
    fails nova-hw-laptop
  done
}

@test "laptop closed: any lid shut" {
  fails nova-hw-laptop-closed
  lid open
  fails nova-hw-laptop-closed
  lid closed
  nova-hw-laptop-closed
}

@test "external monitors: a connected connector that is not the panel" {
  connector card1-eDP-1 connected
  connector card1-DP-1 disconnected
  fails nova-hw-external-monitors
  connector card1-DP-2 connected
  nova-hw-external-monitors
}

@test "clamshell: the lid shut with a display plugged in" {
  lid closed
  connector card1-eDP-1 connected
  fails nova-hw-clamshell
  connector card0-HDMI-A-1 connected
  nova-hw-clamshell
  lid open
  fails nova-hw-clamshell
}

@test "display: the GPU's backlight before the firmware's, and any before none" {
  run nova-hw-display
  [ "$status" -eq 1 ]
  mkdir "$NOVA_BACKLIGHT_PATH/acpi_video0" "$NOVA_BACKLIGHT_PATH/aaa"
  [ "$(nova-hw-display)" = acpi_video0 ]
  mkdir "$NOVA_BACKLIGHT_PATH/intel_backlight"
  [ "$(nova-hw-display)" = intel_backlight ]
  mkdir "$NOVA_BACKLIGHT_PATH/amdgpu_bl1"
  [ "$(nova-hw-display)" = amdgpu_bl1 ]
}

@test "match: the product name or family, any case" {
  echo "21DE001AGE" >"$NOVA_DMI_PATH/product_name"
  echo "ThinkPad P1 Gen 5" >"$NOVA_DMI_PATH/product_family"
  nova-hw-match "thinkpad p1"
  nova-hw-match 21de
  fails nova-hw-match "legion"
  run nova-hw-match
  [ "$status" -eq 2 ]
}
