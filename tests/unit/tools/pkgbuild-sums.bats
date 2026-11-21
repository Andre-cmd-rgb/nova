#!/usr/bin/env bats

# Each PKGBUILD's own files (its patches, configs and keys) are the files its
# checksums name. makepkg refuses a file that changed under its checksum, but
# only in the release's build, after the change is merged; this says it on
# the change. A source that is downloaded (an address, or git+) is makepkg's
# to check, and SKIP is a checksum the PKGBUILD chose not to have.

load ../test_helper

setup() { setup_scratch; }
teardown() { teardown_scratch; }

# <folder>: a line "<what is wrong>: <file>" for each of the folder's own
# files whose checksum (sha256sums or b2sums) is missing or does not match.
wrong_sums() {
  (
    cd "$1" || exit 2
    # shellcheck disable=SC2034 # read by the PKGBUILD (linux-nova's config)
    CARCH=x86_64
    source=()
    # shellcheck disable=SC1091 # each PKGBUILD in turn
    source ./PKGBUILD >/dev/null 2>&1 || {
      echo "the PKGBUILD does not source: $1"
      exit 0
    }
    for i in "${!source[@]}"; do
      entry=${source[$i]}
      file=${entry%%::*}
      [[ $entry == *::* ]] && entry=${entry#*::}
      [[ $entry == *://* ]] && continue
      checked=false
      for kind in sha256 b2; do
        declare -n sums=${kind}sums
        [[ -v sums[@] ]] || continue
        checked=true
        want=${sums[$i]-}
        [[ $want == SKIP ]] && continue
        if [[ ! -f $file ]]; then
          echo "no such file: $1/$file"
        elif [[ -z $want ]]; then
          echo "no ${kind}sum: $1/$file"
        elif [[ $("${kind}sum" -- "$file" | cut -d' ' -f1) != "$want" ]]; then
          echo "${kind}sum does not match: $1/$file"
        fi
      done
      $checked || echo "no checksums: $1/$file"
    done
  )
}

@test "every PKGBUILD's own files match their checksums" {
  local dir out=""
  for dir in "$REPO_ROOT"/packaging/*/; do
    [[ -f $dir/PKGBUILD ]] || continue
    out+=$(wrong_sums "${dir%/}")
  done
  [ -z "$out" ] || {
    printf '%s\n' "$out"
    false
  }
}

@test "a patch changed under its checksum, or a file without one, is named" {
  cp -r "$REPO_ROOT/packaging/hyprland" "$SCRATCH/hyprland"
  [ -z "$(wrong_sums "$SCRATCH/hyprland")" ]
  printf '\n' >>"$SCRATCH/hyprland/stencil-without-depth.patch"
  run wrong_sums "$SCRATCH/hyprland"
  [ "$output" = "sha256sum does not match: $SCRATCH/hyprland/stencil-without-depth.patch" ]
  cp -r "$REPO_ROOT/packaging/nova-keyring" "$SCRATCH/keyring"
  [ -z "$(wrong_sums "$SCRATCH/keyring")" ]
  sed -i 's/^sha256sums=(SKIP SKIP SKIP)$/sha256sums=(SKIP SKIP)/' "$SCRATCH/keyring/PKGBUILD"
  run wrong_sums "$SCRATCH/keyring"
  [ "$output" = "no sha256sum: $SCRATCH/keyring/nova-revoked" ]
}
