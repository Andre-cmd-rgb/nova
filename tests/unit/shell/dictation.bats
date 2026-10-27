#!/usr/bin/env bats

# `nova dictation`, the speech side of the shell's dictation: whether it can
# start, the model's download and its checksum, a recording turned into text
# and deleted, and the text pasted through Hyprland. Every outside command is
# a stub that logs its call to $CALLS; the model is a small file of the
# test's own, with its size and SHA-256 put in place of Parakeet's.

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" XDG_DATA_HOME="$SCRATCH/data" XDG_RUNTIME_DIR="$SCRATCH/run"
  export CALLS="$SCRATCH/calls" SERVED="$SCRATCH/served"
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$SCRATCH/bin"
  printf 'a model of the test'"'"'s own\n' >"$SERVED"
  stub parakeet-cli 'echo "And so, my fellow Americans."'
  stub busctl 'echo "u 4"'
  stub nova-shell
  stub hyprctl
  stub wl-copy 'cat >"$SCRATCH/clipboard"'
  stub pw-record
  # The server: what was asked for after the part already there (-C -).
  stub curl 'out=""; while (($#)); do [[ $1 == -o ]] && out=$2; shift; done
    have=$(stat -c %s "$out" 2>/dev/null || echo 0)
    tail -c +$((have + 1)) "$SERVED" >>"$out"'
  export PATH="$SCRATCH/bin:$PATH"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/shell/plugins/dictation/bin/dictation"
  MODEL_URL=https://example.org/model.bin
  MODEL_BYTES=$(stat -c %s "$SERVED")
  MODEL_SHA256=$(sha256sum "$SERVED" | cut -d' ' -f1)
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

put_model() { mkdir -p "$DATA_DIR" && cp "$SERVED" "$MODEL"; }

@test "check: ready with the model, no-model without, and says when the connection is metered" {
  run cmd_check
  [ "$output" = no-model ]
  stub busctl 'echo "u 1"'
  run cmd_check
  [ "$output" = "no-model metered" ]
  stub busctl 'echo "u 3"'
  run cmd_check
  [ "$output" = "no-model metered" ]
  put_model
  run cmd_check
  [ "$output" = ready ]
}

@test "check: no-engine where there is no parakeet-cli (a Raspberry Pi)" {
  ENGINE=nova-test-no-such-engine
  put_model
  run cmd_check
  [ "$output" = no-engine ]
}

@test "setup downloads the model, checks it, moves it into place, and tells the shell" {
  run cmd_setup
  [ "$status" -eq 0 ]
  cmp "$SERVED" "$MODEL"
  [ ! -e "$MODEL.part" ]
  grep -qx "curl -fsSL --retry 3 -C - -o $MODEL.part https://example.org/model.bin" "$CALLS"
  grep -qx "nova-shell -q dictation refresh" "$CALLS"
  [[ $output == *"Dictation is ready"* ]]
}

@test "setup --progress prints what the shell's pill reads" {
  run cmd_setup --progress
  [ "$status" -eq 0 ]
  [ "${lines[-2]}" = "progress 100" ]
  [ "${lines[-1]}" = checking ]
}

@test "setup carries on from a part left by a stopped download" {
  mkdir -p "$DATA_DIR"
  head -c 7 "$SERVED" >"$MODEL.part"
  run cmd_setup
  [ "$status" -eq 0 ]
  cmp "$SERVED" "$MODEL"
}

@test "setup deletes a download that is not the model it knows, and fails" {
  MODEL_SHA256=0000000000000000000000000000000000000000000000000000000000000000
  run cmd_setup
  [ "$status" -ne 0 ]
  [[ $output == *"not the model Nova knows"* ]]
  [ ! -e "$MODEL" ]
  [ ! -e "$MODEL.part" ]
  fails grep -q "nova-shell" "$CALLS"
}

@test "setup with the model there downloads nothing" {
  put_model
  run cmd_setup
  [ "$status" -eq 0 ]
  fails grep -q "^curl" "$CALLS"
}

@test "remove deletes the model and a part, and tells the shell" {
  put_model
  touch "$MODEL.part"
  run cmd_remove
  [ "$status" -eq 0 ]
  [ ! -e "$DATA_DIR" ]
  grep -qx "nova-shell -q dictation refresh" "$CALLS"
}

@test "record: 16 kHz mono into a private directory, as pw-record itself" {
  run cmd_record "$XDG_RUNTIME_DIR/nova/dictation/1.wav"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$XDG_RUNTIME_DIR/nova/dictation")" = 700 ]
  grep -q "^pw-record --rate 16000 --channels 1 --format s16 .* $XDG_RUNTIME_DIR/nova/dictation/1.wav$" "$CALLS"
}

@test "transcribe prints the words and deletes the recording" {
  put_model
  touch "$XDG_RUNTIME_DIR/1.wav"
  run cmd_transcribe "$XDG_RUNTIME_DIR/1.wav"
  [ "$status" -eq 0 ]
  [ "$output" = "And so, my fellow Americans." ]
  [ ! -e "$XDG_RUNTIME_DIR/1.wav" ]
  grep -q "^parakeet-cli -m $MODEL -f $XDG_RUNTIME_DIR/1.wav -t [0-9]* -ng -np$" "$CALLS"
}

@test "transcribe deletes the recording when the engine fails, and says why" {
  put_model
  stub parakeet-cli 'echo "failed to read audio" >&2; exit 3'
  touch "$XDG_RUNTIME_DIR/1.wav"
  run cmd_transcribe "$XDG_RUNTIME_DIR/1.wav"
  [ "$status" -ne 0 ]
  [[ $output == *"the speech engine failed: failed to read audio"* ]]
  [ ! -e "$XDG_RUNTIME_DIR/1.wav" ]
}

@test "transcribe without a model fails, and still deletes the recording" {
  touch "$XDG_RUNTIME_DIR/1.wav"
  run cmd_transcribe "$XDG_RUNTIME_DIR/1.wav"
  [ "$status" -ne 0 ]
  [[ $output == *"nova dictation setup"* ]]
  [ ! -e "$XDG_RUNTIME_DIR/1.wav" ]
}

@test "insert puts the text on the clipboard and has Hyprland press Ctrl+V, down then up" {
  stub hyprctl '[[ $1 == activewindow ]] && echo "{\"class\":\"google-chrome\",\"tags\":[\"default-opacity*\"]}"; true'
  run cmd_insert "Hola, ¿qué tal? "
  [ "$status" -eq 0 ]
  [ "$(cat "$SCRATCH/clipboard")" = "Hola, ¿qué tal? " ]
  [ "$(grep dispatch "$CALLS")" = "$(printf '%s\n' \
    'hyprctl dispatch hl.dsp.send_key_state({ mods = "CTRL", key = "V", state = "down" })' \
    'hyprctl dispatch hl.dsp.send_key_state({ mods = "CTRL", key = "V", state = "up" })')" ]
}

@test "insert into a terminal pastes with Shift+Insert, as SUPER + V does" {
  stub hyprctl '[[ $1 == activewindow ]] && echo "{\"class\":\"foot\",\"tags\":[\"terminal*\"]}"; true'
  run cmd_insert "ls -la"
  [ "$status" -eq 0 ]
  grep -qx 'hyprctl dispatch hl.dsp.send_key_state({ mods = "SHIFT", key = "Insert", state = "down" })' "$CALLS"
}

@test "insert with nothing to say pastes nothing" {
  run cmd_insert ""
  [ "$status" -eq 0 ]
  [ ! -e "$CALLS" ]
}

@test "threads: one per core, eight at most" {
  stub lscpu 'printf "# Core\n0\n0\n1\n1\n2\n2\n3\n3\n"'
  [ "$(threads)" = 4 ]
  stub lscpu 'seq 0 15'
  [ "$(threads)" = 8 ]
}
