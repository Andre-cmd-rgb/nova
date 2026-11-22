#!/usr/bin/env bats

# What runs as root or unattended: the polkit actions Nova ships, the helpers
# they run, the units, and every other way the tree starts a program as root
# (ROOT_WAYS). Each is checked as `make install` lays the tree out
# (the Rust programs as stand-ins; the cursor, which needs xcursorgen, left
# out).

load ../test_helper

setup_file() {
  export ROOT=$BATS_FILE_TMPDIR/root
  local target=$BATS_FILE_TMPDIR/target name targets
  mkdir -p "$target/release"
  for name in $(grep -ohE 'target\)/release/[A-Za-z0-9_.-]+' "$REPO_ROOT"/Makefile "$REPO_ROOT"/*/install.mk "$REPO_ROOT"/*/*/install.mk | sed 's|.*/||' | sort -u); do
    printf '#!/bin/sh\n' >"$target/release/$name"
  done
  targets=$(make -s -C "$REPO_ROOT" --eval='print-%: ; @echo $($*)' print-INSTALL_TARGETS)
  # shellcheck disable=SC2046 # the targets, a word each
  make -s -C "$REPO_ROOT" DESTDIR="$ROOT" CARGO_TARGET_DIR="$target" $(tr ' ' '\n' <<<"$targets" | grep -vx install-cursor) >/dev/null
}

# Each action of the installed policies, a line each: its id, its three
# defaults (any, inactive, active) and the helper pkexec runs for it.
actions() {
  awk '
    /<action[[:space:]]/ { match($0, /id="[^"]*"/); id = substr($0, RSTART + 4, RLENGTH - 5); any = inactive = active = path = "" }
    /<allow_any>/ { any = $0; gsub(/.*<allow_any>|<\/allow_any>.*/, "", any) }
    /<allow_inactive>/ { inactive = $0; gsub(/.*<allow_inactive>|<\/allow_inactive>.*/, "", inactive) }
    /<allow_active>/ { active = $0; gsub(/.*<allow_active>|<\/allow_active>.*/, "", active) }
    /org\.freedesktop\.policykit\.exec\.path/ { path = $0; gsub(/.*exec\.path">|<\/annotate>.*/, "", path) }
    /<\/action>/ { print id, any, inactive, active, (path == "" ? "-" : path) }
  ' "$ROOT"/usr/share/polkit-1/actions/org.nova.*.policy
}

@test "every policy in the tree is installed, and each has its actions" {
  local policy missing=()
  for policy in $(git -C "$REPO_ROOT" ls-files '*.policy'); do
    [[ -f $ROOT/usr/share/polkit-1/actions/${policy##*/} ]] || missing+=("$policy")
  done
  [ "${#missing[@]}" -eq 0 ] || { printf 'not installed: %s\n' "${missing[@]}"; false; }
  [ "$(actions | wc -l)" -ge "$(git -C "$REPO_ROOT" ls-files '*.policy' | wc -l)" ]
}

# polkit keeps an authorization (auth_*_keep) for the caller's whole session,
# any program in it, for five minutes. An action that keeps one is named here,
# with why that is safe; none does.
KEPT=()

@test "every action asks each time: none keeps an authorization for the session" {
  local id any inactive active path kept=()
  while read -r id any inactive active path; do
    [[ " $any $inactive $active " == *_keep\ * ]] || continue
    [[ " ${KEPT[*]} " == *" $id "* ]] || kept+=("$id: $any $inactive $active")
  done < <(actions)
  [ "${#kept[@]}" -eq 0 ] || { printf 'keeps an authorization: %s\n' "${kept[@]}"; false; }
}

@test "every action runs a helper that is installed where its policy says" {
  local id any inactive active path wrong=()
  while read -r id any inactive active path; do
    [[ $path == /usr/lib/nova/* && -f $ROOT$path && -x $ROOT$path ]] || wrong+=("$id: $path")
  done < <(actions)
  [ "${#wrong[@]}" -eq 0 ] || { printf 'no helper: %s\n' "${wrong[@]}"; false; }
}

# A oneshot unit has no start timeout unless it sets one: systemd waits for it
# for good. A helper that reads a file the user can replace (a pipe that never
# ends, in place of a theme's file) or waits on something that never answers
# would hold its job, and whatever waits for it, until the next boot. So each
# one Nova ships sets a timeout; the few that may run as long as they need are
# named here, with why.
UNBOUNDED=(
  # It keeps its own time, 75 asks cut off after two seconds each.
  nova-session-guard.service
  # It rebuilds the boot entries, which a kill would leave half-written, and
  # reads only root's files.
  nova-patch-ram.service
)

@test "every oneshot unit has a start timeout, or is named with why it needs none" {
  local unit name timeout found=0 wrong=()
  while IFS= read -r unit; do
    grep -qx 'Type=oneshot' "$unit" || continue
    found=$((found + 1))
    name=${unit##*/}
    timeout=$(sed -nE 's/^Timeout(Start)?Sec=//p' "$unit" | tail -n 1)
    if [[ -z $timeout ]]; then
      wrong+=("$name: no TimeoutStartSec=")
    elif [[ $timeout == infinity || $timeout == 0 ]] && [[ " ${UNBOUNDED[*]} " != *" $name "* ]]; then
      wrong+=("$name: TimeoutStartSec=$timeout, and not named here")
    fi
  done < <(find "$ROOT/usr/lib/systemd" -type f -name '*.service')
  [ "${#wrong[@]}" -eq 0 ] || { printf '%s\n' "${wrong[@]}"; false; }
  [ "$found" -ge 10 ]
}

# The ways the tree starts a program as root, each a kind of root_programs.
ROOT_WAYS=(polkit unit drop-in sleep udev pacman pam)

# The programs the tree starts as root one way (ROOT_WAYS), a line each: a
# polkit action's helper, a system unit's command, one a drop-in adds to a
# unit (Nova's or another package's), a sleep hook, a udev rule's RUN, a
# pacman hook's Exec, and a PAM stack's pam_exec, after its options.
root_programs_by() { # way
  local path
  case $1 in
    polkit) actions | awk '{ print $5 }' ;;
    unit) sed -nE 's/^Exec[A-Za-z]*=[-@:+!]*([^ ]+).*/\1/p' "$ROOT"/usr/lib/systemd/system/*.service ;;
    drop-in) sed -nE 's/^Exec[A-Za-z]*=[-@:+!]*([^ ]+).*/\1/p' "$ROOT"/usr/lib/systemd/system/*.d/*.conf ;;
    sleep) for path in "$ROOT"/usr/lib/systemd/system-sleep/*; do echo "${path#"$ROOT"}"; done ;;
    udev) grep -ohE 'RUN\+="[^" ]+' "$ROOT"/usr/lib/udev/rules.d/*.rules | sed 's/^RUN+="//' ;;
    pacman) sed -nE 's/^Exec *= *([^ ]+).*/\1/p' "$ROOT"/usr/share/libalpm/hooks/*.hook ;;
    pam)
      awk '!/^[[:space:]]*#/ {
        for (i = 1; i <= NF; i++) if ($i ~ /(^|\/)pam_exec\.so$/) {
          for (j = i + 1; j <= NF; j++) if ($j ~ /^\//) { print $j; break }
          break
        }
      }' "$ROOT"/etc/pam.d/* ;;
  esac
}

# Every program the tree runs as root, every way, and the programs of Nova's
# that a sh wrapper among them (a sleep hook) runs.
root_programs() {
  local way path
  for way in "${ROOT_WAYS[@]}"; do root_programs_by "$way"; done | sort -u | while IFS= read -r path; do
    echo "$path"
    if [[ -f $ROOT$path ]] && head -n 1 "$ROOT$path" | grep -qx '#!/bin/sh'; then
      grep -ohE '/usr/lib/nova/[A-Za-z0-9/_.-]+' "$ROOT$path" || true
    fi
  done | sort -u
}

@test "each way the tree starts a program as root is read, and finds one" {
  local way empty=()
  for way in "${ROOT_WAYS[@]}"; do
    [[ -n $(root_programs_by "$way") ]] || empty+=("$way")
  done
  [ "${#empty[@]}" -eq 0 ] || { printf 'finds nothing: %s\n' "${empty[@]}"; false; }
  # The two a drop-in and PAM start, which a look at the units alone missed.
  root_programs | grep -qx /usr/lib/nova/nova-memory-reserve
  root_programs | grep -qx /usr/lib/nova/bin/nova-hw-laptop-open
}

# A NOVA_ variable in what runs as root is a test seam, set by a test that
# runs the program as an ordinary account, and is never read as root: each
# such program drops them all before anything reads one, with this line, and
# so for whatever it runs too. pkexec, systemd and udev empty the environment
# anyway; a root shell, sudo -E or a pacman run from one would not. The two
# whose NOVA_ variables are more than seams are named here, with why.
SEAMS_DROPPED="for seam in \$(compgen -e -X '!NOVA_*'); do unset \"\$seam\"; done"
OWN_VARIABLES=(
  # NOVA_POWER_LOCKED marks its own run again under its lock, and
  # NOVA_POWER_BOOST_EXPIRY the boost's end, a unit it starts as root.
  /usr/lib/nova/bin/nova-power
  # NOVA_AIRDROP_CHANNEL is a setting, given in a drop-in for nova-airdrop@
  # (src/airdrop/README.md).
  /usr/lib/nova/nova-airdrop-radio
)
# Settings given on purpose to a program that drops the seams, as path:name:
# it reads each into a variable of its own (name=${NOVA_...:-}) before it
# drops them, and nothing else of them.
KNOBS=(
  # nova-install gives NOVA_BOOT_CHECK=skip to pacstrap, whose hooks run it
  # as root before Limine is in; its header gives sudo NOVA_BOOT_CHECK=skip
  # pacman for an update that cannot wait for the fallback.
  /usr/lib/nova/bin/nova-boot-check:NOVA_BOOT_CHECK
)

# The line, as grep -n gives it, that reads <path>'s knob before the seams go.
knob_read() { # path
  local entry
  for entry in "${KNOBS[@]}"; do
    [[ ${entry%%:*} == "$1" ]] && printf '^[0-9]+:[a-z_]+=\\$\\{%s:-\\}$' "${entry#*:}" && return
  done
  printf '^$'
}

@test "every bash program run as root drops the NOVA_ test seams before anything reads one" {
  local path file first line checked=0 wrong=()
  while IFS= read -r path; do
    file=$ROOT$path
    [[ -f $file ]] && head -n 1 "$file" | grep -q bash || continue
    [[ " ${OWN_VARIABLES[*]} " != *" $path "* ]] || continue
    checked=$((checked + 1))
    # The first line that names a NOVA_ variable, comments and a knob's read
    # aside: the guard, under an EUID of 0, on that line or the one before.
    first=$(grep -nE '^[^#]*NOVA_' "$file" | grep -vE "$(knob_read "$path")" | head -n 1 | cut -d: -f1)
    if [[ -n $first && $(knob_read "$path") != '^$' ]] &&
      ! head -n "$((first - 1))" "$file" | grep -nE '' | grep -qE "$(knob_read "$path")"; then
      wrong+=("$path: does not read its knob before it drops the NOVA_ variables")
    fi
    line=''
    [[ -z $first ]] || line=$(sed -n "${first}p" "$file")
    if [[ $line != *"$SEAMS_DROPPED"* ]]; then
      wrong+=("$path: reads a NOVA_ variable before it drops them, or never drops them")
    elif [[ $line != *'if ((EUID == 0)); then'* && $(sed -n "$((first - 1))p" "$file") != *'if ((EUID == 0)); then'* ]]; then
      wrong+=("$path: drops them, but not only as root")
    fi
  done < <(root_programs)
  [ "${#wrong[@]}" -eq 0 ] || { printf '%s\n' "${wrong[@]}"; false; }
  [ "$checked" -ge 15 ]
}
