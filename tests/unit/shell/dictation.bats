#!/usr/bin/env bats

# `nova dictation`, the speech side of the shell's dictation: whether it can
# start, the model's download and its checksum, a recording heard from a
# second on, in pieces that end at a sentence's end, and deleted at the last,
# and the text pasted through Hyprland. Every outside command is a stub that
# logs its call to $CALLS; the model is a small file of the test's own, with
# its size and SHA-256 put in place of Parakeet's, and the engine prints the
# words of the test's own, a line each with its time, as parakeet-cli -ps does.

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" XDG_DATA_HOME="$SCRATCH/data" XDG_RUNTIME_DIR="$SCRATCH/run"
  export CALLS="$SCRATCH/calls" SERVED="$SCRATCH/served"
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$SCRATCH/bin"
  printf 'a model of the test'"'"'s own\n' >"$SERVED"
  stub parakeet-cli 'echo "And so, fellow. Ask U.S. not"
    while (($#)); do [[ $1 == -f ]] && cp "$2" "$SCRATCH/heard.wav"; shift; done
    cat "$SCRATCH/words" >&2'
  # The words with their times in hundredths of a second, as Parakeet prints
  # them: indices under 10 padded, the marks tokens of their own.
  word() { printf '  [%2d] id= 1 frame= 1 dur_idx= 1 dur_val= 1 p=1.0000 plog=-0.0000 t0=%4d t1=%4d word_start=%s "%s"\n' "$@"; }
  {
    echo "parakeet_model_load: loaded vocab with 8192 tokens"
    word 0 10 30 true "▁And"
    word 1 30 50 true "▁so"
    word 2 50 50 false ","
    word 3 60 80 true "▁fellow"
    word 4 80 80 false "."
    word 5 120 140 true "▁Ask"
    word 6 140 150 true "▁U"
    word 7 150 150 false "."
    word 8 152 160 false "S"
    word 9 160 160 false "."
    word 10 162 180 true "▁not"
  } >"$SCRATCH/words"
  stub busctl 'echo "u 4"'
  stub nova-shell
  stub hyprctl
  stub wl-copy 'cat >"$SCRATCH/clipboard"'
  stub pw-record
  stub nice 'shift 2; exec "$@"'
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

@test "check: no-engine where there is no parakeet-cli" {
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

@test "record: raw 16 kHz mono into a private directory, as pw-record itself" {
  run cmd_record "$XDG_RUNTIME_DIR/nova/dictation/1.pcm"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$XDG_RUNTIME_DIR/nova/dictation")" = 700 ]
  grep -q "^pw-record --raw --rate 16000 --channels 1 --format s16 .* $XDG_RUNTIME_DIR/nova/dictation/1.pcm$" "$CALLS"
}

recording() { # <seconds>: that much of a recording, of noise
  head -c "$(awk -v s="$1" 'BEGIN { printf "%d", s * 32000 }')" /dev/urandom >"$XDG_RUNTIME_DIR/1.pcm"
}

@test "transcribe prints the pieces that end a sentence with words after them, and the rest" {
  put_model
  recording 3
  run cmd_transcribe "$XDG_RUNTIME_DIR/1.pcm" 1.00
  [ "$status" -eq 0 ]
  # "so," has no pause after it, and "U.S." is no end: one piece, cut in the
  # middle of the pause before "Ask", 1 s in plus (0.80 + 1.20) / 2.
  [ "$output" = "$(printf 'end 3.00\npiece 2.00 sentence And so, fellow.\nrest Ask U.S. not')" ]
  grep -q "^parakeet-cli -m $MODEL -f .*\.wav -t [0-9]* -ng -ps$" "$CALLS"
}

@test "transcribe hears the recording from <from> on, as a WAV of 16 kHz mono" {
  put_model
  recording 2
  run cmd_transcribe "$XDG_RUNTIME_DIR/1.pcm" 0.5
  [ "$status" -eq 0 ]
  # 44 bytes of header, then the samples from 0.5 s, 16000 of them.
  [ "$(stat -c %s "$SCRATCH/heard.wav")" -eq $((44 + 48000)) ]
  [ "$(head -c 4 "$SCRATCH/heard.wav")" = RIFF ]
  [ "$(od -A n -t u4 -j 24 -N 4 "$SCRATCH/heard.wav" | tr -d ' ')" = 16000 ]
  [ "$(od -A n -t u4 -j 40 -N 4 "$SCRATCH/heard.wav" | tr -d ' ')" = 48000 ]
  cmp <(tail -c 48000 "$SCRATCH/heard.wav") <(tail -c +16001 "$XDG_RUNTIME_DIR/1.pcm")
}

@test "transcribe while listening keeps the recording, at a low priority; --last deletes it" {
  put_model
  recording 2
  run cmd_transcribe "$XDG_RUNTIME_DIR/1.pcm" 0
  [ "$status" -eq 0 ]
  [ -e "$XDG_RUNTIME_DIR/1.pcm" ]
  grep -q "^nice -n 10 parakeet-cli " "$CALLS"
  run cmd_transcribe "$XDG_RUNTIME_DIR/1.pcm" 0 --last
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_RUNTIME_DIR/1.pcm" ]
  grep -q "^nice -n 0 parakeet-cli " "$CALLS"
}

@test "a look runs on every core, as the end does" {
  put_model
  recording 2
  cmd_transcribe "$XDG_RUNTIME_DIR/1.pcm" 0 >/dev/null
  cmd_transcribe "$XDG_RUNTIME_DIR/1.pcm" 0 --last >/dev/null
  [ "$(grep -o -- '-t [0-9]*' "$CALLS" | sort -u | wc -l)" -eq 1 ]
  grep -q -- "-t $(threads) " "$CALLS"
}

@test "on battery the end runs with performance held, a look and the end plugged in do not" {
  put_model
  export NOVA_POWER_SUPPLIES="$SCRATCH/supplies"
  mkdir -p "$SCRATCH/supplies/AC" "$SCRATCH/supplies/BAT0"
  echo Mains >"$SCRATCH/supplies/AC/type"
  echo Battery >"$SCRATCH/supplies/BAT0/type"
  echo 0 >"$SCRATCH/supplies/AC/online"
  stub powerprofilesctl 'while [[ $1 != -- ]]; do shift; done; shift; exec "$@"'
  recording 2
  run cmd_transcribe "$XDG_RUNTIME_DIR/1.pcm" 0
  [ "$status" -eq 0 ]
  run grep -q '^powerprofilesctl' "$CALLS"
  [ "$status" -ne 0 ]
  run cmd_transcribe "$XDG_RUNTIME_DIR/1.pcm" 0 --last
  [ "$status" -eq 0 ]
  # Its words, through the hold, as without it.
  [ "$output" = "$(printf 'end 2.00\npiece 1.00 sentence And so, fellow.\nrest Ask U.S. not')" ]
  grep -qx 'powerprofilesctl launch --profile performance --reason Dictation --appid nova-dictation -- setpriv --pdeathsig TERM -- nice -n 0 parakeet-cli .*' "$CALLS"
  rm -f "$CALLS"
  echo 1 >"$SCRATCH/supplies/AC/online"
  recording 2
  run cmd_transcribe "$XDG_RUNTIME_DIR/1.pcm" 0 --last
  [ "$status" -eq 0 ]
  run grep -q '^powerprofilesctl' "$CALLS"
  [ "$status" -ne 0 ]
}

@test "transcribe of less than a third of a second asks the engine nothing" {
  put_model
  recording 1.2
  run cmd_transcribe "$XDG_RUNTIME_DIR/1.pcm" 1.0
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'end 1.20\nrest ')" ]
  ! grep -q "^parakeet-cli" "$CALLS"
}

@test "transcribe --last deletes the recording when the engine fails, and says why" {
  put_model
  stub parakeet-cli 'echo "failed to read audio" >&2; exit 3'
  recording 1
  run cmd_transcribe "$XDG_RUNTIME_DIR/1.pcm" 0 --last
  [ "$status" -ne 0 ]
  [[ $output == *"the speech engine failed: failed to read audio"* ]]
  [ ! -e "$XDG_RUNTIME_DIR/1.pcm" ]
}

@test "transcribe without a model fails, and with --last still deletes the recording" {
  recording 1
  run cmd_transcribe "$XDG_RUNTIME_DIR/1.pcm" 0 --last
  [ "$status" -ne 0 ]
  [[ $output == *"nova dictation setup"* ]]
  [ ! -e "$XDG_RUNTIME_DIR/1.pcm" ]
}

@test "transcribe refuses a place that is not a time" {
  put_model
  recording 1
  run cmd_transcribe "$XDG_RUNTIME_DIR/1.pcm" "1;rm"
  [ "$status" -ne 0 ]
  [[ $output == *"not a time in seconds"* ]]
  [ -e "$XDG_RUNTIME_DIR/1.pcm" ]
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

@test "the model's size is said the same everywhere, as its bytes round to" {
  local script=$REPO_ROOT/src/shell/plugins/dictation/bin/dictation bytes size
  bytes=$(sed -n 's/^MODEL_BYTES=//p' "$script")
  size="$(((bytes + 500000) / 1000000)) MB"
  grep -qx "MODEL_SIZE=\"$size\"" "$script"
  grep -qF "setup     download the speech model ($size)" "$script"
  grep -qF "modelSize: \"$size\"" "$REPO_ROOT/src/shell/plugins/dictation/Dictation.qml"
  grep -qF "the speech model, $size," "$REPO_ROOT/README.md"
}
