#!/usr/bin/env bats

# What runs as root or unattended: the polkit actions Nova ships, the helpers
# they run, and the units. Each is checked as `make install` lays the tree out
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
