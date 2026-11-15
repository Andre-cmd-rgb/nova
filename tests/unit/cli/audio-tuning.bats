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

@test "every tuning: each link, input and output joins nodes the graph has" {
  local conf names end
  for conf in "$REPO_ROOT"/data/audio/tunings/*/filter-chain.conf; do
    names=$(grep -oE '\bname +=  *[a-z0-9_]+( |$)' "$conf" | awk '{ print $3 }' | sort -u)
    [ -n "$names" ]
    while IFS= read -r end; do
      grep -qx -- "${end%%:*}" <<<"$names" || { echo "$conf: ${end%%:*} is no node of the graph"; return 1; }
    done < <(sed -n '/^ *links = \[/,/^ *outputs /p' "$conf" | grep -oE '"[a-z0-9_]+:[A-Za-z0-9_]+"' | tr -d '"')
    # A chain of ten a side, the bass before it and the limiter after: 22 links.
    [ "$(grep -c '{ output = ' "$conf")" -ge 2 ]
  done
}

# The P1 with its speakers up: pactl lists $SCRATCH/sinks and the streams in
# $SCRATCH/inputs, and logs what it is told to do; restarting the unit brings
# the tuning's sink, unless $SCRATCH/no-sink is there; nova-audio-output-sink
# says the tuning plays into $SCRATCH/into.
speakers=alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Speaker__sink

p1_up() {
  echo "ThinkPad P1 Gen 4i" >"$NOVA_DMI_PATH/product_family"
  ln -s "$REPO_ROOT/data/audio/filter-chain-host.conf" "$NOVA_PATH/default/audio/filter-chain-host.conf"
  printf '50\t%s\tPipeWire\ts24le 2ch 48000Hz\tRUNNING\n' "$speakers" >"$SCRATCH/sinks"
  echo "$speakers" >"$SCRATCH/into"
  printf '%s\n' 'Sink Input #7' '	application.name = "Firefox"' 'Sink Input #9' '	media.name = "filter"' \
    'Sink Input #11' '	application.name = "EasyEffects"' 'Sink Input #12' '	application.name = "mpv"' >"$SCRATCH/inputs"
  cat >"$SCRATCH/bin/pactl" <<'STUB'
#!/bin/bash
case "$*" in
  "list sinks short") cat "$SCRATCH/sinks" ;;
  "list sink-inputs") cat "$SCRATCH/inputs" ;;
  "get-default-sink") echo "$DEFAULT_SINK" ;;
  *) echo "pactl $*" >>"$SCRATCH/calls" ;;
esac
STUB
  cat >"$SCRATCH/bin/systemctl" <<'STUB'
#!/bin/bash
echo "systemctl $*" >>"$SCRATCH/calls"
case "$*" in
  "--user restart nova-speaker-tuning.service")
    [[ -e $SCRATCH/no-sink ]] || printf '60\tnova_speaker_tuning\tPipeWire\tfloat32le 2ch 48000Hz\tIDLE\n' >>"$SCRATCH/sinks" ;;
  "--user is-active --quiet nova-speaker-tuning.service" | "--user is-enabled --quiet nova-speaker-tuning.service") [[ -e $SCRATCH/unit-up ]] ;;
  "--user is-active nova-speaker-tuning.service") echo inactive; exit 3 ;;
  "--user is-enabled nova-speaker-tuning.service") echo disabled; exit 1 ;;
  *easyeffects*) exit 3 ;;
esac
STUB
  printf '#!/bin/sh\ncat "%s/into"\n' "$SCRATCH" >"$SCRATCH/bin/nova-audio-output-sink"
  chmod +x "$SCRATCH/bin"/*
  export DEFAULT_SINK=$speakers
}

@test "match and status: the tuning for this laptop, and how it stands" {
  p1_up
  run "$tuning" match
  [ "$output" = "$NOVA_PATH/default/audio/tunings/thinkpad-p1-gen4i" ]
  run "$tuning" status
  [ "$status" -eq 0 ]
  [ "$output" = "Installed:      no
Service:        inactive, disabled
Tuning sink:    not there
Default output: $speakers
This laptop's:  ThinkPad P1 Gen 4i speakers (thinkpad-p1-gen4i)" ]
}

@test "on: the graph made for the speakers, the unit started, and what plays moved onto it" {
  p1_up
  run "$tuning" on
  [ "$status" -eq 0 ]
  [[ $output == *"Speaker tuning installed: ThinkPad P1 Gen 4i speakers"* ]]
  [[ $output == *"The speakers play through the tuning now."* ]]
  cmp "$REPO_ROOT/data/audio/filter-chain-host.conf" "$XDG_CONFIG_HOME/pipewire/nova-speaker-tuning.conf"
  graph=$XDG_CONFIG_HOME/pipewire/nova-speaker-tuning.conf.d/90-tuning.conf
  grep -q "target.object = \"$speakers\"" "$graph"
  fails grep -q @SPEAKER_SINK@ "$graph"
  [ "$(grep -v -e is-active -e is-enabled "$SCRATCH/calls")" = "systemctl --user enable nova-speaker-tuning.service
systemctl --user restart nova-speaker-tuning.service
pactl set-default-sink nova_speaker_tuning
pactl move-sink-input 7 nova_speaker_tuning
pactl move-sink-input 12 nova_speaker_tuning" ]
  # Run again with all of it current, it is left as it is.
  touch "$SCRATCH/unit-up"
  : >"$SCRATCH/calls"
  run "$tuning" on
  [ "$output" = "The speaker tuning is up to date: ThinkPad P1 Gen 4i speakers" ]
  fails grep -q -e "user enable " -e restart "$SCRATCH/calls"
}

@test "on: a tuning whose sink does not come, or that plays elsewhere, is taken out again" {
  p1_up
  touch "$SCRATCH/no-sink"
  run "$tuning" on
  [ "$status" -eq 1 ]
  [[ $output == *"did not come up"* ]]
  grep -q 'systemctl --user disable --now nova-speaker-tuning.service' "$SCRATCH/calls"
  [ ! -e "$XDG_CONFIG_HOME/pipewire/nova-speaker-tuning.conf" ]
  rm "$SCRATCH/no-sink" "$SCRATCH/calls"
  printf '50\t%s\tPipeWire\ts24le 2ch 48000Hz\tRUNNING\n' "$speakers" >"$SCRATCH/sinks"
  echo alsa_output.usb-headset >"$SCRATCH/into"
  run "$tuning" on
  [ "$status" -eq 1 ]
  [[ $output == *"played into alsa_output.usb-headset"* ]]
  grep -q 'systemctl --user disable --now nova-speaker-tuning.service' "$SCRATCH/calls"
  fails grep -q set-default-sink "$SCRATCH/calls"
}

@test "on: EasyEffects in the way is said, and nothing is installed" {
  p1_up
  printf '70\teasyeffects_sink\tPipeWire\tfloat32le 2ch 48000Hz\tIDLE\n' >>"$SCRATCH/sinks"
  run "$tuning" on
  [ "$status" -eq 1 ]
  [[ $output == *"EasyEffects is running"* ]]
  [ ! -e "$XDG_CONFIG_HOME/pipewire/nova-speaker-tuning.conf" ]
}

@test "fronted-sink: the speakers, while the tuning is up in front of them" {
  p1_up
  run "$tuning" fronted-sink
  [ "$status" -eq 1 ]
  printf '60\tnova_speaker_tuning\tPipeWire\tfloat32le 2ch 48000Hz\tIDLE\n' >>"$SCRATCH/sinks"
  run "$tuning" fronted-sink
  [ "$status" -eq 0 ]
  [ "$output" = "$speakers" ]
}

@test "off: the speakers made the default again, and what plays moved back" {
  p1_up
  mkdir -p "$XDG_CONFIG_HOME/pipewire/nova-speaker-tuning.conf.d"
  : >"$XDG_CONFIG_HOME/pipewire/nova-speaker-tuning.conf"
  : >"$XDG_CONFIG_HOME/pipewire/nova-speaker-tuning.conf.d/90-tuning.conf"
  run "$tuning" off
  [ "$status" -eq 0 ]
  [ "$output" = "The speaker tuning is taken out." ]
  [ ! -e "$XDG_CONFIG_HOME/pipewire/nova-speaker-tuning.conf.d" ]
  [ "$(cat "$SCRATCH/calls")" = "systemctl --user disable --now nova-speaker-tuning.service
pactl set-default-sink $speakers
pactl move-sink-input 7 $speakers
pactl move-sink-input 12 $speakers" ]
}
