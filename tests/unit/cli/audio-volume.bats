#!/usr/bin/env bats

# nova-audio-output-volume, the volume keys from a terminal: the steps, where
# they stop, the mute key pressed twice at once, and the OSD. pactl is a stub
# whose sink has the volume in $SCRATCH/volume and its mute in $SCRATCH/mute;
# nova-osd and nova-audio-output-sink are stubs too.

load ../test_helper

setup() {
  setup_scratch
  export XDG_RUNTIME_DIR=$SCRATCH/run CALLS=$SCRATCH/calls
  mkdir -p "$SCRATCH/bin" "$XDG_RUNTIME_DIR"
  echo 50 >"$SCRATCH/volume"
  echo no >"$SCRATCH/mute"
  echo alsa_output.speakers >"$SCRATCH/sink"
  cat >"$SCRATCH/bin/pactl" <<'STUB'
#!/bin/bash
[[ $2 == alsa_output.speakers ]] || exit 1
case $1 in
  get-sink-volume)
    [[ -s $SCRATCH/volume ]] || exit 1
    v=$(cat "$SCRATCH/volume")
    printf 'Volume: front-left: 1 / %4s%% / 0 dB,   front-right: 1 / %4s%% / 0 dB\n        balance 0.00\n' "$v" "$v"
    ;;
  get-sink-mute) echo "Mute: $(cat "$SCRATCH/mute")" ;;
  set-sink-volume) echo "${3%\%}" >"$SCRATCH/volume"; echo "pactl $*" >>"$CALLS" ;;
  set-sink-mute)
    case $3 in
      0) echo no >"$SCRATCH/mute" ;;
      toggle) if [[ $(cat "$SCRATCH/mute") == no ]]; then echo yes; else echo no; fi >"$SCRATCH/mute.new"; mv "$SCRATCH/mute.new" "$SCRATCH/mute" ;;
    esac
    echo "pactl $*" >>"$CALLS"
    ;;
esac
STUB
  printf '#!/bin/sh\ncat "%s/sink"\n' "$SCRATCH" >"$SCRATCH/bin/nova-audio-output-sink"
  printf '#!/bin/sh\necho "osd $*" >>"%s"\n' "$CALLS" >"$SCRATCH/bin/nova-osd"
  chmod +x "$SCRATCH/bin"/*
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

volume() { "$REPO_ROOT/src/cli/bin/nova-audio-output-volume" "$@"; }

@test "raise and lower step by 5, unmuting, and the OSD shows where it is" {
  echo yes >"$SCRATCH/mute"
  volume raise
  [ "$(cat "$CALLS")" = $'pactl set-sink-mute alsa_output.speakers 0\npactl set-sink-volume alsa_output.speakers 55%\nosd -i volume-high -p 55' ]
  : >"$CALLS"
  volume lower
  volume -1
  [ "$(cat "$SCRATCH/volume")" = 49 ]
}

@test "down stops at 0, shown as muted; up stops at 100, even from above it" {
  echo 3 >"$SCRATCH/volume"
  volume lower
  [ "$(tail -n 2 "$CALLS")" = $'pactl set-sink-volume alsa_output.speakers 0%\nosd -i volume-muted -p 0' ]
  echo 150 >"$SCRATCH/volume"
  volume lower
  [ "$(cat "$SCRATCH/volume")" = 145 ]
  volume +10
  [ "$(cat "$SCRATCH/volume")" = 100 ]
}

@test "a step written with a leading zero is read as decimal" {
  echo 40 >"$SCRATCH/volume"
  run volume -08
  [ "$status" -eq 0 ]
  [ "$(cat "$SCRATCH/volume")" = 32 ]
}

@test "mute-toggle mutes, and a press sent twice at once toggles once" {
  volume mute-toggle
  volume mute-toggle
  [ "$(cat "$CALLS")" = $'pactl set-sink-mute alsa_output.speakers toggle\nosd -i volume-muted -p 50' ]
}

@test "anything else is refused, and nothing is changed" {
  run volume
  [ "$status" -eq 1 ]
  [[ $output == Usage:* ]]
  for action in up 5 +x -- '+5%'; do
    run volume "$action"
    [ "$status" -eq 1 ]
    [ "$output" = "Unknown volume action: $action" ]
  done
  [ ! -e "$CALLS" ]
}

@test "no sink, or no volume to read, fails" {
  : >"$SCRATCH/volume"
  run volume raise
  [ "$status" -eq 1 ]
  [ "$output" = "Could not read volume for alsa_output.speakers." ]
  : >"$SCRATCH/sink"
  run volume raise
  [ "$status" -eq 1 ]
  [ "$output" = "Could not resolve an audio sink to control." ]
  [ ! -e "$CALLS" ]
}
