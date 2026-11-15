# shellcheck shell=bash
# installer/ui.bash: how Nova's setup screens look, for nova usb and for the
# installer on the stick. Every screen is the same frame: the wordmark on
# top, in Nova's two colours, the steps under it (which are done, which one
# this is), and one question at a time below, asked with gum
# (github.com/charmbracelet/gum), in a column down the middle of the screen.
#
# Every ui_ prompt prints its answer on stdout and returns gum's status: 0 for
# an answer, 1 for Esc (or No), 130 for Ctrl+C. ui_ask runs one and keeps the
# answer in REPLY, so a script can step back on Esc and stop on Ctrl+C.
#
# Colours are the terminal's own sixteen, by what they mean (UI_ below). On
# the stick's own console they are Nova's (ui_console_begin), which also sets
# a font sized to the screen; in a terminal, the terminal's own are left as
# they are. The glyphs are ones the console's fonts all have, the kernel's own
# and Terminus's code page 437 set (no rounded corners, no check mark: √ is
# done, » the cursor). Sourced, never run.

# The sixteen colours by what they mean.
UI_TEXT=7
UI_BRIGHT=15
UI_MUTED=8
UI_ACCENT=5
UI_SECOND=6
UI_GOOD=2
UI_WARN=3
UI_ERROR=1

# Nova's own sixteen, slot by slot, for the stick's console: a night blue to
# draw on, its accent and second colour (the wordmark's, the screensaver's)
# in the magenta and cyan slots, and greys that read on it at a glance.
UI_PALETTE=(0d111e f48e9f 71d69f f2be62 91adff cba6ff 12bff4 c4c9d6
  6b7287 ffa8b5 80ebb0 ffd48a acc2ff e0c8ff 6fd6ff f4f6fb)

# The widest the column of questions gets, on a wide screen.
UI_FRAME_MAX=80

# The escape that writes in one of the sixteen.
ui_sgr() { # colour
  if (($1 < 8)); then printf '\e[%dm' $((30 + $1)); else printf '\e[%dm' $((82 + $1)); fi
}

# Count terminal columns, including wide and combining characters, not bytes,
# and leaving colours out.
ui_width() { printf '%s\n' "$@" | sed $'s/\e\\[[0-9;]*m//g' | LC_ALL=C.UTF-8 wc -L; }

# The size of the screen the prompts are drawn on, stderr. Not tput's: it asks
# stdin, and where a list comes on stdin (ui_filter) it answers 80, so the list
# sat to the left of a wider console.
ui_columns() {
  local cols=${COLUMNS:-} size
  if [[ -t 2 ]] && size=$(stty size <&2 2>/dev/null); then
    cols=${size#* }
  fi
  if [[ $cols =~ ^[1-9][0-9]{0,3}$ ]]; then echo "$cols"; else echo 80; fi
}

# Rows, the same way; with no terminal to ask, as many as the tallest screen
# needs.
ui_rows() {
  local rows=${LINES:-} size
  if [[ -t 2 ]] && size=$(stty size <&2 2>/dev/null); then
    rows=${size% *}
  fi
  if [[ $rows =~ ^[1-9][0-9]{0,3}$ ]]; then echo "$rows"; else echo 50; fi
}

# The column the questions, notes and answers are in: as wide as the screen
# less a margin, up to UI_FRAME_MAX, and in the middle.
ui_frame_width() { # [columns]
  local cols=${1:-$(ui_columns)} width
  width=$((cols - 4))
  ((width <= UI_FRAME_MAX)) || width=$UI_FRAME_MAX
  ((width >= 1)) || width=1
  echo "$width"
}

ui_margin() { # [columns]
  local cols=${1:-$(ui_columns)}
  echo $(((cols - $(ui_frame_width "$cols")) / 2))
}

# An oversized block keeps the old left margin rather than negative padding.
ui_left() { # block-width [columns]
  local width=$1 cols=${2:-$(ui_columns)}
  if ((width <= cols)); then echo $(((cols - width) / 2)); else echo 2; fi
}

# Keep every line's indentation, so artwork and tabular notes stay intact.
ui_center() { # columns line...
  local cols=$1 left line
  shift
  left=$(ui_left "$(ui_width "$@")" "$cols")
  while IFS= read -r line; do
    if [[ -n $line ]]; then printf '%*s%s\n' "$left" '' "$line"; else echo; fi
  done < <(printf '%s\n' "$@")
}

# Lines in one colour, at the column's left edge.
ui_text() { # colour line...
  local colour=$1 margin line
  shift
  margin=$(ui_margin)
  while IFS= read -r line; do
    if [[ -n $line ]]; then printf '%*s%s%s\e[0m\n' "$margin" '' "$(ui_sgr "$colour")" "$line"; else echo; fi
  done < <(printf '%s\n' "$@") >&2
  UI_GAP=0
}

ui_title() { ui_text "$UI_BRIGHT" "$(printf '\e[1m%s' "$*")"; }
ui_note() { ui_text "$UI_MUTED" "$*"; }
ui_warn() { ui_text "$UI_WARN" "$*"; }
ui_error() { ui_text "$UI_ERROR" "$*"; }
ui_good() { ui_text "$UI_GOOD" "$(printf '\e[1m%s' "$*")"; }

# A line of the column's width, to close off the top of the screen.
ui_rule() { # [columns]
  local cols=${1:-$(ui_columns)} width rule
  width=$(ui_frame_width "$cols")
  printf -v rule '%*s' "$width" ''
  printf '%*s%s%s\e[0m\n' "$(ui_margin "$cols")" '' "$(ui_sgr "$UI_MUTED")" "${rule// /─}"
}

# The wordmark: beside this file on the stick, or in the repository. A released
# nova-usb carries its own copy, inline (tools/build-iso).
ui_wordmark() {
  local here=${BASH_SOURCE[0]%/*} file
  for file in "$here/nova.txt" "$here/../theme/wordmark/nova.txt" /usr/share/nova/wordmark/nova.txt; do
    if [[ -r $file ]]; then
      cat -- "$file"
      return 0
    fi
  done
  echo nova
}

# The wordmark in the middle of the screen, the letters in the accent and the
# star in the second colour, as the screensaver draws it. The star is what
# stands above the letters, and everything in its columns below.
ui_mark() { # columns
  local cols=$1 art=() line star='' left lead LC_ALL=C.UTF-8
  mapfile -t art < <(ui_wordmark)
  for line in "${art[@]}"; do
    [[ $line == ' '* ]] || break
    lead=${line%%[! ]*}
    [[ -n $star && ${#lead} -ge $star ]] || star=${#lead}
  done
  [[ -n $star ]] || star=$(ui_width "${art[@]}")
  left=$(ui_left "$(ui_width "${art[@]}")" "$cols")
  for line in "${art[@]}"; do
    printf '%*s%s%s%s%s\e[0m\n' "$left" '' "$(ui_sgr "$UI_ACCENT")" "${line:0:star}" "$(ui_sgr "$UI_SECOND")" "${line:star}"
  done
}

# The steps of a setup, UI_TRAIL (one word each, in order), with the one this
# screen is UI_AT: √ for those done, » for this one, · for those to come. Too
# wide for the column, it is "Step 3 of 7  ·  Disk". A screen in none of the
# steps (one saying this computer is not ready) has none; UI_AT='*' ticks
# them all, once the last is done.
ui_trail() { # columns
  local cols=$1 steps=() i at=-1 out='' mark colour gap=''
  read -ra steps <<<"${UI_TRAIL:-}"
  for i in "${!steps[@]}"; do [[ ${steps[i]} != "${UI_AT:-}" ]] || at=$i; done
  [[ ${UI_AT:-} != '*' ]] || at=${#steps[@]}
  ((at >= 0 && ${#steps[@]})) || return 0
  for i in "${!steps[@]}"; do
    if ((i < at)); then
      mark='√' colour=$UI_ACCENT
    elif ((i == at)); then
      mark='»' colour=$UI_BRIGHT
    else
      mark='·' colour=$UI_MUTED
    fi
    out+="$gap$(ui_sgr "$colour")$mark ${steps[i]}"$'\e[0m'
    gap='   '
  done
  if (($(ui_width "$out") > $(ui_frame_width "$cols"))); then
    i=$((at < ${#steps[@]} ? at : ${#steps[@]} - 1))
    out="$(ui_sgr "$UI_MUTED")Step $((i + 1)) of ${#steps[@]}  ·  $(ui_sgr "$UI_BRIGHT")${steps[i]}"$'\e[0m'
  fi
  ui_center "$cols" "$out"
}

# A fresh screen: the wordmark, the steps (or a grey line saying where you
# are), a rule, and any warnings given since the last screen (UI_NOTES names
# a file collecting them), which the clearing would otherwise take away. A
# small screen has the name alone for a wordmark.
ui_header() { # [line]
  local cols rows art
  cols=$(ui_columns) rows=$(ui_rows)
  art=$(ui_wordmark)
  [[ ! -t 2 ]] || printf '\e[H\e[2J' >&2
  UI_GAP=0
  {
    echo
    if (($(ui_width "$art") + 2 <= cols && rows >= 34)); then
      ui_mark "$cols"
      ((rows < 40)) || echo
    else
      ui_center "$cols" "$(ui_sgr "$UI_ACCENT")"$'\e[1mnova\e[0m'
    fi
    echo
    [[ -z ${1:-} ]] || ui_center "$cols" "$(ui_sgr "$UI_MUTED")$1"$'\e[0m'
    ui_trail "$cols"
    ui_rule "$cols"
    echo
    if [[ -s ${UI_NOTES:-} ]]; then
      ui_warn "$(cat -- "$UI_NOTES")"
      : >"$UI_NOTES"
      echo
    fi
  } >&2
}

# Runs a ui_ prompt with its arguments and keeps the answer in REPLY. Returns 0
# for an answer and 1 for Esc; Ctrl+C ends the script, saying UI_STOPPED.
ui_ask() { # ui_function arg...
  local status
  REPLY=$("$@") && status=0 || status=$?
  if ((status == 130)); then
    echo >&2
    ui_note "${UI_STOPPED:-Stopped.}"
    exit 130
  fi
  return "$status"
}

# What was answered stays on screen above the next question, the way a form
# reads: the label in grey, the answer in white, lined up in the column.
ui_answered() { # label value
  printf '%*s%s%-13s\e[0m %s%s\e[0m\n' "$(ui_margin)" '' "$(ui_sgr "$UI_MUTED")" "$1" "$(ui_sgr "$UI_BRIGHT")" "$2" >&2
  UI_GAP=1
}

# A question under answers, or under a box, has a line between them; the
# question's own, so it goes with the question and the answers stay together.
# Text in between (a warning) sits right above the question again.
UI_GAP=0
ui_question() { # text
  if ((UI_GAP)); then printf '\n%s' "$1"; else printf '%s' "$1"; fi
}

# An editable field is as wide as the column, and never wider than the
# screen.
ui_field_width() {
  local cols
  cols=$(ui_columns)
  if ((cols > 4)); then ui_frame_width "$cols"; else echo 1; fi
}

ui_input() { # question [value] [placeholder]
  gum input --header "$(ui_question "$1")" --prompt "» " --value "${2:-}" --placeholder "${3:-}" --char-limit 0 \
    --width "$(ui_field_width)" --padding "0 0 0 $(ui_margin)" \
    --header.foreground "$UI_BRIGHT" --prompt.foreground "$UI_ACCENT" --cursor.foreground "$UI_ACCENT" \
    --placeholder.foreground "$UI_MUTED"
}

ui_secret() { # question [placeholder]
  gum input --password --header "$(ui_question "$1")" --prompt "» " --placeholder "${2:-}" --char-limit 0 \
    --width "$(ui_field_width)" --padding "0 0 0 $(ui_margin)" \
    --header.foreground "$UI_BRIGHT" --prompt.foreground "$UI_ACCENT" --cursor.foreground "$UI_ACCENT" \
    --placeholder.foreground "$UI_MUTED"
}

# A new password, typed twice, until both match and it is long enough.
ui_password() { # question [minimum-length]
  local first second min=${2:-1}
  while :; do
    first=$(ui_secret "$1") || return
    second=$(ui_secret "The same once more") || return
    if ((${#first} < min)); then
      ui_warn "$( ((min > 1)) && echo "At least $min characters." || echo "It cannot be empty.")"
    elif [[ $first != "$second" ]]; then
      ui_warn "Those did not match; once more."
    else
      printf '%s' "$first"
      return 0
    fi
  done
}

# Options are "label<TAB>value": the label is shown, the value printed. A
# label holds no comma, since gum splits --selected on them.
ui_choose() { # header selected-label option...
  local header=$1 selected=$2 args=()
  shift 2
  [[ -z $selected ]] || args+=(--selected "$selected")
  gum choose --header "$(ui_question "$header")" --label-delimiter $'\t' --height 14 --cursor "» " --padding "0 0 0 $(ui_margin)" \
    --header.foreground "$UI_BRIGHT" --cursor.foreground "$UI_ACCENT" --selected.foreground "$UI_BRIGHT" \
    --item.foreground "$UI_TEXT" "${args[@]}" "$@"
}

# The same, ticking any number with Space; prints the values, one per line.
ui_choose_many() { # header selected-labels(newline-separated) option...
  local header=$1 selected args=()
  selected=$(paste -sd, - <<<"$2")
  shift 2
  [[ -z $selected ]] || args+=(--selected "$selected")
  gum choose --no-limit --header "$(ui_question "$header")" --label-delimiter $'\t' --height 20 --cursor "» " --padding "0 0 0 $(ui_margin)" \
    --selected-prefix "[x] " --unselected-prefix "[ ] " --cursor-prefix "[ ] " \
    --header.foreground "$UI_BRIGHT" --cursor.foreground "$UI_ACCENT" --selected.foreground "$UI_BRIGHT" \
    --item.foreground "$UI_TEXT" "${args[@]}" "$@"
}

# A long list, narrowed by typing; the lines come on stdin.
ui_filter() { # header [placeholder]
  gum filter --header "$(ui_question "$1")" --placeholder "${2:-Type to narrow the list}" --height 14 --indicator "»" \
    --prompt "» " --width "$(ui_field_width)" --padding "0 0 0 $(ui_margin)" \
    --header.foreground "$UI_BRIGHT" --indicator.foreground "$UI_ACCENT" --match.foreground "$UI_ACCENT" \
    --prompt.foreground "$UI_ACCENT" --text.foreground "$UI_TEXT" --cursor-text.foreground "$UI_BRIGHT" \
    --placeholder.foreground "$UI_MUTED"
}

ui_confirm() { # question [yes|no]: the default
  local args=()
  [[ ${2:-yes} == yes ]] || args+=(--default=false)
  # gum's own margins, a column before the question and each button, would
  # put them one in from the rest of the column.
  gum confirm --affirmative Yes --negative No --padding "0 0 0 $(ui_margin)" \
    --prompt.foreground "$UI_BRIGHT" --prompt.margin 0 \
    --selected.background "$UI_ACCENT" --selected.foreground 0 --selected.margin "0 2 0 0" \
    --unselected.background "$UI_MUTED" --unselected.foreground "$UI_BRIGHT" --unselected.margin "0 2 0 0" \
    "${args[@]}" "$(ui_question "$1")"
}

# A framed summary, one argument per line, as wide as the column; colours in a
# line are kept.
ui_box() { # line...
  local width margin line rule pad muted
  width=$(ui_frame_width)
  margin=$(ui_margin)
  muted=$(ui_sgr "$UI_MUTED")
  for line; do
    (($(ui_width "$line") + 6 <= width)) || width=$(($(ui_width "$line") + 6))
  done
  printf -v rule '%*s' $((width - 2)) ''
  rule=${rule// /─}
  {
    printf '%*s%s┌%s┐\e[0m\n' "$margin" '' "$muted" "$rule"
    for line; do
      pad=$((width - 6 - $(ui_width "$line")))
      printf '%*s%s│\e[0m  %s\e[0m%*s  %s│\e[0m\n' "$margin" '' "$muted" "$line" "$pad" '' "$muted"
    done
    printf '%*s%s└%s┘\e[0m\n' "$margin" '' "$muted" "$rule"
  } >&2
  UI_GAP=1
}

# What is on a disk now, one line per partition: name, size, file system and
# label, so a backup drive is recognised before it is erased.
disk_contents() { # disk
  lsblk -J -o NAME,SIZE,FSTYPE,LABEL -- "$1" 2>/dev/null | jq -r '
    .blockdevices[0].children[]?
    | "\(.name)  \(.size)  \(.fstype // "no file system")\(if .label then "  \"\(.label)\"" else "" end)"'
}

# used of total as a bar of blocks, the part used in the accent: for "does it
# fit on the stick", and how far an install has come.
ui_bar() { # used total [width]
  local used=$1 total=$2 width=${3:-32} filled full empty
  ((total > 0)) || total=1
  ((used <= total)) || used=$total
  ((used >= 0)) || used=0
  filled=$((used * width / total))
  printf -v full '%*s' "$filled" ''
  printf -v empty '%*s' $((width - filled)) ''
  printf '%s%s%s%s\e[0m' "$(ui_sgr "$UI_ACCENT")" "${full// /█}" "$(ui_sgr "$UI_MUTED")" "${empty// /░}"
}

# ------------------------------------------------------------- the console
#
# The stick's own console, a Linux virtual terminal, is drawn in Nova's
# colours and in a font sized to the screen; never a terminal's, which are
# its owner's. The installer sets both when it starts there and gives the
# colours back when it leaves (ui_console_end); the font, as readable in the
# shell that follows, stays.

UI_FB=${NOVA_FB:-/sys/class/graphics/fb0}
UI_FONTS=${NOVA_CONSOLE_FONTS:-/usr/share/kbd/consolefonts}

# The terminal stderr is, when it is one of the console's.
ui_console_tty() {
  local tty
  tty=$(readlink -- "/proc/$$/fd/2" 2>/dev/null) || return 1
  [[ ${TERM:-} == linux && $tty =~ ^/dev/tty[0-9]+$ ]] || return 1
  echo "$tty"
}

# The Terminus console font for a screen of the size given, as setfont takes
# it: the largest that still gives 45 rows and 100 columns, so the text is
# about the same size on a 1080p and a 4K panel. Above 32 pixels, the biggest
# Terminus has, a font is shown doubled (setfont -d). Code page 437 (ter-i):
# the set the kernel's own font has, with the ▀ and ▄ the wordmark is drawn
# with, which the Latin-1 set (ter-1) lacks.
ui_console_font_for() { # width height
  local width=$1 height=$2 entry h w name best=''
  for entry in 12:6:ter-i12n 14:8:ter-i14b 16:8:ter-i16b 18:10:ter-i18b 20:10:ter-i20b 22:11:ter-i22b \
    24:12:ter-i24b 28:14:ter-i28b 32:16:ter-i32b 36:20:ter-i18b:d 40:20:ter-i20b:d 44:22:ter-i22b:d \
    48:24:ter-i24b:d 56:28:ter-i28b:d 64:32:ter-i32b:d; do
    IFS=: read -r h w name _ <<<"$entry"
    ((height / h >= 45 && width / w >= 100)) && best=$entry
  done
  [[ -n $best ]] || best=12:6:ter-i12n
  IFS=: read -r _ _ name h <<<"$best"
  echo "$name${h:+ -d}"
}

# Sets the font for the screen's size, from the framebuffer's; a kernel that
# takes no doubled font gets the largest plain one.
ui_console_font() { # tty
  local size font
  size=$(cat -- "$UI_FB/virtual_size" 2>/dev/null) || return 0
  [[ $size =~ ^([0-9]+),([0-9]+)$ ]] || return 0
  font=$(ui_console_font_for "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}")
  [[ -r $UI_FONTS/${font%% *}.psf.gz ]] || return 0
  # shellcheck disable=SC2086 # the font and its -d
  setfont -C "$1" $font 2>/dev/null ||
    { [[ $font != *' -d' ]] || setfont -C "$1" ter-i32b 2>/dev/null; } || true
}

# On the console: Nova's colours and font, once for the installer and every
# program it starts (NOVA_CONSOLE), and a cleared screen in them.
ui_console_begin() {
  local tty i
  [[ -z ${NOVA_CONSOLE:-} ]] || return 0
  tty=$(ui_console_tty) || return 0
  ui_console_font "$tty"
  for i in "${!UI_PALETTE[@]}"; do printf '\e]P%x%s' "$i" "${UI_PALETTE[i]}"; done >&2
  printf '\e[0m\e[H\e[2J' >&2
  export NOVA_CONSOLE=$$
}

# The kernel's colours back, by the program that set Nova's. What is on the
# screen stays, the last thing said with it.
ui_console_end() {
  [[ ${NOVA_CONSOLE:-} == "$$" ]] || return 0
  printf '\e[0m\e]R' >&2
  unset NOVA_CONSOLE
}
