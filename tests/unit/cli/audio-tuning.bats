#!/usr/bin/env bats

# nova-audio-tuning auto, run at every login: a laptop with a tuning gets it,
# one without is left alone, and a tuning turned off by hand stays off. And
# every tuning's own volumes stay at 100%.

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
  # The P1's plugins, as their bundles declare them: Calf in full, LSP through
  # a prefix.
  export LV2_PATH="$SCRATCH/lv2"
  mkdir -p "$LV2_PATH/calf.lv2" "$LV2_PATH/lsp-plugins.lv2"
  echo '<http://calf.sourceforge.net/plugins/BassEnhancer> a lv2:Plugin ; rdfs:seeAlso <BassEnhancer.ttl> .' \
    >"$LV2_PATH/calf.lv2/manifest.ttl"
  printf '%s\n' '@prefix plug:       <http://lsp-plug.in/plugins/lv2/> .' 'plug:limiter_stereo' \
    '	a lv2:Plugin ;' >"$LV2_PATH/lsp-plugins.lv2/manifest.ttl"
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

@test "on: a plugin the graph needs is missing, so nothing is installed" {
  echo "ThinkPad P1 Gen 4i" >"$NOVA_DMI_PATH/product_family"
  rm -r "$LV2_PATH/calf.lv2"
  run "$tuning" on
  [ "$status" -eq 1 ]
  [[ $output == *"http://calf.sourceforge.net/plugins/BassEnhancer"* ]]
  [[ $output != *"lsp-plug.in"* ]]
  [[ $output == *"nova update installs them"* ]]
  [ ! -e "$XDG_CONFIG_HOME/pipewire/nova-speaker-tuning.conf" ]
  [ ! -e "$SCRATCH/calls" ]
}

@test "every tuning: its volumes are locked, and WirePlumber keeps none of them" {
  # A volume WirePlumber had kept for the P1's tuning (0.000125) made its
  # speakers silent at every start, the keys moving the speakers behind it.
  for conf in "$REPO_ROOT"/data/audio/tunings/*/filter-chain.conf; do
    for side in capture playback; do
      props=$(sed -n "/^ *$side.props = {/,/^ *}/p" "$conf")
      [[ $props == *"channelmix.lock-volumes = true"* ]] || { echo "$conf: $side.props is not locked"; return 1; }
      [[ $props == *"state.restore-props = false"* ]] || { echo "$conf: $side.props is restored"; return 1; }
    done
  done
}
