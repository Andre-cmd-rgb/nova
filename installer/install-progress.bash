# shellcheck shell=bash
# installer/install-progress.bash: the install's steps, each one timed into
# the log, and the view that shows them on the screen while they run.
# Sourced by nova-install, never run.

# ------------------------------------------------------------- the install
#
# Each step of the install is timed: its seconds go into the log as it ends,
# as a line of its own (STEP_LINE), and the log ends with a table of them all
# (step_table), so a slow install says where its time went.

STEP_LINE=':: nova-install step:'
STEP='' STEP_STARTED='' INSTALL_STARTED=''

# Microseconds since the epoch, whatever the locale's decimal point.
now_us() { echo "${EPOCHREALTIME//[!0-9]/}"; }

# Seconds since a now_us, to a tenth.
seconds_since() { # microseconds
  local us=$(($(now_us) - $1))
  printf '%d.%d' $((us / 1000000)) $((us / 100000 % 10))
}

log_step() { # label started-microseconds
  printf '%s %s: %s s\n' "$STEP_LINE" "$1" "$(seconds_since "$2")" >>"$LOG"
}

# Runs one step and logs how long it took. A step that fails under set -e
# ends the install where it is, and stopped (the ERR trap) names it.
step() { # label command...
  STEP=$1 STEP_STARTED=$(now_us)
  INSTALL_STARTED=${INSTALL_STARTED:-$STEP_STARTED}
  shift
  printf '\n==> %s\n' "$STEP" >>"$LOG"
  progress_event step "$STEP"
  "$@"
  local status=$?
  log_step "$STEP" "$STEP_STARTED"
  progress_event took "$STEP" "$(seconds_since "$STEP_STARTED")"
  return "$status"
}

# Every step's time, as the log has it, and the whole install's.
step_table() {
  local label seconds
  echo "The install's steps and their times:"
  while IFS=$'\t' read -r label seconds; do
    case $label in
      Packages:*) printf '    %-34s %7s s\n' "${label#Packages: }" "$seconds" ;;
      *) printf '  %-36s %7s s\n' "$label" "$seconds" ;;
    esac
  done < <(sed -n "s/^$STEP_LINE \\(.*\\): \\([0-9.]*\\) s\$/\\1\\t\\2/p" "$LOG")
  [[ -z $INSTALL_STARTED ]] || printf '  %-36s %7s s\n' "In all" "$(seconds_since "$INSTALL_STARTED")"
}

# ------------------------------------------------------------- the progress view
#
# On a screen, the install is one view while it runs, not every command's
# output scrolling by: its parts, ticked with their times as each is done;
# the one running with what it does now and its clock, and for the packages
# a bar, as pacman counts them. What would have scrolled by goes to the log.
# With an answers file, or no terminal, it is plain lines as before.
#
# One process draws the view (progress_view), the only one writing to the
# screen, so its clocks run on while a command says nothing for minutes. The
# install tells it what happens, a line at a time, over a pipe
# (progress_event): step and took (step's), say, info and warn (a part's
# words), part and count (pacstrap's), and end.

PROGRESS=0 PROGRESS_PID='' PROGRESS_ROWS=() PROGRESS_TITLE=()

# The part of the view a step is in.
progress_row() { # step label
  case $1 in
    "Checking the packages") echo "Checking the packages" ;;
    "Partitioning and formatting" | "Subvolumes and swap file" | "Boot configuration") echo "Preparing the disk" ;;
    "Packages, in all") echo "Installing the packages" ;;
    "System configuration" | Snapshots | Account | Fingerprint | "Your things" | Services) echo "Setting up the system" ;;
    "Boot loader") echo "Installing the boot loader" ;;
    Apps) echo "Installing the apps" ;;
    *) echo Finishing ;;
  esac
}

# The view's parts for this install: the packages are checked only online,
# the apps installed only when the answers do not say apps=no.
progress_rows() {
  PROGRESS_ROWS=()
  offline_repo_ready || PROGRESS_ROWS+=("Checking the packages")
  PROGRESS_ROWS+=("Preparing the disk" "Installing the packages" "Setting up the system" "Installing the boot loader")
  [[ $(answer_or apps yes) == no ]] || PROGRESS_ROWS+=("Installing the apps")
  PROGRESS_ROWS+=(Finishing)
}

progress_event() { # field...
  ((PROGRESS)) || return 0
  # A view that is gone reads nothing: the pipe would fill, and the install
  # wait at its next line for good. Its lines go to the screen again instead.
  if ! kill -0 "$PROGRESS_PID" 2>/dev/null; then
    PROGRESS=0
    exec 2>&8 8>&- 7>&-
    printf '\e[?25h\n' >&2
    return 0
  fi
  local IFS=$'\t' strip=$'\t\n'
  printf '%s\n' "${*//[$strip]/ }" >&7 2>/dev/null || true
}

# m:ss, or h:mm:ss, of a number of tenths of a second, into the variable named.
progress_clock() { # variable tenths
  local s=$(($2 / 10))
  if ((s >= 3600)); then
    printf -v "$1" '%d:%02d:%02d' $((s / 3600)) $((s / 60 % 60)) $((s % 60))
  else
    printf -v "$1" '%d:%02d' $((s / 60)) $((s % 60))
  fi
}

# The view: the header of the Install step, PROGRESS_TITLE under it, then a
# line for each part. Redrawn in place, never cleared, so it does not flicker;
# every second for the clocks, and on the install's news, at most ten times a
# second. It ends at the install's end event, with the view as it ended.
progress_view() {
  set +eu
  trap - ERR
  # Counted in characters, the √ and » too.
  local LC_ALL=C.UTF-8
  local cols rows hrows head kind a b c i at=-1 started now row_started last=0 detail='' part='' n=0 total=0 item=''
  local -a secs=() warnings=()
  local c_text c_bright c_muted c_accent c_warn c_error width margin
  cols=$(ui_columns) rows=$(ui_rows)
  # The view has to fit, or redrawing it in place would scroll: under 45
  # rows, the wordmark is the name alone.
  hrows=$rows
  ((rows >= 45)) || hrows=33
  width=$(ui_frame_width "$cols") margin=$(ui_margin "$cols")
  c_text=$(ui_sgr "$UI_TEXT") c_bright=$(ui_sgr "$UI_BRIGHT") c_muted=$(ui_sgr "$UI_MUTED")
  c_accent=$(ui_sgr "$UI_ACCENT") c_warn=$(ui_sgr "$UI_WARN") c_error=$(ui_sgr "$UI_ERROR")
  head=$(COLUMNS=$cols LINES=$hrows UI_NOTES='' ui_header 2>&1)
  started=${EPOCHREALTIME//[!0-9]/} row_started=$started
  printf '\e[?25l\e[H\e[2J' >&2

  # The row of a step, by its label.
  row_of() {
    local name i
    name=$(progress_row "$1")
    for i in "${!PROGRESS_ROWS[@]}"; do
      [[ ${PROGRESS_ROWS[i]} != "$name" ]] || { echo "$i"; return; }
    done
    echo -1
  }

  # A line of the column: left-aligned text, and some at its right edge.
  line() { # colour text [right]
    local right=${3:-} text
    text=${2:0:$((width - ${#right} - 1))}
    printf -v line '%*s%s%s%s%*s\e[0m\e[K\n' "$margin" '' "$1" "$text" "$c_muted" $((width - ${#text})) "$right"
    out+=$line
  }

  frame() { # [ok|fail]: the last one
    local out='' i mark colour time label bar filled
    now=${EPOCHREALTIME//[!0-9]/}
    for label in "${PROGRESS_TITLE[@]}"; do line "$c_muted" "$label"; done
    out+=$'\e[K\n'
    for i in "${!PROGRESS_ROWS[@]}"; do
      label=${PROGRESS_ROWS[i]} time=''
      if ((i < at)); then
        mark='√' colour=$c_accent
        progress_clock time "${secs[i]:-0}"
      elif ((i == at)); then
        mark='»' colour=$c_bright
        [[ ${1:-} != fail ]] || mark='x' colour=$c_error
        progress_clock time $(((now - row_started) / 100000))
      else
        mark='·' colour=$c_muted
      fi
      line "$colour" "$mark $label" "$time"
      ((i == at)) && [[ ${1:-} != ok ]] || continue
      # What the part running does now, and for the packages how far.
      if ((total > 0 && n > 0)); then
        filled=$((n * 24 / total))
        ((filled <= 24)) || filled=24
        printf -v bar '%*s' "$filled" ''
        printf -v time '%*s' $((24 - filled)) ''
        line '' "    $c_accent${bar// /█}$c_muted${time// /░}$c_text  $part $n of $total"
        [[ -z $item ]] || line "$c_muted" "    $item"
      elif [[ -n $part ]]; then
        line "$c_text" "    $part"
        [[ -z $item ]] || line "$c_muted" "    $item"
      elif [[ -n $detail && $detail != "$label" ]]; then
        line "$c_muted" "    $detail"
      fi
    done
    out+=$'\e[K\n'
    progress_clock time $(((now - started) / 100000))
    line "$c_muted" "In all" "$time"
    if ((${#warnings[@]})); then
      out+=$'\e[K\n'
      # The last four.
      i=$((${#warnings[@]} > 4 ? ${#warnings[@]} - 4 : 0))
      for label in "${warnings[@]:i}"; do line "$c_warn" "$label"; done
    fi
    if [[ ${1:-} == ok ]]; then
      # The last one under the steps all ticked.
      UI_AT='*'
      head=$(COLUMNS=$cols LINES=$hrows UI_NOTES='' ui_header 2>&1)
    elif [[ ${1:-} == fail ]]; then
      # Under the name alone, to leave room for the error and the log's
      # last lines.
      head=$(COLUMNS=$cols LINES=33 UI_NOTES='' ui_header 2>&1)
      printf '\e[2J' >&2
    fi
    printf '\e[H%s\n\n%s\e[J' "$head" "$out" >&2
    last=$now
  }

  while :; do
    if IFS=$'\t' read -r -t 1 kind a b c; then
      case $kind in
        step)
          i=$(row_of "$a")
          if ((i >= 0 && i != at)); then
            at=$i row_started=${EPOCHREALTIME//[!0-9]/} detail='' part='' n=0 total=0 item=''
          fi
          ;;
        took)
          i=$(row_of "$a")
          ((i < 0)) || secs[i]=$((${secs[i]:-0} + ${b%.*} * 10 + ${b#*.}))
          ;;
        say | info) detail=$a part='' n=0 total=0 item='' ;;
        warn) warnings+=("$a") ;;
        part) part=$a n=0 total=${b:-0} item='' ;;
        count) n=$a total=$b item=$c ;;
        end)
          [[ $a != ok ]] || at=${#PROGRESS_ROWS[@]}
          frame "$a"
          printf '\e[?25h' >&2
          exit 0
          ;;
      esac
      now=${EPOCHREALTIME//[!0-9]/}
      ((now - last < 100000)) && continue
    fi
    frame
  done
}

# The view, when there is a screen to draw it on; otherwise the Install
# step's header and its title, and the install's lines under it.
progress_start() {
  local fifo title
  if [[ ! -t 2 ]]; then
    screen Install
    for title in "${PROGRESS_TITLE[@]}"; do info "$title"; done
    return 0
  fi
  # shellcheck disable=SC2034 # ui.bash's header reads it
  UI_AT=Install
  fifo=$(mktemp -u /tmp/nova-progress.XXXXXX)
  mkfifo -m 600 "$fifo"
  # Read and write: the install never blocks opening it, and never dies of
  # a closed pipe. The view stops at the end event, not at the pipe's end,
  # since a program the install starts may keep it open.
  exec 7<>"$fifo"
  rm -f -- "$fifo"
  progress_view <&7 &
  PROGRESS_PID=$!
  exec 8>&2 2>>"$LOG"
  PROGRESS=1
}

# The view's last frame, and the screen back for the lines after it.
progress_end() { # ok|fail
  ((PROGRESS && !BASH_SUBSHELL)) || return 0
  local i
  progress_event end "$1"
  # Gone already, and the screen given back (progress_event).
  ((PROGRESS)) || return 0
  PROGRESS=0
  for ((i = 0; i < 50; i++)); do
    kill -0 "$PROGRESS_PID" 2>/dev/null || break
    sleep 0.1
  done
  kill "$PROGRESS_PID" 2>/dev/null || true
  wait "$PROGRESS_PID" 2>/dev/null || true
  exec 2>&8 8>&- 7>&-
  printf '\e[?25h' >&2
}

# Under a failed install's view: the log's last lines, where what went wrong
# usually is, and where the whole log is.
progress_tail() {
  local width
  width=$(($(ui_frame_width) - 2))
  echo >&2
  ui_note "The log's last lines:"
  ui_note "$(grep -v "^$STEP_LINE" "$LOG" | tail -n 12 | tr -d '\000-\010\013-\037' | cut -c "1-$width" | sed 's/^/  /')"
  echo >&2
  ui_note "The whole log: $LOG"
}
