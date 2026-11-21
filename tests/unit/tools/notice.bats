#!/usr/bin/env bats

# NOTICE says which of the programs Nova packages it changes, patch by patch.
# A patch added beside a PKGBUILD and not named there makes NOTICE say less
# than Nova does to another project's code.

load ../test_helper

@test "NOTICE names every patch Nova applies to a program it packages" {
  local patch missing=()
  for patch in "$REPO_ROOT"/packaging/*/*.patch; do
    grep -qF -- "${patch##*/}" "$REPO_ROOT/NOTICE" || missing+=("${patch#"$REPO_ROOT"/}")
  done
  [ "${#missing[@]}" -eq 0 ] || {
    printf 'not named in NOTICE: %s\n' "${missing[@]}"
    false
  }
}
