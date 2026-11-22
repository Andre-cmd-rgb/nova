#!/usr/bin/env bats

# What runs as root: the polkit actions Nova ships, and the helpers they run.
# Each is checked as `make install` lays the tree out (the Rust programs as
# stand-ins; the cursor, which needs xcursorgen, left out).

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
