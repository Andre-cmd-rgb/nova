#!/usr/bin/env bats

# The nova dispatcher against a scratch helper directory: which helper a
# command line runs, with which arguments, and what it lists.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_BIN="$SCRATCH/bin"
  mkdir -p "$NOVA_BIN"
  helper nova-theme-set '# nova:summary=Switch the theme'
  helper nova-theme '# nova:summary=Theme commands'
  helper nova-doctor '# nova:summary=Look this computer over'
  helper nova-boot-check '# nova:hidden=true'
}

teardown() { teardown_scratch; }

helper() { # name [comment]: a helper that prints its name, arguments and PATH
  printf '#!/bin/bash\n%s\necho "%s $*"\necho "PATH=$PATH"\n' "${2:-}" "$1" >"$NOVA_BIN/$1"
  chmod +x "$NOVA_BIN/$1"
}

nova() { "$REPO_ROOT/src/cli/nova" "$@"; }

@test "the longest helper name the words spell wins, the rest are arguments" {
  run nova theme set white
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "nova-theme-set white" ]
  run nova theme list
  [ "${lines[0]}" = "nova-theme list" ]
}

@test "a word a helper name cannot contain ends the name" {
  run nova theme set --help
  [ "${lines[0]}" = "nova-theme-set --help" ]
}

@test "helpers find one another by name, also under sudo's PATH" {
  PATH=/usr/bin:/bin run nova doctor
  [ "${lines[1]}" = "PATH=$NOVA_BIN:/usr/bin:/bin" ]
}

@test "help lists visible helpers with their summaries" {
  run nova help
  [ "$status" -eq 0 ]
  [[ $output == *"theme set"*"Switch the theme"* ]]
  [[ $output == *"doctor"*"Look this computer over"* ]]
  [[ $output != *"boot check"* ]]
}

@test "help leaves out a compiled helper that is no command of its own" {
  for helper in nova-undervolt nova-password-change nova-keyring-migrate; do
    printf '\177ELF' >"$NOVA_BIN/$helper"
    chmod +x "$NOVA_BIN/$helper"
  done
  run nova help
  [ "$status" -eq 0 ]
  [[ $output != *undervolt* ]]
  [[ $output != *password* ]]
  [[ $output != *keyring* ]]
}

# What the install puts among the helpers that is compiled, so carries no
# summary of its own: a program from cargo's release folder, or a link to one
# of those it put in /usr/lib/nova.
compiled_helpers() {
  local files libs name target
  mapfile -t files < <(cd "$REPO_ROOT" && git ls-files '*install.mk')
  cd "$REPO_ROOT"
  libs=" $(grep -ho 'target)/release/[A-Za-z0-9_-]* $(DESTDIR)$(NOVA_LIB)/[A-Za-z0-9_-]*' "${files[@]}" | sed 's|.*/||' | tr '\n' ' ') "
  grep -ho 'target)/release/[A-Za-z0-9_-]* $(DESTDIR)$(NOVA_BIN)/nova-[A-Za-z0-9_-]*' "${files[@]}" | sed 's|.*/||'
  grep -ho 'ln -sfn* \.\./[A-Za-z0-9_-]* $(DESTDIR)$(NOVA_BIN)/nova-[A-Za-z0-9_-]*' "${files[@]}" |
    while read -r _ _ target name; do
      [[ $libs == *" ${target#../} "* ]] && echo "${name##*/}"
    done
}

@test "every compiled helper the install puts in place has a summary, or stays out of the help" {
  local names name listed=()
  names=$(compiled_helpers | sort -u)
  # The ones there are now, at least: the list is read from the install.
  [[ $names == *nova-theme* && $names == *nova-tray-quit* && $names == *nova-pinentry* ]]
  for name in $names; do
    printf '\177ELF' >"$NOVA_BIN/$name"
    chmod +x "$NOVA_BIN/$name"
  done
  run nova help
  [ "$status" -eq 0 ]
  for name in $names; do
    words=${name#nova-}
    # Listed, it has its words and then a summary.
    if grep -qE "^  ${words//-/ } +\$" <<<"$output"; then listed+=("$name"); fi
  done
  [ "${#listed[@]}" -eq 0 ] || { printf 'listed with no summary: %s\n' "${listed[@]}"; false; }
  [[ $output != *"tray quit"* && $output != *"calendar sync"* ]]
}

@test "help for a group lists only that group" {
  run nova help theme
  [[ $output == *"theme set"* ]]
  [[ $output != *doctor* ]]
  run nova help nonsense
  [ "$status" -eq 2 ]
}

@test "an unknown command fails with a pointer to help" {
  run nova frobnicate
  [ "$status" -eq 2 ]
  [[ $output == *"unknown command 'frobnicate'"* ]]
}

@test "nova launch lists the launch helpers, a typo is unknown, a helper runs; the launcher itself is never run" {
  helper nova-launch-browser '# nova:summary=Open the browser'
  helper nova-launch ''
  run nova launch
  [ "$status" -eq 0 ]
  [[ $output == *"launch browser"*"Open the browser"* ]]
  [[ $output != "nova-launch "* ]]
  run nova launch brwoser
  [ "$status" -eq 2 ]
  [[ $output == *"unknown command 'launch brwoser'"* ]]
  run nova launch browser https://example.org
  [ "${lines[0]}" = "nova-launch-browser https://example.org" ]
}
