#!/usr/bin/env bats

load ../test_helper

ddc="$REPO_ROOT/src/cli/bin/nova-brightness-display-ddc"

# The first block of a real screen's EDID: a 1024x600 HDMI panel whose
# brightness runs backwards, HCH:HETECH to ddcutil.
HETECH_EDID='
00ffffffffffff002068040080ee33011a1c010380a05a78ea5525a1574fa028
0f50540000000100010001000100010001000100010101140040415823202010
9300dc0c1100001e000000ff0032303230303931350a20202020000000fd0018
461a8c1e000a202020202020000000fc004845544543480a20202020202001f5'

setup() {
  setup_scratch
  export XDG_RUNTIME_DIR="$SCRATCH/run" NOVA_HARDWARE="$REPO_ROOT/data/hardware"
  export NOVA_DRM_PATH="$SCRATCH/drm" VCP="$SCRATCH/vcp"
  mkdir -p "$XDG_RUNTIME_DIR" "$SCRATCH/bin"
  # ddcutil for one screen on bus 14, its brightness in $VCP, out of 100.
  cat >"$SCRATCH/bin/ddcutil" <<'EOF'
#!/bin/bash
case " $* " in
  *" detect "*) printf 'Display 1\n   I2C bus:          /dev/i2c-14\n   DRM connector:    card1-HDMI-A-2\n' ;;
  *" getvcp 10 "*) printf 'VCP 10 C %s 100\n' "$(<"$VCP")" ;;
  *" setvcp 10 "*) echo "${@: -1}" >"$VCP" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$SCRATCH/bin/ddcutil"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

# The screen on HDMI-A-2, with the EDID given as hex.
screen() { # hex
  mkdir -p "$NOVA_DRM_PATH/card1-HDMI-A-2"
  local hex=${1//[$'\n ']/} i
  for ((i = 0; i < ${#hex}; i += 2)); do printf "\\x${hex:i:2}"; done >"$NOVA_DRM_PATH/card1-HDMI-A-2/edid"
}

# The same block with another maker and name, DEL:U2720Q: an ordinary screen.
# The maker is bytes 8-9, the name bytes 113-125.
ordinary_edid() {
  local hex=${HETECH_EDID//[$'\n ']/}
  hex=${hex:0:16}10ac${hex:20}
  printf '%s' "${hex:0:226}5532373230510a202020202020${hex:252}"
}

@test "an ordinary screen: Nova's numbers are the screen's" {
  screen "$(ordinary_edid)"
  echo 6 >"$VCP"
  run "$ddc" HDMI-A-2
  [ "$output" = 6 ]
  run "$ddc" HDMI-A-2 25%
  [ "$status" -eq 0 ]
  [ "$(<"$VCP")" = 25 ]
}

@test "a screen that runs backwards reads flipped" {
  screen "$HETECH_EDID"
  echo 0 >"$VCP"
  run "$ddc" HDMI-A-2
  [ "$output" = 100 ]
  echo 94 >"$VCP"
  run "$ddc" HDMI-A-2
  [ "$output" = 6 ]
}

@test "a screen that runs backwards is set flipped" {
  screen "$HETECH_EDID"
  echo 50 >"$VCP"
  run "$ddc" HDMI-A-2 100%
  [ "$output" = 100 ]
  [ "$(<"$VCP")" = 0 ]
  run "$ddc" HDMI-A-2 25%
  [ "$(<"$VCP")" = 75 ]
}

@test "a step up on a screen that runs backwards brightens it" {
  screen "$HETECH_EDID"
  echo 60 >"$VCP"
  run "$ddc" HDMI-A-2 +10%
  [ "$output" = 50 ]
  [ "$(<"$VCP")" = 50 ]
}

@test "a screen without an EDID is driven as it says" {
  echo 6 >"$VCP"
  run "$ddc" HDMI-A-2
  [ "$output" = 6 ]
}
