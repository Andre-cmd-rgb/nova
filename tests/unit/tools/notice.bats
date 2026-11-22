#!/usr/bin/env bats

# NOTICE names every program of another project that the [nova] repository
# carries, by the folder under packaging/ that builds it, and every patch Nova
# applies to one: each patch a PKGBUILD lists in its source=, a file kept
# beside it or one it fetches by URL (the kernel's), by its file name. A
# package added, or a patch, and not named there makes NOTICE say less than
# Nova ships. The source arrays are read as makepkg reads them, by bash.

load ../test_helper

# Nova's own packages; every other folder builds somebody else's program.
OWN=(nova nova-keyring)

# Each PKGBUILD's source entries, one a line, as "folder<TAB>entry".
sources() {
  local pkgbuild dir
  for pkgbuild in "$REPO_ROOT"/packaging/*/PKGBUILD; do
    dir=$(dirname "$pkgbuild")
    (cd "$dir" && env -i PATH="$PATH" CARCH=x86_64 bash -c 'source ./PKGBUILD >/dev/null 2>&1; printf "%s\n" "${source[@]}"') |
      sed "s|^|${dir##*/}\t|"
  done
}

@test "NOTICE names every folder under packaging/ that builds another project's program" {
  local dir name missing=()
  for dir in "$REPO_ROOT"/packaging/*/; do
    name=$(basename "$dir")
    [[ " ${OWN[*]} " == *" $name "* ]] && continue
    grep -qF -- "packaging/$name" "$REPO_ROOT/NOTICE" || missing+=("packaging/$name")
  done
  [ "${#missing[@]}" -eq 0 ] || {
    printf 'not named in NOTICE: %s\n' "${missing[@]}"
    false
  }
}

@test "NOTICE names every patch a PKGBUILD applies, a file beside it or one fetched by URL" {
  local dir entry name missing=() seen=0
  while IFS=$'\t' read -r dir entry; do
    [[ -n $entry ]] || continue
    # name::url names the download; a bare URL or file is its last part.
    if [[ $entry == *::* ]]; then name=${entry%%::*}; else name=${entry##*/}; fi
    name=${name%%[?#]*}
    [[ $name == *.patch || $name == *.patch.* || $name == *.diff ]] || continue
    [[ $name != *.sig ]] || continue
    seen=$((seen + 1))
    grep -qF -- "$name" "$REPO_ROOT/NOTICE" || missing+=("$dir: $name")
  done < <(sources)
  # Hyprland's six and the kernel's two, at least: a parse that finds none
  # would pass by checking nothing.
  [ "$seen" -ge 8 ]
  [ "${#missing[@]}" -eq 0 ] || {
    printf 'not named in NOTICE: %s\n' "${missing[@]}"
    false
  }
}

@test "every patch file kept beside a PKGBUILD is in its source=" {
  # A patch file the PKGBUILD does not list is applied by nothing; the test
  # above reads source=, so this keeps the two in step.
  local patch dir listed missing=()
  for patch in "$REPO_ROOT"/packaging/*/*.patch; do
    [[ -e $patch ]] || continue
    dir=$(basename "$(dirname "$patch")")
    listed=$(sources | awk -F '\t' -v d="$dir" -v p="${patch##*/}" '$1 == d && ($2 == p || $2 ~ ("^" p "::")) { n++ } END { print n + 0 }')
    [ "$listed" -gt 0 ] || missing+=("${patch#"$REPO_ROOT"/}")
  done
  [ "${#missing[@]}" -eq 0 ] || {
    printf 'not in its source=: %s\n' "${missing[@]}"
    false
  }
}
