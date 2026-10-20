#!/usr/bin/env bats

# nova update, end to end with the root step and the system stubbed: what it
# does after a release is applied.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" PKGVER="$SCRATCH/pkgver"
  export NOVA_MIRRORLIST="$SCRATCH/nova-mirrorlist" NOVA_REPOFILE="$SCRATCH/nova-repo"
  export NOVA_UPDATE_APPLY="$SCRATCH/bin/nova-update-apply"
  mkdir -p "$SCRATCH/bin"
  echo 1.0.0beta.1 >"$PKGVER"
  printf 'version = "1.0.0-beta.2"\narch_date = "2026/10/19"\nnova_repo = "https://example.org/repo"\n' >"$SCRATCH/release.toml"
  stub pacman 'echo "nova $(cat "$PKGVER")-1"'
  stub pacman-conf
  stub pkexec '"$@"'
  stub nova-update-apply 'echo 1.0.0beta.2 >"$PKGVER"'
  stub nova-shell
  stub nova-restart-shell
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

update() { "$REPO_ROOT/src/cli/bin/nova-update" --release-file "$SCRATCH/release.toml" --yes; }

@test "a running shell is restarted on the new release" {
  run update
  [ "$status" -eq 0 ]
  grep -q '^nova-update-apply --tag v1.0.0-beta.2' "$CALLS"
  grep -qx 'nova-restart-shell ' "$CALLS"
  [[ $output == *"Restarting the shell"* ]]
}

@test "no shell running, none started" {
  stub nova-shell 'exit 1'
  run update
  [ "$status" -eq 0 ]
  ! grep -q nova-restart-shell "$CALLS"
}

@test "nova unchanged, the shell is left alone" {
  stub nova-update-apply
  run update
  [ "$status" -eq 0 ]
  ! grep -q nova-restart-shell "$CALLS"
}

@test "a failed update restarts nothing" {
  stub nova-update-apply 'exit 3'
  run update
  [ "$status" -eq 3 ]
  ! grep -q nova-restart-shell "$CALLS"
}

@test "a shell that will not restart is a warning, not a failed update" {
  stub nova-restart-shell 'exit 1'
  run update
  [ "$status" -eq 0 ]
  [[ $output == *"log out and back in"* ]]
}
