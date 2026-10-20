#!/usr/bin/env bats

# nova-audio-tuning auto, run at every login: a laptop with a tuning gets it,
# one without is left alone, and a tuning turned off by hand stays off.

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" XDG_STATE_HOME="$SCRATCH/state" XDG_CONFIG_HOME="$SCRATCH/config"
  export NOVA_PATH="$SCRATCH/nova" NOVA_DMI_PATH="$SCRATCH/dmi"
  mkdir -p "$NOVA_PATH/default/audio" "$NOVA_DMI_PATH" "$SCRATCH/bin"
  ln -s "$REPO_ROOT/data/audio/tunings" "$NOVA_PATH/default/audio/tunings"
  # No audio server and no waiting: pactl lists nothing, sleep returns at once.
  printf '#!/bin/sh\nexit 0\n' >"$SCRATCH/bin/pactl"
  printf '#!/bin/sh\nexit 0\n' >"$SCRATCH/bin/sleep"
  printf '#!/bin/sh\necho "systemctl $*" >>"%s/calls"\n' "$SCRATCH" >"$SCRATCH/bin/systemctl"
  chmod +x "$SCRATCH/bin"/*
  export PATH="$SCRATCH/bin:$REPO_ROOT/src/cli/bin:$PATH"
}

teardown() { teardown_scratch; }

tuning="$REPO_ROOT/src/cli/bin/nova-audio-tuning"

@test "auto: a computer with no tuning is left alone" {
  echo "ThinkPad X1 Carbon" >"$NOVA_DMI_PATH/product_family"
  run "$tuning" auto
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "auto: a matching laptop gets the tuning, and waits for its sink if it is not up" {
  echo "ThinkPad P1 Gen 4i" >"$NOVA_DMI_PATH/product_family"
  run "$tuning" auto
  [ "$status" -eq 0 ]
  [[ $output == *"no audio server yet"* ]]
  [[ $output == *"trying again at the next login"* ]]
}

@test "auto: a tuning turned off by hand stays off" {
  echo "ThinkPad P1 Gen 4i" >"$NOVA_DMI_PATH/product_family"
  mkdir -p "$XDG_CONFIG_HOME/pipewire"
  : >"$XDG_CONFIG_HOME/pipewire/nova-speaker-tuning.conf"
  run "$tuning" off
  [ "$status" -eq 0 ]
  [ -e "$XDG_STATE_HOME/nova/speaker-tuning-off" ]
  run "$tuning" auto
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
