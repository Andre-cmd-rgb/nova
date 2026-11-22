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

# The install rules, a rule continued with a backslash joined into one line.
install_rules() {
  local file
  while IFS= read -r file; do
    awk '/\\$/ { sub(/\\$/, ""); printf "%s", $0; next } { print }' "$REPO_ROOT/$file"
  done < <(cd "$REPO_ROOT" && git ls-files '*install.mk')
}

# The programs from cargo's release folder that the install puts in <dir>
# (NOVA_BIN or NOVA_LIB), by the names they get there: `install src
# <dir>/name`, or `install -t <dir> src...`.
installed_into() {
  install_rules | awk -v dir="\$(DESTDIR)\$($1)" '
    /(^|[[:space:]])install[[:space:]]/ {
      into = 0
      for (i = 1; i < NF; i++) if ($i == "-t" && $(i + 1) == dir) into = 1
      for (i = 1; i <= NF; i++) {
        if ($i !~ /target\)\/release\//) continue
        if (into) { name = $i; sub(/.*\//, "", name); print name }
        else if (i < NF && index($(i + 1), dir "/") == 1) { name = $(i + 1); sub(/.*\//, "", name); print name }
      }
    }'
}

# What the install puts among the helpers that is compiled, so carries no
# summary of its own: a program from cargo's release folder, or a link to one
# of those it put in /usr/lib/nova.
compiled_helpers() {
  local libs name target
  libs=" $(installed_into NOVA_LIB | tr '\n' ' ') "
  installed_into NOVA_BIN | grep '^nova-' || true
  install_rules | grep -o 'ln -sfn* \.\./[A-Za-z0-9_-]* $(DESTDIR)$(NOVA_BIN)/nova-[A-Za-z0-9_-]*' |
    while read -r _ _ target name; do
      [[ $libs == *" ${target#../} "* ]] && echo "${name##*/}"
    done
}

@test "every compiled helper the install puts in place has a summary, or stays out of the help" {
  local names name listed=()
  names=$(compiled_helpers | sort -u)
  # The ones there are now, at least: the list is read from the install.
  [[ $names == *nova-theme* && $names == *nova-tray-quit* && $names == *nova-pinentry* ]]
  # Put in place by a rule over several lines, `install -t`.
  [[ $names == *nova-password-change* && $names == *nova-keyring-migrate* ]]
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
