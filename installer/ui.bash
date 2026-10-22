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
  [[ ! -t 2 ]] || printf '\e[H\e[2J' >&2
  {
    echo
    ui_wordmark | sed $'s/^/  \e[1m/; s/$/\e[0m/'
    echo
    [[ -z ${1:-} ]] || printf '  \e[90m%s\e[0m\n' "$1"
    if [[ -s ${UI_NOTES:-} ]]; then
      sed $'s/^/  \e[33m/; s/$/\e[0m/' "$UI_NOTES"
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
    printf '\n  %s\n' "${UI_STOPPED:-Stopped.}" >&2
    exit 130
  fi
  return "$status"
}

ui_title() { printf '  \e[1m%s\e[0m\n' "$*" >&2; }
ui_note() { printf '  \e[90m%s\e[0m\n' "$*" >&2; }
ui_warn() { printf '  \e[33m%s\e[0m\n' "$*" >&2; }

# What was answered stays on screen above the next question, the way a form
# reads.
ui_answered() { # label value
  printf '  \e[90m%-13s\e[0m %s\n' "$1" "$2" >&2
}

ui_input() { # question [value] [placeholder]
  gum input --header "  $1" --prompt "  » " --value "${2:-}" --placeholder "${3:-}" --char-limit 0 \
    --header.foreground "$UI_BRIGHT" --prompt.foreground "$UI_BRIGHT" --cursor.foreground "$UI_BRIGHT" \
    --placeholder.foreground "$UI_MUTED"
}

ui_secret() { # question [placeholder]
  gum input --password --header "  $1" --prompt "  » " --placeholder "${2:-}" --char-limit 0 \
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
      printf '  \e[33m%s\e[0m\n' "$( ((min > 1)) && echo "At least $min characters." || echo "It cannot be empty.")" >&2
    elif [[ $first != "$second" ]]; then
      printf '  \e[33m%s\e[0m\n' "Those did not match; once more." >&2
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
  gum choose --header "$header" --label-delimiter $'\t' --height 14 --cursor "» " --padding "0 2" \
    --header.foreground "$UI_BRIGHT" --cursor.foreground "$UI_BRIGHT" --selected.foreground "$UI_BRIGHT" \
    "${args[@]}" "$@"
}

# The same, ticking any number with Space; prints the values, one per line.
ui_choose_many() { # header selected-labels(newline-separated) option...
  local header=$1 selected args=()
  selected=$(paste -sd, - <<<"$2")
  shift 2
  [[ -z $selected ]] || args+=(--selected "$selected")
  gum choose --no-limit --header "$header" --label-delimiter $'\t' --height 20 --cursor "» " --padding "0 2" \
    --selected-prefix "[x] " --unselected-prefix "[ ] " --cursor-prefix "[ ] " \
    --header.foreground "$UI_BRIGHT" --cursor.foreground "$UI_BRIGHT" --selected.foreground "$UI_BRIGHT" \
    "${args[@]}" "$@"
}

# A long list, narrowed by typing; the lines come on stdin.
ui_filter() { # header [placeholder]
  gum filter --header "$1" --placeholder "${2:-Type to narrow the list}" --height 14 --indicator "»" \
    --header.foreground "$UI_BRIGHT" --indicator.foreground "$UI_BRIGHT" --match.foreground "$UI_BRIGHT"
}

ui_confirm() { # question [yes|no]: the default
  local args=()
  [[ ${2:-yes} == yes ]] || args+=(--default=false)
  gum confirm --affirmative Yes --negative No --padding "0 2" --prompt.foreground "$UI_BRIGHT" \
    --selected.background "$UI_BRIGHT" --selected.foreground 0 \
    --unselected.background "$UI_MUTED" --unselected.foreground "$UI_BRIGHT" "${args[@]}" "$1"
}

# A framed summary, one argument per line.
ui_box() { # line...
  gum style --border normal --border-foreground "$UI_MUTED" --padding "0 2" --margin "0 2" "$@" >&2
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
