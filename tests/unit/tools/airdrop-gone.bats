#!/usr/bin/env bats

# AirDrop left Nova in 1.0.0-rc.15, all of it. Nothing in the tree names it,
# in any case, in a file's words or in its name, but the places that take it
# off a computer that had it, their tests, and the list of packages it alone
# needed, each named here with why. A file not listed that names it fails, so
# that AirDrop can neither come back half-way nor be left half-removed; a
# listed one that no longer names it fails too, so that the list stays as
# short as it should. Files git ignores (target/, .ai-local/) are not read.

load ../test_helper

ALLOWED=(
  packaging/nova/nova.install             # stops its units on an update from a release that had it, and removes what it kept
  tests/unit/tools/package-scriptlet.bats # that, tested
  src/shell/services/Layout.js            # drops its plugin from an older shell.json as the shell reads it
  src/cli/bin/nova-shell-config           # and as the CLI reads it
  tests/qml/shell-json-test.qml           # the shell's side, tested
  tests/unit/cli/bar.bats                 # the CLI's side, tested, and the two lists held equal
  src/shell/plugins/menu/MenuModel.js     # drops its entries from an older menu.jsonc as the menu reads it
  tests/qml/menu-test.qml                 # that, tested
  src/cli/retired                         # the packages it alone needed, which nova update may remove, and why
  tests/unit/tools/airdrop-gone.bats      # this check
)

# The files, tracked or new, that name it in their words or their name.
naming() {
  git -C "$REPO_ROOT" grep --untracked -I -il airdrop
  { git -C "$REPO_ROOT" ls-files; git -C "$REPO_ROOT" ls-files --others --exclude-standard; } | grep -i airdrop
}

@test "nothing in the tree names AirDrop but the places that take it off a computer that had it" {
  local path wrong=()
  while IFS= read -r path; do
    [[ " ${ALLOWED[*]} " == *" $path "* ]] || wrong+=("$path")
  done < <(naming | sort -u)
  [ "${#wrong[@]}" -eq 0 ] || { printf 'names AirDrop, which Nova no longer has: %s\n' "${wrong[@]}"; false; }
}

@test "each place allowed to name AirDrop still does" {
  local path stale=()
  for path in "${ALLOWED[@]}"; do
    grep -qi airdrop "$REPO_ROOT/$path" || stale+=("$path")
  done
  [ "${#stale[@]}" -eq 0 ] || { printf 'no longer names AirDrop: take it off the list: %s\n' "${stale[@]}"; false; }
}
