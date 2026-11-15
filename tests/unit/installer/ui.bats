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
  # A combining accent, as its UTF-8 bytes: bash turns $'\u0301' into
  # characters only in a UTF-8 locale, and a build container may have none.
  [ "$(ui_width $'e\xcc\x81')" -eq 1 ]
  run ui_center 8 '██' '界' $'e\xcc\x81'
  [ "$output" = $'   ██\n   界\n   e\xcc\x81' ]
}

@test "centering: terminal columns use a sane fallback without a tty" {
  [ "$(COLUMNS=101 ui_columns)" -eq 101 ]
  [ "$(COLUMNS=0 ui_columns)" -eq 80 ]
  [ "$(COLUMNS=-2 ui_columns)" -eq 80 ]
  [ "$(COLUMNS=invalid ui_columns)" -eq 80 ]
  [ "$(unset COLUMNS; ui_columns)" -eq 80 ]
}

@test "centering: the width is the terminal's, also for a list that comes on stdin" {
  # As ui_filter measures: the list on stdin, the answer captured, and no
  # COLUMNS, which a shell does not export to the scripts it runs. script(1)
  # gives it a terminal 200 columns wide.
  cat >"$SCRATCH/width" <<EOF
unset COLUMNS
stty cols 200 rows 50
source "$REPO_ROOT/installer/ui.bash"
cols=\$(echo list | ui_columns)
echo "\$cols"
EOF
  run script -qec "bash $SCRATCH/width" /dev/null
  [ "${output//$'\r'/}" = 200 ]
}

@test "header: the wordmark in the middle, then the step, a rule over the column, and the notes" {
  ui_wordmark() { printf '  *\nNOVA\n'; }
  UI_NOTES=$SCRATCH/notes
  printf 'Look again.\n' >"$UI_NOTES"
  ui_header Setup 2>"$SCRATCH/header"
  plain <"$SCRATCH/header" >"$SCRATCH/plain"
  [ "$(sed -n 2p "$SCRATCH/plain")" = "$(printf '%38s  *' '')" ]
  [ "$(sed -n 3p "$SCRATCH/plain")" = "$(printf '%38sNOVA' '')" ]
  [ "$(sed -n 6p "$SCRATCH/plain")" = "$(printf '%37sSetup' '')" ]
  # The column: 76 wide on 80 columns, from the third.
  [ "$(sed -n 7p "$SCRATCH/plain")" = "  $(printf '─%.0s' {1..76})" ]
  [ "$(sed -n 9p "$SCRATCH/plain")" = '  Look again.' ]
  [ ! -s "$UI_NOTES" ]
}

@test "header: the star in the second colour, the letters in the accent" {
  ui_wordmark() { printf '    *\nNOVA\n'; }
  ui_mark 8 >"$SCRATCH/mark"
  [ "$(sed -n 1p "$SCRATCH/mark")" = $' \e[35m    \e[36m*\e[0m' ]
  [ "$(sed -n 2p "$SCRATCH/mark")" = $' \e[35mNOVA\e[36m\e[0m' ]
}

@test "header: a narrow or short console has the name for a wordmark, without wrapping" {
  COLUMNS=30
  ui_header Setup 2>"$SCRATCH/header"
  plain <"$SCRATCH/header" >"$SCRATCH/plain"
  [ "$(sed -n 2p "$SCRATCH/plain")" = "$(printf '%13snova' '')" ]
  [ "$(ui_width "$(cat "$SCRATCH/plain")")" -le 30 ]
  COLUMNS=200 LINES=25 ui_header Setup 2>"$SCRATCH/header"
  [ "$(plain <"$SCRATCH/header" | sed -n 2p)" = "$(printf '%98snova' '')" ]
}

@test "header: the released single file USB writer renders the same screen" {
  "$REPO_ROOT/tools/inline-ui" >"$SCRATCH/nova-usb"
  local cols
  for cols in 80 35; do
    COLUMNS=$cols ui_header Setup 2>"$SCRATCH/expected"
    COLUMNS=$cols bash -c 'source "$1"; ui_header Setup' _ "$SCRATCH/nova-usb" 2>"$SCRATCH/actual"
    cmp "$SCRATCH/expected" "$SCRATCH/actual"
  done
}

@test "trail: the steps done, this one and those to come, in the middle" {
  UI_TRAIL="Keyboard Disk You" UI_AT=Disk
  ui_trail 80 >"$SCRATCH/trail"
  [ "$(plain <"$SCRATCH/trail")" = "$(printf '%26s√ Keyboard   » Disk   · You' '')" ]
  grep -q $'\e\\[35m√ Keyboard\e\\[0m   \e\\[97m» Disk' "$SCRATCH/trail"
  grep -q $'\e\\[90m· You' "$SCRATCH/trail"
}

@test "trail: too wide for the column, the step's number; in no step, nothing" {
  UI_TRAIL="Keyboard Network Disk You Computer Review Install" UI_AT=You
  [ "$(ui_trail 40 | plain)" = "$(printf '%10sStep 4 of 7  ·  You' '')" ]
  UI_AT=''
  [ -z "$(ui_trail 80)" ]
  UI_TRAIL='' UI_AT=You
  [ -z "$(ui_trail 80)" ]
}

@test "notes: multiline paragraphs keep the column's margin and stdout stays free" {
  ui_note $'abcd\n xy' >"$SCRATCH/stdout" 2>"$SCRATCH/note"
  [ ! -s "$SCRATCH/stdout" ]
  [ "$(plain <"$SCRATCH/note")" = $'  abcd\n   xy' ]
}

@test "choices: in the column, whatever the labels' width" {
  stub_gum answer
  ui_choose Pick '' $'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\tlong internal value ignored' >"$SCRATCH/answer"
  [ "$(cat "$SCRATCH/answer")" = answer ]
  grep -q -- '--padding 0 0 0 2 ' "$GUM_LOG"
  stub_gum $'one\ntwo'
  COLUMNS=200 ui_choose_many Pick '' $'One\t1' $'Two\t2' >"$SCRATCH/answer"
  grep -q -- '--padding 0 0 0 60 ' "$GUM_LOG"
  grep -q -- '--selected-prefix \[x\]  --unselected-prefix \[ \]' "$GUM_LOG"
}

@test "input and secret: fields as wide as the column, answers on stdout" {
  stub_gum Ada secret
  [ "$(ui_input Name '' 'Your name')" = Ada ]
  [ "$(ui_secret Password)" = secret ]
  [ "$(grep -c -- '--width 76 --padding 0 0 0 2 ' "$GUM_LOG")" -eq 2 ]
  grep -q -- '^input --password' "$GUM_LOG"
  COLUMNS=25
  [ "$(ui_field_width Name '' 'Your name')" -eq 21 ]
  COLUMNS=1
  [ "$(ui_field_width Name '' '')" -eq 1 ]
}

@test "answers: they line up with each other, and the next question has a line above it" {
  stub_gum Ada engine
  ui_answered Name Ada 2>"$SCRATCH/answers"
  ui_answered Username ada 2>>"$SCRATCH/answers"
  [ "$(plain <"$SCRATCH/answers")" = $'  Name          Ada\n  Username      ada' ]
  ui_input Password >/dev/null
  [ "$(sed -n 1p "$GUM_LOG")" = 'input --header ' ]
  [[ $(sed -n 2p "$GUM_LOG") == 'Password --prompt'* ]]
  # Text in between sits right above the question again.
  ui_warn 'Too short.' 2>/dev/null
  ui_input Password >/dev/null
  [[ $(sed -n 3p "$GUM_LOG") == 'input --header Password --prompt'* ]]
}

@test "filter: the list stays on its stdin, the answer on stdout" {
  stub_gum Europe/Rome
  printf 'UTC\nEurope/Rome\n' | ui_filter 'Time zone' >"$SCRATCH/answer"
  [ "$(cat "$SCRATCH/answer")" = Europe/Rome ]
  [ "$(cat "$GUM_LOG.filter")" = $'UTC\nEurope/Rome' ]
  grep -q -- '--width 76 --padding 0 0 0 2 ' "$GUM_LOG"
}

@test "box: as wide as the column, or as its longest line, square corners, colours kept" {
  ui_box abcd $'\e[33mxy\e[0m' 2>"$SCRATCH/box"
  [ "$(plain <"$SCRATCH/box" | sed -n 1p)" = "  ┌$(printf '─%.0s' {1..74})┐" ]
  [ "$(plain <"$SCRATCH/box" | sed -n 2p)" = "  │  abcd$(printf '%66s' '')  │" ]
  [ "$(plain <"$SCRATCH/box" | sed -n 3p)" = "  │  xy$(printf '%68s' '')  │" ]
  [ "$(plain <"$SCRATCH/box" | sed -n 4p)" = "  └$(printf '─%.0s' {1..74})┘" ]
  grep -q $'\e\\[33mxy' "$SCRATCH/box"
  local long
  printf -v long '%90s' x
  ui_box "$long" 2>"$SCRATCH/box"
  [ "$(ui_width "$(plain <"$SCRATCH/box" | sed -n 2p)")" -eq $((2 + 96)) ]
}

@test "bar: the part used in the accent, clamped to the whole" {
  [ "$(ui_bar 1 4 8 | plain)" = '██░░░░░░' ]
  [ "$(ui_bar 9 4 4 | plain)" = '████' ]
  [ "$(ui_bar 0 0 3 | plain)" = '░░░' ]
  [[ $(ui_bar 1 2 2) == $'\e[35m█\e[90m░'* ]]
}

@test "console font: about 45 rows and 100 columns, on any screen" {
  [ "$(ui_console_font_for 1920 1080)" = ter-i24b ]
  [ "$(ui_console_font_for 3840 2160)" = 'ter-i24b -d' ]
  [ "$(ui_console_font_for 3840 2400)" = 'ter-i24b -d' ]
  [ "$(ui_console_font_for 2560 1600)" = ter-i32b ]
  [ "$(ui_console_font_for 1366 768)" = ter-i16b ]
  [ "$(ui_console_font_for 1280 800)" = ter-i16b ]
  [ "$(ui_console_font_for 800 600)" = ter-i12n ]
  [ "$(ui_console_font_for 640 480)" = ter-i12n ]
}

@test "console: never in a terminal, and once for the installer and what it starts" {
  TERM=xterm-256color ui_console_begin 2>"$SCRATCH/out"
  [ ! -s "$SCRATCH/out" ]
  [ -z "${NOVA_CONSOLE:-}" ]
  ui_console_tty() { echo /dev/tty1; }
  NOVA_CONSOLE=1 ui_console_begin 2>"$SCRATCH/out"
  [ ! -s "$SCRATCH/out" ]
}

@test "console: Nova's colours and a font for the screen, and the kernel's colours back" {
  ui_console_tty() { echo /dev/tty1; }
  mkdir -p "$SCRATCH/fb" "$SCRATCH/fonts" "$SCRATCH/bin"
  echo 3840,2160 >"$SCRATCH/fb/virtual_size"
  touch "$SCRATCH/fonts/ter-i24b.psf.gz"
  UI_FB=$SCRATCH/fb UI_FONTS=$SCRATCH/fonts
  # A kernel that takes no doubled font gets the largest plain one.
  printf '#!/bin/bash\necho "$*" >>"%s/setfont.log"\n[[ $* != *-d ]]\n' "$SCRATCH" >"$SCRATCH/bin/setfont"
  chmod +x "$SCRATCH/bin/setfont"
  PATH=$SCRATCH/bin:$PATH ui_console_begin 2>"$SCRATCH/out"
  [ "$(cat "$SCRATCH/setfont.log")" = $'-C /dev/tty1 ter-i24b -d\n-C /dev/tty1 ter-i32b' ]
  grep -qF $'\e]P00d111e' "$SCRATCH/out"
  grep -qF $'\e]P5cba6ff' "$SCRATCH/out"
  grep -qF $'\e]Pff4f6fb' "$SCRATCH/out"
  [ "$NOVA_CONSOLE" = "$$" ]
  ui_console_end 2>"$SCRATCH/out"
  [ "$(cat "$SCRATCH/out")" = $'\e[0m\e]R' ]
  [ -z "${NOVA_CONSOLE:-}" ]
  # Only the program that set them gives them back.
  NOVA_CONSOLE=1 ui_console_end 2>"$SCRATCH/out"
  [ ! -s "$SCRATCH/out" ]
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
