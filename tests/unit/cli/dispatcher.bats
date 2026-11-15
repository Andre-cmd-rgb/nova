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
  printf '\177ELF' >"$NOVA_BIN/nova-undervolt"
  chmod +x "$NOVA_BIN/nova-undervolt"
  run nova help
  [ "$status" -eq 0 ]
  [[ $output != *undervolt* ]]
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
