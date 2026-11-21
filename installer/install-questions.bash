# shellcheck shell=bash
# installer/install-questions.bash: nova-install's questions, read from an
# answers file or asked one a screen, the summary that ends them, the
# fingerprint enrolled on the way, and the answers file's after= script.
# Sourced by nova-install, never run.

# ------------------------------------------------------------- the questions
#
# The questions themselves are installer/setup.bash's; these are the
# installer's own.

# An answer from the answers file: the last key=value line for the key.
answer() { # key
  sed -n "s/^$1=//p" "$ANSWERS" | tail -n 1
}

# The answers, asked on screen or read from the answers file.
KEYMAP='' DISK_LINE='' FULLNAME='' ACCOUNT='' PASSWORD='' COMPUTER='' TIMEZONE='' FINGERPRINT=''
ENCRYPT=no DISK_PASSPHRASE='' BROWSER=supernova
# Who FINGERPRINT was enrolled for: going back and changing the username
# leaves the print behind.
ENROLLED_FOR=''
# shellcheck disable=SC2034 # ui.bash says it when Ctrl+C stops a question
UI_STOPPED="The installer stopped; nothing was changed. nova-install-start starts it again."

# What carried things say about the computer they came from, as defaults.
carried_default() { # name|user|host|timezone
  carry_ready || return 0
  local value
  value=$(carry_value ".source.$1")
  case $1 in
    name) valid_fullname "$value" || value= ;;
    user) valid_username "$value" || value= ;;
    # Only for this same computer; another one deserves its own name.
    host) [[ -n $(machine_hash) && $(machine_hash) == "$(carry_value .source.machine)" ]] && valid_hostname "$value" || value= ;;
    timezone) valid_timezone "$value" || value= ;;
  esac
  echo "$value"
}

# A portable install is a computer of its own, on every network it joins, so
# it is not named after the one it is made on.
default_answer() {
  if ((PORTABLE)) && [[ $1 == host ]]; then
    echo nova-usb
    return 0
  fi
  carried_default "$1"
}

# Why no disk is offered.
no_disk() {
  if ((PORTABLE)); then
    echo "no USB disk to put Nova on: it needs a USB stick or drive of 32 GB or more, besides the stick this runs from."
  else
    echo "no disk to install on: Nova needs an internal disk of at least 64 GiB."
  fi
}

# --answers: every answer from the file, where a wrong one ends the install
# rather than asking again.
answers_from_file() {
  local line
  KEYMAP=$(answer keymap)
  KEYMAP=${KEYMAP:-us}
  valid_keymap "$KEYMAP" || die "the answers file: no keyboard layout called '$KEYMAP'."
  local disks=()
  mapfile -t disks < <(candidate_disks)
  ((${#disks[@]})) || die "$(no_disk)"
  DISK_LINE=''
  for line in "${disks[@]}"; do
    [[ ${line%%$'\t'*} == "$(answer disk)" ]] && DISK_LINE=$line
  done
  [[ -n $DISK_LINE ]] || die "the answers file names no disk this can install on (disk=$(answer disk))"
  ! disk_in_use "${DISK_LINE%%$'\t'*}" || die "the answers file's disk is in use by the live system"
  FULLNAME=$(answer_or fullname "$(carried_default name)")
  valid_fullname "$FULLNAME" || die "the answers file: a name without : in it."
  ACCOUNT=$(answer_or user "$(carried_default user)")
  [[ -n $ACCOUNT ]] || ACCOUNT=$(suggested_username "$FULLNAME")
  valid_username "$ACCOUNT" || die "the answers file: no account can be called '$ACCOUNT'."
  PASSWORD=$(answer password)
  [[ -n $PASSWORD ]] || die "the answers file has no password"
  ((${#PASSWORD} >= MIN_PASSWORD)) || die "the answers file: a password of at least $MIN_PASSWORD characters."
  COMPUTER=$(answer_or hostname nova)
  valid_hostname "$COMPUTER" || die "the answers file: no computer can be called '$COMPUTER'."
  TIMEZONE=$(answer_or timezone UTC)
  valid_timezone "$TIMEZONE" || die "the answers file: no time zone called '$TIMEZONE'."
  ENCRYPT=$(answer_or encrypt no)
  [[ $ENCRYPT == yes || $ENCRYPT == no ]] || die "the answers file: encrypt=yes or encrypt=no."
  DISK_PASSPHRASE=''
  if [[ $ENCRYPT == yes ]]; then
    DISK_PASSPHRASE=$(answer disk_passphrase)
    ((${#DISK_PASSPHRASE} >= MIN_PASSWORD)) ||
      die "the answers file: encrypt=yes needs a disk_passphrase of at least $MIN_PASSWORD characters."
  fi
  BROWSER=$(answer_or browser supernova)
  [[ $BROWSER =~ ^(supernova|firefox|chrome)$ ]] || die "the answers file: browser=supernova, browser=firefox or browser=chrome."
}

# ------------------------------------------------------------------ the browser
#
# The web browser, which is the default one: Supernova, Nova's own, which the
# stick carries; Firefox, from Arch's repositories; or Google Chrome, which may
# not be passed on, so it is built from Google's release once the system is in
# (install_apps), with Supernova beside it in case it cannot be. Firefox and
# Chrome come over the internet: without it there is no question, and the
# summary says why it is Supernova.

INTERNET=''

# Whether the internet answers: asked once, and with "again" asked again
# after a no, as at the browser's step, so that a network that came up during
# the questions (a cable plugged in, an address that came late) brings them.
internet() { # [again]
  if [[ -z $INTERNET || ($INTERNET == no && ${1:-} == again) ]]; then
    INTERNET=no
    curl -fsI --max-time 10 -o /dev/null https://archive.archlinux.org/ && INTERNET=yes
  fi
  [[ $INTERNET == yes ]]
}

# The browser this install can give: Supernova without the internet, and
# without the apps step (answers apps=no) that would build Chrome.
settle_browser() {
  [[ $BROWSER != supernova ]] || return 0
  if ! internet; then
    info "No internet: Supernova is the browser. Firefox and Chrome are in the App Center once there is."
    BROWSER=supernova
  elif [[ $BROWSER == chrome && $(answer_or apps yes) == no ]]; then
    info "apps=no: Chrome is built in that step, so Supernova is the browser."
    BROWSER=supernova
  fi
  return 0
}

# What the packages step installs for it.
browser_packages() {
  case $BROWSER in
    firefox) echo firefox ;;
    *) echo supernova ;;
  esac
}

step_browser() {
  local supernova="Supernova: Nova's own, light and fast" firefox="Firefox" chrome="Google Chrome" current
  screen Browser
  case $BROWSER in
    firefox) current=$firefox ;;
    chrome) current=$chrome ;;
    *) current=$supernova ;;
  esac
  ui_ask ui_choose "Your web browser?" "$current" \
    "$supernova"$'\t'supernova "$firefox"$'\t'firefox "$chrome"$'\t'chrome || return 1
  BROWSER=$REPLY
}

summary_browser() {
  case $BROWSER in
    firefox) echo "Browser      Firefox" ;;
    chrome)
      echo "Browser      Google Chrome, built from Google's release at the end, and"
      echo "             Supernova beside it"
      ;;
    *)
      if internet; then
        echo "Browser      Supernova"
      else
        echo "Browser      Supernova: Firefox and Chrome need the internet, and are in"
        echo "             the App Center once there is"
      fi
      ;;
  esac
}

# ------------------------------------------------------------- the screens
#
# One question a screen under the wordmark, as nova usb asks its own: Esc goes
# back a step, Ctrl+C stops with nothing changed. Each step_ function returns 1
# for Esc; the keyboard, you and this computer are installer/setup.bash's.
#
# The steps show above each question (UI_TRAIL, ui_trail): the ones
# nova-install-start went through first (NOVA_TRAIL_BEFORE: the keyboard, the
# network), then this installer's own, and the install. A portable install
# says so above them.

screen() { # [the step it is in] [what it is about]
  # shellcheck disable=SC2034 # ui.bash's header reads it
  UI_AT=${1:-}
  if ((PORTABLE)); then
    ui_header "Portable Nova, onto a USB disk${2:+  ·  $2}"
  else
    ui_header "${2:-}"
  fi
}

# The step of the trail each question is in.
trail_step() { # step_ name
  case $1 in
    keymap) echo Keyboard ;;
    disk | encryption) echo Disk ;;
    you | fingerprint) echo You ;;
    computer) echo Computer ;;
    browser) echo Browser ;;
    summary) echo Review ;;
  esac
}

step_keymap() {
  ui_ask choose_keymap "${KEYMAP:-us}" || return 1
  KEYMAP=$REPLY
  loadkeys "$KEYMAP" >/dev/null 2>&1 || true
}

# What a disk holds, for the list of disks: each partition's label, file
# system and size, the largest first (on a Windows disk, Windows), the ones
# with neither label nor file system left out. With a width, as many as fit,
# and how many more there are.
disk_held() { # disk [width]
  local width=${2:-0} entries=() i out='' more
  mapfile -t entries < <(disk_contents "$1" | awk '{
      label = ""
      if (match($0, /"[^"]*"$/)) label = substr($0, RSTART)
      fs = ($3 == "no") ? "" : $3
      if (fs == "" && label == "") next
      entry = label
      if (fs != "") entry = entry (entry == "" ? "" : " ") fs
      print $2 "\t" entry " " $2
    }' | sort -t $'\t' -k1,1hr -s | cut -f2-)
  for i in "${!entries[@]}"; do
    more=''
    ((i + 1 == ${#entries[@]})) || more="  ·  +$((${#entries[@]} - i - 1)) more"
    if ((width > 0 && ${#out} + (${#out} ? 5 : 0) + ${#entries[i]} + ${#more} > width)); then
      # The largest alone, when there is room for nothing more.
      if [[ -n $out ]]; then
        out+="  ·  +$((${#entries[@]} - i)) more"
      elif ((${#entries[i]} <= width)); then
        out=${entries[i]}
      else
        out="${#entries[@]} partitions"
      fi
      break
    fi
    out+="${out:+  ·  }${entries[i]}"
  done
  printf '%s' "$out"
}

step_disk() {
  local disks=() options=() names=() sizes=() models=() i path size model held label selected='' problem=''
  local name_width=0 size_width=0 model_width=0
  mapfile -t disks < <(candidate_disks)
  ((${#disks[@]})) || die "$(no_disk)"
  for i in "${!disks[@]}"; do
    IFS=$'\t' read -r path size model _ _ <<<"${disks[i]}"
    [[ $model != - ]] || model="unknown model"
    names[i]=${path#/dev/} sizes[i]=$(human_size "$size") models[i]=$model
    ((${#names[i]} <= name_width)) || name_width=${#names[i]}
    ((${#sizes[i]} <= size_width)) || size_width=${#sizes[i]}
    ((${#model} <= model_width)) || model_width=${#model}
  done
  # In columns: the name, the size and the model line up, then what is on it,
  # as much as fits beside the cursor.
  for i in "${!disks[@]}"; do
    printf -v label '%-*s  %*s  %-*s' "$name_width" "${names[i]}" "$size_width" "${sizes[i]}" "$model_width" "${models[i]}"
    held=$(disk_held "${disks[i]%%$'\t'*}" $(($(ui_frame_width) - 2 - ${#label} - 5)))
    label="$label${held:+  ·  $held}"
    label=${label//[,$'\t']/ }
    label=${label%"${label##*[! ]}"}
    options+=("$label"$'\t'"$i")
    [[ ${disks[i]} != "$DISK_LINE" ]] || selected=$label
  done
  while :; do
    screen Disk
    [[ -z $problem ]] || ui_warn "$problem"
    ui_ask ui_choose "Which disk? Everything on it will be erased." "$selected" "${options[@]}" || return 1
    path=${disks[REPLY]%%$'\t'*}
    if ! disk_in_use "$path"; then
      DISK_LINE=${disks[REPLY]}
      return 0
    fi
    problem="${path#/dev/} is in use by the live system (mounted, swap or LVM). Pick another."
  done
}

# Off unless asked for. On, the btrfs partition is LUKS2 and its passphrase is
# asked at every start, before anything else; the EFI partition, which holds
# the kernels, stays plain for the firmware to start them. A choice rather
# than a yes or no, so Esc goes back to the disk.
step_encryption() {
  local off="No" on="Yes: a passphrase at every start"
  screen Disk
  ui_ask ui_choose "Encrypt the disk?" "$([[ $ENCRYPT == yes ]] && echo "$on" || echo "$off")" \
    "$off"$'\t'no "$on"$'\t'yes || return 1
  ENCRYPT=$REPLY DISK_PASSPHRASE=''
  [[ $ENCRYPT == yes ]] || return 0
  ui_answered Encryption on
  ui_note "Without the passphrase nothing on the disk can be read, by anyone: keep it safe."
  ui_ask ui_password "The disk's passphrase" "$MIN_PASSWORD" || return 1
  DISK_PASSPHRASE=$REPLY
}

# Offered when the reader is one fprintd drives. Esc is No here.
step_fingerprint() {
  screen You
  if ! ui_ask ui_confirm "Unlock with your fingerprint too?"; then
    FINGERPRINT='' ENROLLED_FOR=''
    return 0
  fi
  until enroll_fingerprint "$ACCOUNT"; do
    ui_warn "That did not work."
    if ! ui_ask ui_confirm "Try again?"; then
      FINGERPRINT='' ENROLLED_FOR=''
      ui_note "Settings, Lock Screen sets it up later."
      return 0
    fi
  done
  FINGERPRINT="right index finger" ENROLLED_FOR=$ACCOUNT
}

# What the install will do, one line each; the screens frame it, the answers
# file's install logs it.
summary_lines() {
  local disk size model line
  IFS=$'\t' read -r disk size model _ _ <<<"$DISK_LINE"
  echo "Erased       ${disk#/dev/}  $(human_size "$size")$([[ $model == - ]] || echo "  $model")"
  while IFS= read -r line; do
    [[ -z $line ]] || echo "             now holds $line"
  done < <(disk_contents "$disk")
  if ((PORTABLE)); then
    echo "Layout       2 GiB EFI partition, btrfs with snapshots, no swap file"
    echo "Portable     starts any 64-bit PC from its boot menu, with what is on it"
    echo "             now; no PC's firmware gets a boot entry, this one included"
  else
    echo "Layout       2 GiB EFI partition, btrfs with snapshots, $(swap_gib "$size") GiB swap file"
  fi
  if [[ $ENCRYPT == yes ]]; then
    echo "Encryption   on: the passphrase at every start"
  else
    echo "Encryption   off: anyone with the disk can read it"
  fi
  echo "Kernel       $(main_kernel), with linux-lts as the fallback"
  echo "Account      $ACCOUNT ($FULLNAME) on $COMPUTER"
  echo "Time zone    $TIMEZONE, keyboard $KEYMAP"
  [[ -z $FINGERPRINT ]] || echo "Fingerprint  $FINGERPRINT"
  summary_browser
  if carry_ready && [[ -n $(restorable_labels) ]]; then
    echo "Your things  $(restorable_labels | paste -sd, - | sed 's/,/, /g') from $(carry_value .source.host)"
  fi
}

# The summary in its box: each line's label in grey, and the disk that is
# erased in the warning colour, so it is the first thing read.
summary_box() {
  local line lines=()
  while IFS= read -r line; do
    if [[ $line == Erased* ]]; then
      lines+=("$(ui_sgr "$UI_WARN")${line:0:13}$(ui_sgr "$UI_BRIGHT")${line:13}")
    elif [[ ${line:0:13} == *[![:space:]]* ]]; then
      lines+=("$(ui_sgr "$UI_MUTED")${line:0:13}$(ui_sgr "$UI_TEXT")${line:13}")
    else
      lines+=("${line:0:13}$(ui_sgr "$UI_MUTED")${line:13}")
    fi
  done < <(summary_lines)
  ui_box "${lines[@]}"
}

step_summary() {
  local disk=${DISK_LINE%%$'\t'*}
  screen Review
  summary_box
  echo >&2
  ui_note "Nothing has been changed yet."
  echo >&2
  while :; do
    ui_ask ui_input "Type erase to wipe ${disk#/dev/} and $( ((PORTABLE)) && echo "put Nova on it" || echo install), or Esc to go back" || return 1
    [[ $REPLY != erase ]] || return 0
    ui_warn "That is not erase."
  done
}

# The steps in order, Esc stepping back one. The layout is asked only when
# nova-install-start has not asked it already, and the disk only when nova usb
# has not picked it (--portable <disk>).
# The browser's step is there only online, which is asked again when it comes
# up (internet again): with no question it is passed over, going back as well
# as forward, and the steps above the questions follow.
questions_on_screen() { # fingerprint(yes|no): whether to offer enrolling one
  local steps=() i=0 back=0
  KEYMAP=${NOVA_KEYMAP:-}
  steps=()
  valid_keymap "$KEYMAP" || steps+=(keymap)
  [[ -n $PORTABLE_DISK ]] || steps+=(disk)
  steps+=(encryption you)
  [[ $1 != yes ]] || steps+=(fingerprint)
  steps+=(computer browser summary)
  questions_trail "${steps[@]}"
  while ((i < ${#steps[@]})); do
    [[ -z $ENROLLED_FOR || $ENROLLED_FOR == "$ACCOUNT" ]] || FINGERPRINT='' ENROLLED_FOR=''
    if [[ ${steps[i]} == browser ]]; then
      internet again || true
      questions_trail "${steps[@]}"
      if ! internet; then
        if ((back)); then i=$((i - 1)); else i=$((i + 1)); fi
        continue
      fi
    fi
    if "step_${steps[i]}"; then
      i=$((i + 1)) back=0
    elif ((i > 0)); then
      i=$((i - 1)) back=1
    else
      die "nothing was changed."
    fi
  done
}

# The steps above each question (ui.bash's UI_TRAIL): nova-install-start's,
# these, and the install; the browser's only online.
questions_trail() { # step...
  local name trail=" ${NOVA_TRAIL_BEFORE:-} "
  for name in "$@" install; do
    [[ $name != browser ]] || internet || continue
    name=$(trail_step "$name")
    name=${name:-Install}
    [[ $trail == *" $name "* ]] || trail+="$name "
  done
  # shellcheck disable=SC2034 # ui.bash's header reads it
  read -r UI_TRAIL <<<"$trail"
}

# ------------------------------------------------------------------ fingerprint

# Whether the live system's fprintd has a reader. It starts on this first call,
# and sees only the readers libfprint can drive, which are the ones worth
# setting up.
fingerprint_reader() {
  local devices
  devices=$(busctl --system call net.reactivated.Fprint /net/reactivated/Fprint/Manager \
    net.reactivated.Fprint.Manager GetDevices 2>/dev/null) || return 1
  [[ $devices == "ao "[1-9]* ]]
}

# One finger for the new account, enrolled here on the stick before anything
# is installed; copy_fingerprints moves it into the new system. fprintd files
# prints under a user name, so a stand-in for the account exists here too.
enroll_fingerprint() { # user
  local user=$1 line
  id -u "$user" >/dev/null 2>&1 || useradd -M -s /usr/bin/nologin "$user" >/dev/null 2>&1 || return 1
  info "Touch the reader with your right index finger, lift it, and again, until it says done."
  { fprintd-enroll -f right-index-finger "$user" 2>&1 || true; } | while IFS= read -r line; do
    case $line in
      *enroll-stage-passed*) info "Got it. Again." ;;
      *enroll-retry-scan* | *enroll-swipe-too-short* | *enroll-finger-not-centered* | *enroll-remove-and-retry*)
        info "That did not read. Lift your finger and touch again."
        ;;
      *enroll-completed*) info "Done." ;;
    esac
  done
  [[ -n $(find "$FPRINT_DIR/$user" -type f 2>/dev/null) ]]
}

copy_fingerprints() { # user
  [[ -d $FPRINT_DIR/$1 ]] || return 0
  install -d -m 700 "$TARGET/var/lib/fprint"
  cp -a "$FPRINT_DIR/$1" "$TARGET/var/lib/fprint/"
}

# --------------------------------------------------------------- answers file

answer_or() { # key default: the answer, or the default when there is none
  local value=''
  [[ -z $ANSWERS ]] || value=$(answer "$1")
  echo "${value:-$2}"
}

# The answers file's after= script, run as root in the new system once the
# install is done; a relative path is next to the answers file.
run_after() {
  local script
  script=$(answer_or after '')
  [[ -n $script ]] || return 0
  [[ $script == /* ]] || script=${ANSWERS%/*}/$script
  [[ -r $script ]] || die "the answers file's after= script is not there: $script"
  say "Running $script"
  install -m 700 "$script" "$TARGET/root/nova-after"
  in_target /root/nova-after || die "$script failed; the log is in $LOG"
  rm -f "$TARGET/root/nova-after"
}
