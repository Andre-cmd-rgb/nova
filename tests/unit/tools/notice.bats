#!/usr/bin/env bats

# NOTICE says which of the programs Nova packages it changes, patch by patch.
# A patch added beside a PKGBUILD and not named there makes NOTICE say less
# than Nova does to another project's code. A patch a PKGBUILD fetches by URL
# (the kernel's) is not a file here, so this cannot see it: NOTICE's lines for
# those are kept by hand.

load ../test_helper

@test "NOTICE names every patch file kept beside a PKGBUILD" {
  local patch missing=()
  for patch in "$REPO_ROOT"/packaging/*/*.patch; do
    grep -qF -- "${patch##*/}" "$REPO_ROOT/NOTICE" || missing+=("${patch#"$REPO_ROOT"/}")
  done
  [ "${#missing[@]}" -eq 0 ] || {
    printf 'not named in NOTICE: %s\n' "${missing[@]}"
    false
  }
}
