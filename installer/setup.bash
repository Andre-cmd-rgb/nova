# shellcheck shell=bash
# installer/setup.bash: what setting up a Nova system asks and does: the
# questions nova-install asks, on the screens of installer/ui.bash, and the
# account it makes from the answers. Sourced, never run.
#
# The script sourcing this defines screen [step] (the header of each screen),
# default_answer name|user|host|timezone (that question's default, printed),
# say, info, warn and die, and sets TARGET (the root of the system being set
# up) and LOG.

KBD_MODEL_MAP=${NOVA_KBD_MODEL_MAP:-/usr/share/systemd/kbd-model-map}
# Files to remove however the script ends, for its EXIT trap: it has one of
# its own, for the console's colours.
CLEANUP=()
# Unless the disk is encrypted, this password is all that stands between the
# computer and anyone at its lock screen or its sudo.
MIN_PASSWORD=8

# ------------------------------------------------------------- the questions

# Never root, the greeter or another system account, nor a system group's name
# (audio, video, wheel...): those exist in the new system too, and useradd,
# which makes the account a group of its own name, would fail there after the
# disk is already erased. An ordinary account or group of that name on the live
# system (the fingerprint stand-in of an earlier attempt) is fine.
valid_username() {
  [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ && $1 != root && $1 != greeter ]] || return 1
  local entry id
  if entry=$(getent group "$1"); then
    IFS=: read -r _ _ id _ <<<"$entry"
    ((id >= 1000 && id != 65534)) || return 1
  fi
  entry=$(getent passwd "$1") || return 0
  IFS=: read -r _ _ id _ <<<"$entry"
  ((id >= 1000 && id != 65534))
}

# What useradd takes as the comment: no : (the passwd file's separator), and
# nothing that is not text.
valid_fullname() {
  [[ ! $1 =~ [[:cntrl:]:] ]]
}

valid_hostname() {
  [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]
}

valid_timezone() {
  [[ $1 =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && -f ${NOVA_ZONEINFO:-/usr/share/zoneinfo}/$1 ]]
}

valid_keymap() {
  [[ $1 =~ ^[a-z][a-z0-9_-]*$ ]] && localectl list-keymaps 2>/dev/null | grep -qx -- "$1"
}

suggested_username() { # full name
  tr '[:upper:]' '[:lower:]' <<<"${1%% *}" | tr -cd 'a-z0-9_-'
}

# ------------------------------------------------------------- the screens
#
# One question a screen under the wordmark: Esc goes back a step, Ctrl+C stops.
# Each step_ function returns 1 for Esc, and keeps its answers in KEYMAP,
# FULLNAME, ACCOUNT, PASSWORD, COMPUTER and TIMEZONE.

# Keyboard layouts by name. Any other console keymap can be typed in.
keymap_names() {
  cat <<'EOF'
English (US)	us
English (UK)	uk
English (US international)	us-acentos
Spanish	es
Latin American	la-latin1
Italian	it
German	de
French	fr
Portuguese	pt-latin1
Brazilian	br-abnt2
Swiss German	de_CH-latin1
Swiss French	fr_CH-latin1
Belgian	be-latin1
Dutch	nl
Danish	dk-latin1
Norwegian	no-latin1
Swedish	sv-latin1
Finnish	fi
Polish	pl
Czech	cz
Hungarian	hu
Greek	gr
Turkish	trq
Russian	ru
Ukrainian	ua
Japanese	jp106
Dvorak	dvorak
Colemak	colemak
EOF
}

# The keyboard layout, picked by name with the default on top; prints its
# keymap. Asked first, before any password is typed: nova-install-start asks it
# with nova-install --keymap.
choose_keymap() { # default
  local default=$1 line keymap problem=''
  while :; do
    screen Keyboard
    [[ -z $problem ]] || ui_warn "$problem"
    line=$({
      keymap_names | awk -F'\t' -v d="$default" '$2 == d { print $1 " (" $2 ")"; found = 1 }
        END { if (!found && d != "") print d " (" d ")" }'
      keymap_names | awk -F'\t' -v d="$default" '$2 != d { print $1 " (" $2 ")" }'
      echo "Another layout..."
    } | ui_filter "Keyboard layout" "Type to narrow the list: Spanish, German, ...") || return
    if [[ $line == "Another layout..." ]]; then
      keymap=$(ui_input "Its console keymap" "" "as listed by localectl list-keymaps") ||
        { (($? == 130)) && return 130; continue; }
    else
      keymap=${line##*(}
      keymap=${keymap%)}
    fi
    if valid_keymap "$keymap"; then
      echo "$keymap"
      return 0
    fi
    problem="No keyboard layout called '$keymap'."
  done
}

step_you() {
  screen You
  while :; do
    ui_ask ui_input "Your full name" "${FULLNAME:-$(default_answer name)}" || return 1
    valid_fullname "$REPLY" && break
    ui_warn "A name without : in it."
  done
  FULLNAME=$REPLY
  ui_answered Name "$FULLNAME"
  while :; do
    ui_ask ui_input "Username" "${ACCOUNT:-$(default_answer user)}" "$(suggested_username "$FULLNAME")" || return 1
    REPLY=${REPLY:-$(suggested_username "$FULLNAME")}
    valid_username "$REPLY" && break
    ui_warn "Lower-case letters, digits, - and _, starting with a letter."
  done
  ACCOUNT=$REPLY
  ui_answered Username "$ACCOUNT"
  ui_ask ui_password "Password, for the lock screen and sudo" "$MIN_PASSWORD" || return 1
  # shellcheck disable=SC2034 # for the script sourcing this, to create the account with
  PASSWORD=$REPLY
}

step_computer() {
  screen Computer
  while :; do
    ui_ask ui_input "This computer's name" "${COMPUTER:-$(default_answer host)}" nova || return 1
    REPLY=${REPLY:-nova}
    valid_hostname "$REPLY" && break
    ui_warn "Letters, digits and -, up to 63 characters."
  done
  COMPUTER=$REPLY
  ui_answered Name "$COMPUTER"
  while :; do
    ui_ask choose_timezone "${TIMEZONE:-$(default_answer timezone)}" || return 1
    valid_timezone "$REPLY" && break
    ui_warn "Pick one of the list."
  done
  TIMEZONE=$REPLY
}

timezones() { timedatectl list-timezones 2>/dev/null; }

choose_timezone() { # default
  { echo "${1:-UTC}"; timezones | grep -vxF -- "${1:-UTC}"; } |
    ui_filter "Time zone" "Type a city: Rome, New York, ..."
}

# ------------------------------------------------------------- the system

logged() { # log the command, then run it with its output in the log
  printf '+ %s\n' "$*" >>"$LOG"
  "$@" >>"$LOG" 2>&1
}

# A command in the system being set up under $TARGET, from the installer's
# live system.
in_target() {
  logged arch-chroot "$TARGET" "$@"
}

# A command as the new account, inside the new system, with an environment of
# its own: the live system's root session would lend it XDG_RUNTIME_DIR=/run/user/0
# and the like, which the account cannot write to.
as_user() { # user command...
  local user=$1
  shift
  in_target runuser -u "$user" -- env -i HOME="/home/$user" USER="$user" LOGNAME="$user" \
    LANG=C.UTF-8 PATH=/usr/lib/nova/bin:/usr/bin "$@"
}

# The XKB layout and variant for a console keymap, tab-separated, from the table
# localectl converts with (sv-latin1 is se, sg is ch with de_nodeadkeys). A
# keymap the table lacks is taken to be the layout's own name, less a -latin1
# style suffix.
xkb_layout() { # keymap
  local keymap=$1 layout='' variant=''
  if [[ -r $KBD_MODEL_MAP ]]; then
    read -r layout variant < <(awk -v k="$keymap" \
      '$1 == k { print $2, ($4 == "-" ? "" : $4); found = 1; exit } END { if (!found) print "" }' "$KBD_MODEL_MAP")
  fi
  if [[ -z $layout ]]; then
    case $keymap in
      *-latin1 | *-latin9 | *-nodeadkeys) layout=${keymap%%-*} ;;
      *) layout=$keymap ;;
    esac
  fi
  printf '%s\t%s\n' "$layout" "$variant"
}

# The session and the greeter read the keyboard layout from here
# (default/hypr/keyboard.lua), so the console, the greeter, the lock screen
# and the desktop all agree.
write_keyboard() { # keymap
  local layout variant
  IFS=$'\t' read -r layout variant < <(xkb_layout "$1")
  {
    printf 'KEYMAP=%s\nXKBLAYOUT=%s\n' "$1" "$layout"
    [[ -z $variant ]] || printf 'XKBVARIANT=%s\n' "$variant"
  } >"$TARGET/etc/vconsole.conf"
}

write_names() { # hostname timezone
  echo "$1" >"$TARGET/etc/hostname"
  printf '127.0.0.1 localhost\n::1 localhost\n127.0.1.1 %s.localdomain %s\n' "$1" "$1" >"$TARGET/etc/hosts"
  ln -sf "/usr/share/zoneinfo/$2" "$TARGET/etc/localtime"
  # The Wi-Fi channels the time zone's country allows, from the next start.
  in_target /usr/lib/nova/bin/nova-wireless-regdom || warn "Could not set the Wi-Fi country; Wi-Fi keeps to the channels every country allows."
  # Some machines and VMs have no clock this can set; timesyncd sets it later.
  in_target hwclock --systohc || warn "Could not set the hardware clock; it is set once the system is online."
}

create_user() {
  local user=$1 fullname=$2 password=$3
  say "Creating your account"
  in_target useradd -m -k /usr/share/nova/skel -G wheel -c "$fullname" -s /bin/bash "$user"
  # On stdin, never a command line, which any process can read; the log
  # gets only the command.
  printf '%s:%s\n' "$user" "$password" | in_target chpasswd ||
    die "could not set the password"
  in_target passwd -l root
  install -m 440 /dev/stdin "$TARGET/etc/sudoers.d/10-nova-wheel" <<<'%wheel ALL=(ALL:ALL) ALL'
  in_target visudo -cf /etc/sudoers.d/10-nova-wheel

  # Autologin goes to this account, and the greeter greets it after a logout;
  # other accounts log in on a text console (Ctrl+Alt+F2).
  sed "s/@NOVA_USER@/$user/" "$TARGET/usr/share/nova/session/greetd.toml" >"$TARGET/etc/greetd/config.toml"
  # The greeter shows the user's theme without root: the theme engine mirrors
  # it here, and the directory is the user's.
  install -d -m 755 "$TARGET/var/lib/nova/greeter"
  in_target chown "$user:$user" /var/lib/nova/greeter
  # The lock screen runs PAM as the user, so pam_faillock can count its wrong
  # passwords only in a tally file that already exists: /run/faillock is
  # root's. The boot autologin never runs root's PAM to create one.
  install -Dm644 /dev/stdin "$TARGET/etc/tmpfiles.d/nova-faillock.conf" <<<"f /run/faillock/$user 0660 $user root -"
  # Without a theme the desktop still starts, in the default colors, and
  # Settings sets one: not worth stopping a setup for.
  as_user "$user" nova-theme set white ||
    warn "The theme did not apply; choose one in Settings, Appearance."
  [[ $BROWSER != firefox ]] || set_browser "$user" firefox.desktop
}

# The account's default browser, in the mimeapps.list it has from Nova's
# skel, which names Supernova: for the web and web pages, and for PDFs, which
# Firefox and Chrome open and Supernova does not.
set_browser() { # user desktop-entry
  local list=$TARGET/home/$1/.config/mimeapps.list
  [[ -f $list ]] || return 0
  sed -i -E "s#^(x-scheme-handler/https?|text/html|application/pdf)=.*#\1=$2#" "$list"
  grep -q '^application/pdf=' "$list" || sed -i "/^text\/html=/a application/pdf=$2" "$list"
}

# Chrome when it is the browser asked for, VS Code (built from their AUR
# recipes, since neither may be redistributed) and the mise tools, Claude Code
# and Codex. Online only, and never fatal: the system is complete without
# them (Supernova is there beside Chrome), the welcome offers VS Code at the
# first login online, and mise install finishes the rest.
install_apps() {
  local user=$1 rule=$TARGET/etc/sudoers.d/90-nova-install-apps names=VS\ Code
  [[ $BROWSER != chrome ]] || names="Chrome, VS Code"
  if ! curl -fsI --max-time 10 -o /dev/null https://aur.archlinux.org/; then
    warn "No internet: $names, Claude Code and Codex are not installed."
    warn "Once connected, the welcome offers VS Code, and mise install sets up the rest."
    return 0
  fi
  say "Installing $names, Claude Code and Codex"
  # makepkg installs through sudo, and the account has no password prompt to
  # answer here, so pacman alone is allowed for the length of this step. The
  # rule is a file of the live system's, in memory, mounted over an empty one
  # of the new system's: should the power go now, the disk holds no such rule.
  local held=/run/nova-install-apps.sudoers
  install -m 440 /dev/stdin "$held" <<<"$user ALL=(root) NOPASSWD: /usr/bin/pacman"
  install -m 440 /dev/null "$rule"
  CLEANUP+=("$rule")
  if mount --bind "$held" "$rule"; then
    if [[ $BROWSER == chrome ]]; then
      if as_user "$user" nova-apps-install --noconfirm --only google-chrome; then
        set_browser "$user" google-chrome.desktop
      else
        warn "Chrome did not install, so Supernova is the browser; the App Center installs Chrome."
      fi
    fi
    as_user "$user" nova-apps-install --noconfirm --only visual-studio-code-bin ||
      warn "VS Code did not install; the App Center installs it."
    umount -- "$rule" || true
  else
    warn "$names did not install; the App Center installs them."
  fi
  rm -f -- "$rule" "$held"
  as_user "$user" mise install --yes ||
    warn "The mise tools did not install; run mise install after the first login."
}
