#!/usr/bin/env bats

# `nova dictation`, the user's side of the shell's dictation: whether it can
# start, the model's download and its checksum, the last dictation's words,
# and the text pasted through Hyprland. Every outside command is a stub that
# logs its call to $CALLS; the model is a small file of the test's own, with
# its size and SHA-256 put in place of Parakeet's, and the speech engine a
# file of the test's own, which a stub nova-dictationd --engine finds usable.
# Recording and hearing are nova-dictationd's, and tested there
# (src/dictation; its engine check in tests/engine.rs).

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" XDG_DATA_HOME="$SCRATCH/data" XDG_RUNTIME_DIR="$SCRATCH/run"
  export CALLS="$SCRATCH/calls" SERVED="$SCRATCH/served"
  export NOVA_DICTATION_LIBRARY="$SCRATCH/libparakeet.so.1"
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$SCRATCH/bin"
  touch "$NOVA_DICTATION_LIBRARY"
  printf 'a model of the test'"'"'s own\n' >"$SERVED"
  stub busctl 'echo "u 4"'
  stub nova-shell
  stub nova-dictationd
  export NOVA_DICTATIOND="$SCRATCH/bin/nova-dictationd"
  stub hyprctl
  stub wl-copy 'cat >"$SCRATCH/clipboard"'
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

@test "check: no-engine where there is no speech engine" {
  ENGINE=$SCRATCH/no-such-libparakeet.so.1
  put_model
  run cmd_check
  [ "$output" = no-engine ]
  run cmd_status
  [[ $output == *"Not available here: dictation needs whisper-cpp"* ]]
}

@test "check: no-engine other where the speech engine is one nova-dictationd cannot use" {
  put_model
  run cmd_check
  [ "$output" = ready ]
  grep -qx "nova-dictationd --engine" "$CALLS"
  stub nova-dictationd 'echo "the speech engine is whisper.cpp \"1.10.0\", and dictation is made for 1.9.5: it is not used" >&2; exit 1'
  run cmd_check
  [ "$output" = "no-engine other" ]
  run cmd_status
  [[ $output == *'Not available here: the speech engine is whisper.cpp "1.10.0", and dictation is made for 1.9.5: it is not used.'* ]]
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

@test "setup with a speech engine nova-dictationd cannot use downloads nothing, and says why" {
  stub nova-dictationd 'echo "the speech engine is whisper.cpp \"1.10.0\", and dictation is made for 1.9.5: it is not used" >&2; exit 1'
  run cmd_setup --progress
  [ "$status" -ne 0 ]
  [[ $output == *'the speech engine is whisper.cpp "1.10.0", and dictation is made for 1.9.5'* ]]
  fails grep -q "^curl" "$CALLS"
  [ ! -e "$MODEL.part" ]
  # Nor, with the model there, does it say dictation is ready.
  put_model
  run cmd_setup
  [ "$status" -ne 0 ]
  [[ $output != *"already here"* ]]
  # And without an engine at all, the same.
  ENGINE=$SCRATCH/no-such-libparakeet.so.1
  run cmd_setup
  [ "$status" -ne 0 ]
  [[ $output == *"dictation needs whisper-cpp"* ]]
}

@test "setup with the model there downloads nothing" {
  put_model
  run cmd_setup
  [ "$status" -eq 0 ]
  fails grep -q "^curl" "$CALLS"
}

# Until $SCRATCH/release is there, as a download under way; ten seconds at
# most, should a test stop before it releases it. That is well past
# waits_for's three, so that a loaded machine never lets it end first.
held_download() {
  stub curl 'out=""; while (($#)); do [[ $1 == -o ]] && out=$2; shift; done
    touch "$SCRATCH/downloading"
    for ((n = 0; n < 200; n++)); do [[ -e $SCRATCH/release ]] && break; sleep 0.05; done
    '"${1:-}"'
    have=$(stat -c %s "$out" 2>/dev/null || echo 0)
    tail -c +$((have + 1)) "$SERVED" >>"$out"'
}

waits_for() { # file [pattern]: up to three seconds
  local i
  for ((i = 0; i < 60; i++)); do
    if [[ -e $1 ]] && { [[ -z ${2:-} ]] || grep -q "$2" "$1"; }; then return 0; fi
    sleep 0.05
  done
  return 1
}

@test "setup runs one download at a time: a second follows it, and the part is written once" {
  held_download
  cmd_setup >"$SCRATCH/first.out" 2>&1 &
  local first=$!
  waits_for "$SCRATCH/downloading"
  # Download in Settings while Super+D downloads: the second follows.
  cmd_setup --progress >"$SCRATCH/second.out" 2>&1 &
  local second=$!
  waits_for "$SCRATCH/second.out" '^progress '
  # Deleting it meanwhile is refused.
  run cmd_remove
  [ "$status" -ne 0 ]
  [[ $output == *"being downloaded"* ]]
  touch "$SCRATCH/release"
  wait "$first"
  wait "$second"
  [ "$(grep -c '^curl ' "$CALLS")" -eq 1 ]
  cmp "$SERVED" "$MODEL"
  # Nothing is left beside the model, and removing it leaves no folder.
  [ "$(ls -A "$DATA_DIR")" = "$(basename "$MODEL")" ]
  run cmd_remove
  [ "$status" -eq 0 ]
  [ ! -e "$DATA_DIR" ]
}

@test "a download that stops is carried on by the one that followed it" {
  # The first curl ends half-way, as when the pill's Esc stops it.
  held_download '[[ -e $SCRATCH/stopped ]] || { touch "$SCRATCH/stopped"; head -c 10 "$SERVED" >"$out"; exit 1; }'
  cmd_setup >"$SCRATCH/first.out" 2>&1 &
  local first=$!
  waits_for "$SCRATCH/downloading"
  cmd_setup --progress >"$SCRATCH/second.out" 2>&1 &
  local second=$!
  waits_for "$SCRATCH/second.out" '^progress '
  touch "$SCRATCH/release"
  fails wait "$first"
  wait "$second"
  [ "$(grep -c '^curl ' "$CALLS")" -eq 2 ]
  cmp "$SERVED" "$MODEL"
}

@test "remove deletes the model and a part, and tells the shell" {
  put_model
  touch "$MODEL.part"
  run cmd_remove
  [ "$status" -eq 0 ]
  [ ! -e "$DATA_DIR" ]
  grep -qx "nova-shell -q dictation refresh" "$CALLS"
}

@test "last prints the last dictation's words, and says when there are none" {
  run cmd_last
  [ "$status" -ne 0 ]
  [[ $output == *"no dictation yet"* ]]
  mkdir -p "$XDG_RUNTIME_DIR/nova/dictation"
  printf 'Meet me at six. ' >"$XDG_RUNTIME_DIR/nova/dictation/last"
  run cmd_last
  [ "$status" -eq 0 ]
  [ "$output" = "Meet me at six. " ]
}

@test "vocab makes a file of examples the first time, opens it, and keeps the user's after" {
  stub nova-launch-editor
  run cmd_vocab
  [ "$status" -eq 0 ]
  file=$HOME/.config/nova/dictation/vocab.toml
  [ "$VOCAB" = "$file" ]
  grep -qx "nova-launch-editor $file" "$CALLS"
  # Examples only: nothing is changed until the user says so.
  ! grep -v '^#' "$file" | grep -q .
  echo '"quick shell" = "Quickshell"' >>"$file"
  run cmd_vocab
  [ "$status" -eq 0 ]
  grep -qx '"quick shell" = "Quickshell"' "$file"
}

@test "insert puts the text on the clipboard and has Hyprland press Ctrl+V, down then up" {
  stub hyprctl '[[ $1 == activewindow ]] && echo "{\"class\":\"google-chrome\",\"tags\":[\"default-opacity*\"]}"; true'
  run cmd_insert "Hola, ¿qué tal? "
  [ "$status" -eq 0 ]
  [ "$(cat "$SCRATCH/clipboard")" = "Hola, ¿qué tal? " ]
  # Marked as a password manager marks one: the clipboard's history passes
  # it over.
  grep -qx "wl-copy --sensitive" "$CALLS"
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

@test "the model's size is said the same everywhere, as its bytes round to" {
  local script=$REPO_ROOT/src/shell/plugins/dictation/bin/dictation bytes size
  bytes=$(sed -n 's/^MODEL_BYTES=//p' "$script")
  size="$(((bytes + 500000) / 1000000)) MB"
  grep -qx "MODEL_SIZE=\"$size\"" "$script"
  grep -qF "setup     download the speech model ($size)" "$script"
  grep -qF "modelSize: \"$size\"" "$REPO_ROOT/src/shell/plugins/dictation/Dictation.qml"
  grep -qF "modelSize: \"$size\"" "$REPO_ROOT/src/shell/plugins/settings/DictationView.qml"
  grep -qF "the speech model, $size," "$REPO_ROOT/README.md"
  grep -qF "the speech model, $size," "$REPO_ROOT/site/index.html"
}
