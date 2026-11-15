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
  *" setvcp 10 "*) [[ ! -e $SCRATCH/set-fails ]] || exit 1; echo "${@: -1}" >"$VCP" ;;
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

# How many times ddcutil was asked this, once log_calls has it log.
asked() { grep -c -- " $1 " "$SCRATCH/ddc-calls" 2>/dev/null || true; }

log_calls() {
  sed -i '2i echo " $* " >>"'"$SCRATCH"'/ddc-calls"' "$SCRATCH/bin/ddcutil"
}

@test "the keys' 5% steps go by 1% at 5% and under, and stop at 1% and 100%" {
  screen "$(ordinary_edid)"
  for case in 4:+5%:5 5:+5%:10 5:5%-:4 6:5%-:1 2:5%-:1 98:+5%:100 50:+10%:60 50:20%-:30 1:1%-:1; do
    IFS=: read -r from step to <<<"$case"
    echo "$from" >"$VCP"
    run "$ddc" HDMI-A-2 "$step"
    [ "$status" -eq 0 ] || { echo "$case: status $status"; return 1; }
    [ "$output" = "$to" ] || { echo "$case: said $output"; return 1; }
    [ "$(<"$VCP")" = "$to" ] || { echo "$case: set $(<"$VCP")"; return 1; }
  done
}

@test "a percentage set just after a reading needs no reading of its own" {
  screen "$(ordinary_edid)"
  log_calls
  echo 40 >"$VCP"
  "$ddc" HDMI-A-2 >/dev/null
  "$ddc" HDMI-A-2 70% >/dev/null
  [ "$(<"$VCP")" = 70 ]
  [ "$(asked detect)" = 1 ]
  [ "$(asked getvcp)" = 1 ]
}

@test "a display without DDC/CI is not looked for again for a minute" {
  sed -i 's#card1-HDMI-A-2#card1-DP-9#' "$SCRATCH/bin/ddcutil"
  log_calls
  run "$ddc" HDMI-A-2
  [ "$status" -eq 1 ]
  run "$ddc" HDMI-A-2 +5%
  [ "$status" -eq 1 ]
  [ "$(asked detect)" = 1 ]
}

@test "a brightness that cannot be set fails, and the display is looked for again" {
  screen "$(ordinary_edid)"
  echo 40 >"$VCP"
  "$ddc" HDMI-A-2 >/dev/null
  touch "$SCRATCH/set-fails"
  log_calls
  run "$ddc" HDMI-A-2 50%
  [ "$status" -eq 1 ]
  rm "$SCRATCH/set-fails"
  run "$ddc" HDMI-A-2 50%
  [ "$output" = 50 ]
  [ "$(asked detect)" = 1 ]
}

@test "no monitor, or a step it does not take, fails" {
  run "$ddc"
  [ "$status" -eq 1 ]
  for step in 5 +5 up -5% 5%+; do
    run "$ddc" HDMI-A-2 "$step"
    [ "$status" -eq 1 ] || { echo "took $step"; return 1; }
  done
}
