#!/usr/bin/env bats

load ../test_helper

setup() {
  setup_scratch
  export COLUMNS=80
  UI_NOTES=$SCRATCH/notes
  # shellcheck source=installer/ui.bash
  source "$REPO_ROOT/installer/ui.bash"
}

teardown() { teardown_scratch; }

plain() { sed $'s/\e\\[[0-9;]*m//g'; }

@test "centering: a multiline block keeps its own indentation at a wide width" {
  run ui_center 80 abcd ' xy'
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%38sabcd\n%38s xy' '' '')" ]
}

@test "centering: an odd number of spare columns leaves the extra one on the right" {
  run ui_center 11 abcd xy
  [ "$status" -eq 0 ]
  [ "$output" = $'   abcd\n   xy' ]
}

@test "centering: an oversized block keeps the old left margin" {
  run ui_center 3 abcd xy
  [ "$status" -eq 0 ]
  [ "$output" = $'  abcd\n  xy' ]
  [ "$(ui_left 4 4)" -eq 0 ]
}

@test "centering: block glyphs, wide characters and combining marks use display columns" {
  [ "$(LC_ALL=C ui_width '██')" -eq 2 ]
  [ "$(ui_width '界')" -eq 2 ]
  [ "$(ui_width $'e\u0301')" -eq 1 ]
  run ui_center 8 '██' '界' $'e\u0301'
  [ "$output" = $'   ██\n   界\n   e\u0301' ]
}

@test "centering: terminal columns use a sane fallback without a tty" {
  [ "$(COLUMNS=101 ui_columns)" -eq 101 ]
  [ "$(COLUMNS=0 ui_columns)" -eq 80 ]
  [ "$(COLUMNS=-2 ui_columns)" -eq 80 ]
  [ "$(COLUMNS=invalid ui_columns)" -eq 80 ]
  [ "$(unset COLUMNS; ui_columns)" -eq 80 ]
}

@test "header: artwork moves as one block and notes use the same centering" {
  ui_wordmark() { printf '  *\nNOVA\n'; }
  UI_NOTES=$SCRATCH/notes
  printf 'Look again.\n' >"$UI_NOTES"
  ui_header Setup 2>"$SCRATCH/header"
  plain <"$SCRATCH/header" >"$SCRATCH/plain"
  [ "$(sed -n 2p "$SCRATCH/plain")" = "$(printf '%38s  *' '')" ]
  [ "$(sed -n 3p "$SCRATCH/plain")" = "$(printf '%38sNOVA' '')" ]
  [ "$(sed -n 5p "$SCRATCH/plain")" = "$(printf '%37sSetup' '')" ]
  [ "$(sed -n 6p "$SCRATCH/plain")" = "$(printf '%34sLook again.' '')" ]
  [ ! -s "$UI_NOTES" ]
}

@test "header: a narrow console uses a compact left aligned wordmark without wrapping" {
  COLUMNS=30
  ui_header Setup 2>"$SCRATCH/header"
  plain <"$SCRATCH/header" >"$SCRATCH/plain"
  [ "$(sed -n 2p "$SCRATCH/plain")" = '  nova' ]
  [ "$(ui_width "$(cat "$SCRATCH/plain")")" -le 30 ]
}

@test "header: the released single file USB writer renders the same centered screen" {
  "$REPO_ROOT/tools/inline-ui" >"$SCRATCH/nova-usb"
  local cols
  for cols in 80 35; do
    COLUMNS=$cols ui_header Setup 2>"$SCRATCH/expected"
    COLUMNS=$cols bash -c 'source "$1"; ui_header Setup' _ "$SCRATCH/nova-usb" 2>"$SCRATCH/actual"
    cmp "$SCRATCH/expected" "$SCRATCH/actual"
  done
}

@test "notes: multiline paragraphs keep a shared margin and stdout stays free" {
  ui_note $'abcd\n xy' >"$SCRATCH/stdout" 2>"$SCRATCH/note"
  [ ! -s "$SCRATCH/stdout" ]
  [ "$(plain <"$SCRATCH/note")" = "$(printf '%38sabcd\n%38s xy' '' '')" ]
}

@test "choices: only labels affect the width, with space for the cursor and gum help" {
  stub_gum answer
  ui_choose Pick '' $'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\tlong internal value ignored' >"$SCRATCH/answer"
  [ "$(cat "$SCRATCH/answer")" = answer ]
  grep -q -- '--padding 0 0 0 21 ' "$GUM_LOG"
  stub_gum $'one\ntwo'
  ui_choose_many Pick '' $'One\t1' $'Two\t2' >"$SCRATCH/answer"
  grep -q -- '--padding 0 0 0 10 ' "$GUM_LOG"
  grep -q -- '--selected-prefix \[x\]  --unselected-prefix \[ \]' "$GUM_LOG"
}

@test "input and secret: bounded fields are centered and answers stay on stdout" {
  stub_gum Ada secret
  [ "$(ui_input Name '' 'Your name')" = Ada ]
  [ "$(ui_secret Password)" = secret ]
  [ "$(grep -c -- '--width 40 --padding 0 0 0 20 ' "$GUM_LOG")" -eq 2 ]
  grep -q -- '^input --password' "$GUM_LOG"
  COLUMNS=25
  [ "$(ui_field_width Name '' 'Your name')" -eq 21 ]
  COLUMNS=1
  [ "$(ui_field_width Name '' '')" -eq 1 ]
}

@test "answers: they line up with each other and with the field under them" {
  ui_answered Name Ada 2>"$SCRATCH/answers"
  ui_answered Username ada 2>>"$SCRATCH/answers"
  [ "$(plain <"$SCRATCH/answers")" = "$(printf '%20sName          Ada\n%20sUsername      ada' '' '')" ]
}

@test "filter: measuring the list preserves its stdin and the selected answer" {
  stub_gum Europe/Rome
  printf 'UTC\nEurope/Rome\n' | ui_filter 'Time zone' >"$SCRATCH/answer"
  [ "$(cat "$SCRATCH/answer")" = Europe/Rome ]
  [ "$(cat "$GUM_LOG.filter")" = $'UTC\nEurope/Rome' ]
  grep -q -- '--width 40 --padding 0 0 0 18 ' "$GUM_LOG"
}

@test "box: centering includes the padding and square borders" {
  stub_gum
  ui_box abcd xy 2>/dev/null
  grep -q -- '--border normal ' "$GUM_LOG"
  grep -q -- '--padding 0 2 --margin 0 0 0 35 ' "$GUM_LOG"
}

@test "prompts: Esc returns, No stays false and Ctrl+C stops through ui_ask" {
  stub_gum '!1' '!1' '!130'
  run ui_input Name
  [ "$status" -eq 1 ]
  run ui_confirm Continue? no
  [ "$status" -eq 1 ]
  grep -q -- '--default=false' "$GUM_LOG"
  run ui_ask ui_choose Pick '' $'One\t1'
  [ "$status" -eq 130 ]
  [[ $output == *Stopped.* ]]
}
