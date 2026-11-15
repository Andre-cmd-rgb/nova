#!/usr/bin/env bats
load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home" XDG_DATA_HOME="$SCRATCH/user" XDG_DATA_DIRS="$SCRATCH/system"
  export PATH="$SCRATCH/bin:$PATH" CALLS="$SCRATCH/calls" OWNER=editor
  mkdir -p "$SCRATCH/bin" "$XDG_DATA_DIRS/applications" "$XDG_DATA_HOME/applications"
  write_file "$XDG_DATA_DIRS/applications/editor.desktop" '[Desktop Entry]'
  stub pacman 'case $1 in
    -Qqo) [[ -n $OWNER ]] || exit 1; echo "$OWNER" ;;
    -R*)
      # As pacman: -n and --print are not taken together.
      if [[ $1 == -Rns && " $* " == *" --print "* ]]; then
        echo "error: invalid option: '"'"'--nosave'"'"' and '"'"'--print'"'"' may not be used together" >&2; exit 1
      fi
      if [[ -n ${DEPENDENCY_ERROR:-} ]]; then echo "$DEPENDENCY_ERROR" >&2; exit 1; fi ;;
  esac'
  stub pkexec 'if [[ -n ${REMOVE_ERROR:-} ]]; then echo "$REMOVE_ERROR" >&2; exit 1; fi'
  stub nova-notification-send ':'
  stub update-desktop-database ':'
  stub flatpak 'case $1 in
    info) [[ $2 == "${FLATPAK_SCOPE:-}" ]] ;;
    uninstall) if [[ -n ${REMOVE_ERROR:-} ]]; then echo "$REMOVE_ERROR" >&2; exit 1; fi ;;
  esac'
  remove="$REPO_ROOT/src/cli/bin/nova-remove-launcher-entry"
}
teardown() { teardown_scratch; }
stub() {
  printf '#!/bin/bash\nprintf "%%s\\n" "%s $*" >>"$CALLS"\n%s\n' "$1" "$2" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

@test "launcher removal checks dependencies before one polkit removal and reports success" {
  run "$remove" editor 'Text Editor'
  [ "$status" -eq 0 ]
  [[ $(cat "$CALLS") == *'pacman -Rs --print --print-format %n -- editor'*'pkexec pacman -Rns --noconfirm -- editor'*'nova-notification-send Removed Text Editor'* ]]
  [ "$(grep -c '^pkexec ' "$CALLS")" -eq 1 ]
}

@test "Nova and its required packages cannot be removed" {
  OWNER=nova run "$remove" editor
  [ "$status" -eq 1 ]
  [[ $(cat "$CALLS") == *'part of Nova'* ]]
  fails grep -qE '^pkexec ' "$CALLS"
  OWNER=nova-keyring run "$remove" editor
  [ "$status" -eq 1 ]
  DEPENDENCY_ERROR="error: removing editor breaks dependency 'editor' required by nova" run "$remove" editor
  [ "$status" -eq 1 ]
  [[ $(cat "$CALLS") == *'required by nova'* ]]
  fails grep -qE '^pkexec ' "$CALLS"
}

@test "another app needing a package refuses removal and explains why" {
  DEPENDENCY_ERROR="removing editor breaks dependency required by another-app" run "$remove" editor
  [ "$status" -eq 1 ]
  [[ $(cat "$CALLS") == *'Could not remove editor removing editor breaks dependency required by another-app'* ]]
  fails grep -qE '^pkexec ' "$CALLS"
}

@test "polkit cancellation or a transaction failure is reported" {
  REMOVE_ERROR='Authentication dismissed' run "$remove" editor 'My Editor'
  [ "$status" -eq 1 ]
  [[ $(cat "$CALLS") == *'Could not remove My Editor Authentication dismissed'* ]]
  [[ $(cat "$CALLS") != *'nova-notification-send Removed '* ]]
}

@test "user and system flatpaks use their own scope without pkexec" {
  OWNER='' FLATPAK_SCOPE=--user run "$remove" editor
  [ "$status" -eq 0 ]
  [[ $(cat "$CALLS") == *'flatpak uninstall --user -y -- editor'* ]]
  fails grep -qE '^pkexec ' "$CALLS"
  OWNER='' FLATPAK_SCOPE=--system run "$remove" editor
  [ "$status" -eq 0 ]
  [[ $(cat "$CALLS") == *'flatpak uninstall --system -y -- editor'* ]]
}

@test "a user launcher is deleted and unknown system launchers stay put" {
  write_file "$XDG_DATA_HOME/applications/editor.desktop" '[Desktop Entry]'
  run "$remove" editor
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_DATA_HOME/applications/editor.desktop" ]
  fails grep -qE '^pkexec |^pacman |^flatpak ' "$CALLS"
  OWNER='' run "$remove" editor
  [ "$status" -eq 1 ]
  [ -f "$XDG_DATA_DIRS/applications/editor.desktop" ]
  [[ $(cat "$CALLS") == *'No package owns'* ]]
}

@test "launcher IDs cannot traverse directories and names stay literal" {
  run "$remove" ../editor
  [ "$status" -eq 2 ]
  [ ! -e "$CALLS" ]
  run "$remove" editor 'Editor; $(touch unsafe)'
  [ "$status" -eq 0 ]
  [[ $(cat "$CALLS") == *'Removed Editor; $(touch unsafe)'* ]]
  [ ! -e unsafe ]
}
