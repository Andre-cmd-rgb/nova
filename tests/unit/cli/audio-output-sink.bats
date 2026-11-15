#!/usr/bin/env bats

# nova-audio-output-sink: the sink under a filter in front of an output, where
# the output's loudness is. pactl lists the sinks and streams in $SCRATCH,
# pw-link the links in $SCRATCH/links.

load ../test_helper

setup() {
  setup_scratch
  export XDG_CONFIG_HOME=$SCRATCH/config
  mkdir -p "$SCRATCH/bin"
  printf '%s\n' \
    $'50\talsa_output.speakers\tPipeWire\ts24le 2ch 48000Hz\tRUNNING' \
    $'51\talsa_output.hdmi\tPipeWire\ts24le 2ch 48000Hz\tSUSPENDED' \
    $'52\tbluez_output.headphones\tPipeWire\ts16le 2ch 48000Hz\tIDLE' \
    $'60\tnova_speaker_tuning\tPipeWire\tfloat32le 2ch 48000Hz\tRUNNING' \
    $'61\teffect_input.room\tPipeWire\tfloat32le 2ch 48000Hz\tRUNNING' \
    $'62\teasyeffects_sink\tPipeWire\tfloat32le 2ch 48000Hz\tRUNNING' >"$SCRATCH/sinks"
  : >"$SCRATCH/inputs"
  : >"$SCRATCH/links"
  echo nova_speaker_tuning >"$SCRATCH/default"
  cat >"$SCRATCH/bin/pactl" <<'STUB'
#!/bin/bash
case "$*" in
  "get-default-sink") cat "$SCRATCH/default" ;;
  "list sinks short") cat "$SCRATCH/sinks" ;;
  "list sink-inputs") cat "$SCRATCH/inputs" ;;
  *) exit 1 ;;
esac
STUB
  printf '#!/bin/sh\ncat "%s/links"\n' "$SCRATCH" >"$SCRATCH/bin/pw-link"
  chmod +x "$SCRATCH/bin"/*
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

sink() { "$REPO_ROOT/src/cli/bin/nova-audio-output-sink" "$@"; }

stream() { # number sink property...
  printf 'Sink Input #%s\n\tDriver: PipeWire\n\tSink: %s\n\tProperties:\n' "$1" "$2"
  shift 2
  printf '\t\t%s\n' "$@"
}

@test "a sound card's own sink, or none, answers itself" {
  [ "$(sink alsa_output.hdmi)" = alsa_output.hdmi ]
  echo alsa_output.speakers >"$SCRATCH/default"
  [ "$(sink)" = alsa_output.speakers ]
  : >"$SCRATCH/default"
  run sink
  [ "$output" = "" ]
}

@test "a tuning, the default output, answers the sink its stream plays into" {
  {
    stream 7 51 'application.name = "Firefox"' 'node.name = "Firefox"'
    stream 8 50 'media.name = "tuning"' 'node.name = "nova_speaker_tuning_output"'
  } >"$SCRATCH/inputs"
  [ "$(sink)" = alsa_output.speakers ]
}

@test "an effect_input's own effect_output wins over a stream only named after it" {
  {
    stream 3 51 'node.name = "effect_input.room.monitor"'
    stream 4 52 'node.name = "effect_output.room"'
  } >"$SCRATCH/inputs"
  [ "$(sink effect_input.room)" = bluez_output.headphones ]
  stream 3 51 'node.name = "effect_input.room.monitor"' >"$SCRATCH/inputs"
  [ "$(sink effect_input.room)" = alsa_output.hdmi ]
}

@test "EasyEffects: its stream, else its ports' links, else the output it is set to" {
  stream 5 52 'application.name = "EasyEffects"' 'node.name = "ee_soe_output_level"' >"$SCRATCH/inputs"
  [ "$(sink easyeffects_sink)" = bluez_output.headphones ]
  : >"$SCRATCH/inputs"
  printf '%s\n' 'Firefox:output_FL' '  |-> alsa_output.hdmi:playback_FL' 'ee_soe_output_level:output_FL' \
    '  |-> nova_speaker_tuning:playback_FL' '  |-> alsa_output.speakers:playback_FL' >"$SCRATCH/links"
  [ "$(sink easyeffects_sink)" = alsa_output.speakers ]
  : >"$SCRATCH/links"
  mkdir -p "$XDG_CONFIG_HOME/easyeffects/db"
  printf '[Output]\noutputDevice=alsa_output.hdmi\n' >"$XDG_CONFIG_HOME/easyeffects/db/easyeffectsrc"
  [ "$(sink easyeffects_sink)" = alsa_output.hdmi ]
  printf '[Output]\noutputDevice=alsa_output.gone\n' >"$XDG_CONFIG_HOME/easyeffects/db/easyeffectsrc"
  [ "$(sink easyeffects_sink)" = easyeffects_sink ]
}

@test "a filter with nothing found under it answers itself" {
  stream 9 77 'node.name = "nova_speaker_tuning_output"' >"$SCRATCH/inputs"
  [ "$(sink)" = nova_speaker_tuning ]
  # No audio server.
  printf '#!/bin/sh\nexit 1\n' >"$SCRATCH/bin/pactl"
  [ "$(sink some_filter)" = some_filter ]
}
