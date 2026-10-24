# shellcheck shell=bash
# installer/ui.bash: how Nova's setup screens look, for nova usb and for the
# installer on the stick. The wordmark sits on top and one question at a time
# below it, asked with gum (github.com/charmbracelet/gum), as Omarchy's
# installer asks.
#
# Every ui_ prompt prints its answer on stdout and returns gum's status: 0 for
# an answer, 1 for Esc (or No), 130 for Ctrl+C. ui_ask runs one and keeps the
# answer in REPLY, so a script can step back on Esc and stop on Ctrl+C.
#
# Colours are the terminal's own sixteen and the glyphs are ones the Linux
# console's font has (no rounded corners, » for the cursor), so the stick's
# text console and any terminal agree: white for what matters, grey for the
# rest, yellow for a warning. Sourced, never run.

UI_BRIGHT=15
UI_MUTED=8

# Count terminal columns, including wide and combining characters, not bytes.
ui_width() { printf '%s\n' "$@" | LC_ALL=C.UTF-8 wc -L; }

ui_columns() {
  local cols=${COLUMNS:-}
  if [[ -t 2 ]]; then
    cols=$(tput cols 2>/dev/null) || cols=${COLUMNS:-80}
  fi
  if [[ $cols =~ ^[1-9][0-9]{0,3}$ ]]; then echo "$cols"; else echo 80; fi
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

ui_text() { # colour line...
  local colour=$1
  shift
  ui_center "$(ui_columns)" "$@" | sed $'s/^/\e['"$colour"$'m/; s/$/\e[0m/' >&2
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

# A fresh screen: the wordmark, a grey line saying where you are, and any
# warnings given since the last screen (UI_NOTES names a file collecting them),
# which the clearing would otherwise take away.
ui_header() { # [line]
  local wordmark cols
  cols=$(ui_columns)
  wordmark=$(ui_wordmark)
  # A compact mark keeps the artwork from wrapping on a narrow console.
  if (( $(ui_width "$wordmark") > cols )); then
    wordmark="$(printf '  \e[1mnova\e[0m\n')"
  else
    wordmark=$(ui_center "$cols" "$wordmark" | sed $'s/^/\e[1m/; s/$/\e[0m/')
  fi
  [[ ! -t 2 ]] || printf '\e[H\e[2J' >&2
  {
    echo
    printf '%s\n' "$wordmark"
    echo
    [[ -z ${1:-} ]] || ui_note "$1"
    if [[ -s ${UI_NOTES:-} ]]; then
      ui_warn "$(cat -- "$UI_NOTES")"
      : >"$UI_NOTES"
    fi
    echo
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

ui_title() { ui_text 1 "$*"; }
ui_note() { ui_text 90 "$*"; }
ui_warn() { ui_text 33 "$*"; }
ui_error() { ui_text 31 "$*"; }

# What was answered stays on screen above the next question, the way a form
# reads. As wide as a field at least, so the answers line up with each other
# and with the question under them.
ui_answered() { # label value
  local width left
  width=$(ui_width "$(printf '%-13s %s' "$1" "$2")")
  ((width >= 40)) || width=40
  left=$(ui_left "$width")
  printf '%*s\e[90m%-13s\e[0m %s\n' "$left" '' "$1" "$2" >&2
}

# Give editable fields a steady width without filling the terminal. Headers
# and placeholders can widen it, but the field must still fit the console.
ui_field_width() { # header value placeholder
  local width cols
  cols=$(ui_columns)
  width=$(ui_width "$@")
  width=$((width + 2))
  ((width >= 40)) || width=40
  ((width <= cols - 4)) || width=$((cols > 4 ? cols - 4 : 1))
  echo "$width"
}

ui_input() { # question [value] [placeholder]
  local width left
  width=$(ui_field_width "$1" "${2:-}" "${3:-}")
  left=$(ui_left "$(ui_width "$1" "$(printf '%*s' "$width" '')")")
  gum input --header "$1" --prompt "» " --value "${2:-}" --placeholder "${3:-}" --char-limit 0 \
    --width "$width" --padding "0 0 0 $left" \
    --header.foreground "$UI_BRIGHT" --prompt.foreground "$UI_BRIGHT" --cursor.foreground "$UI_BRIGHT" \
    --placeholder.foreground "$UI_MUTED"
}

ui_secret() { # question [placeholder]
  local width left
  width=$(ui_field_width "$1" "" "${2:-}")
  left=$(ui_left "$(ui_width "$1" "$(printf '%*s' "$width" '')")")
  gum input --password --header "$1" --prompt "» " --placeholder "${2:-}" --char-limit 0 \
    --width "$width" --padding "0 0 0 $left" \
    --header.foreground "$UI_BRIGHT" --prompt.foreground "$UI_BRIGHT" --cursor.foreground "$UI_BRIGHT" \
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

# Gum's help takes room too. Values behind a label never affect its width.
ui_choice_left() { # prefix header help option...
  local prefix=$1 header=$2 help=$3 option labels=()
  shift 3
  for option; do labels+=("$prefix${option%%$'\t'*}"); done
  ui_left "$(ui_width "$header" "$help" "${labels[@]}")"
}

# Options are "label<TAB>value": the label is shown, the value printed. A
# label holds no comma, since gum splits --selected on them.
ui_choose() { # header selected-label option...
  local header=$1 selected=$2 left args=()
  shift 2
  left=$(ui_choice_left '» ' "$header" '←↓↑→ navigate • enter submit' "$@")
  [[ -z $selected ]] || args+=(--selected "$selected")
  gum choose --header "$header" --label-delimiter $'\t' --height 14 --cursor "» " --padding "0 0 0 $left" \
    --header.foreground "$UI_BRIGHT" --cursor.foreground "$UI_BRIGHT" --selected.foreground "$UI_BRIGHT" \
    "${args[@]}" "$@"
}

# The same, ticking any number with Space; prints the values, one per line.
ui_choose_many() { # header selected-labels(newline-separated) option...
  local header=$1 selected left args=()
  selected=$(paste -sd, - <<<"$2")
  shift 2
  left=$(ui_choice_left '» [ ] ' "$header" 'x toggle • ←↓↑→ navigate • enter submit • ctrl+a select all' "$@")
  [[ -z $selected ]] || args+=(--selected "$selected")
  gum choose --no-limit --header "$header" --label-delimiter $'\t' --height 20 --cursor "» " --padding "0 0 0 $left" \
    --selected-prefix "[x] " --unselected-prefix "[ ] " --cursor-prefix "[ ] " \
    --header.foreground "$UI_BRIGHT" --cursor.foreground "$UI_BRIGHT" --selected.foreground "$UI_BRIGHT" \
    "${args[@]}" "$@"
}

# A long list, narrowed by typing; the lines come on stdin.
ui_filter() { # header [placeholder]
  local options=() left width
  mapfile -t options
  width=$(ui_field_width "$1" "${options[@]}" "${2:-Type to narrow the list}")
  left=$(ui_choice_left '» ' "$1" '↓↑ navigate • esc blur search • enter submit' "${options[@]}" "${2:-Type to narrow the list}")
  printf '%s\n' "${options[@]}" | gum filter --header "$1" --placeholder "${2:-Type to narrow the list}" --height 14 --indicator "»" \
    --prompt "» " --width "$width" --padding "0 0 0 $left" \
    --header.foreground "$UI_BRIGHT" --indicator.foreground "$UI_BRIGHT" --match.foreground "$UI_BRIGHT"
}

ui_confirm() { # question [yes|no]: the default
  local left args=()
  left=$(ui_left "$(ui_width " $1" '←→ toggle • enter submit • y Yes • n No')")
  [[ ${2:-yes} == yes ]] || args+=(--default=false)
  gum confirm --affirmative Yes --negative No --padding "0 0 0 $left" --prompt.foreground "$UI_BRIGHT" \
    --selected.background "$UI_BRIGHT" --selected.foreground 0 \
    --unselected.background "$UI_MUTED" --unselected.foreground "$UI_BRIGHT" "${args[@]}" "$1"
}

# A framed summary, one argument per line.
ui_box() { # line...
  local left
  left=$(ui_left "$(( $(ui_width "$@") + 6 ))")
  gum style --border normal --border-foreground "$UI_MUTED" --padding "0 2" --margin "0 0 0 $left" "$@" >&2
}

# What is on a disk now, one line per partition: name, size, file system and
# label, so a backup drive is recognised before it is erased.
disk_contents() { # disk
  lsblk -J -o NAME,SIZE,FSTYPE,LABEL -- "$1" 2>/dev/null | jq -r '
    .blockdevices[0].children[]?
    | "\(.name)  \(.size)  \(.fstype // "no file system")\(if .label then "  \"\(.label)\"" else "" end)"'
}

# used of total as a bar of blocks, for "does it fit on the stick".
ui_bar() { # used total [width]
  local used=$1 total=$2 width=${3:-32} i bar=''
  ((total > 0)) || total=1
  for ((i = 0; i < width; i++)); do
    if ((i * total < used * width)); then bar+='█'; else bar+='░'; fi
  done
  printf '%s' "$bar"
}
