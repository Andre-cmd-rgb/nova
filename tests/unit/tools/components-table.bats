#!/usr/bin/env bats

# docs/ARCHITECTURE.md's "Components and where they install" names every part
# of Nova: each folder with an install.mk has a row of its own, and each Rust
# crate of the workspace has one, or is named, by what it builds, in the row
# of the folder it lives in. Two components once went in with no row.

load ../test_helper

# The table's rows, as they are.
rows() {
  awk '/^## Components and where they install/ { on = 1; next } on && /^## / { exit } on && /^\| `/' "$REPO_ROOT/docs/ARCHITECTURE.md"
}

# The folders a row names in its first column.
named() {
  rows | awk -F' \\| ' '{ print $1 }' | grep -o '`[^`]*`' | tr -d '`' | sed 's|/$||'
}

@test "every folder with an install.mk has a row, or rows for what is in it" {
  local missing=() dir
  while IFS= read -r dir; do
    case $dir in tests/* | tools) continue ;; esac
    named | grep -qE -- "^$dir(/|$)" || missing+=("$dir")
  done < <(cd "$REPO_ROOT" && git ls-files '*install.mk' | sed 's|/install.mk$||' | grep -v '^install.mk$')
  [ "${#missing[@]}" -eq 0 ] || { printf 'no row: %s\n' "${missing[@]}"; false; }
}

@test "every crate of the workspace has a row, or is named in its folder's" {
  local missing=() member names parent row found name
  members=$(sed -n 's/^members *= *\[\(.*\)\]/\1/p' "$REPO_ROOT/Cargo.toml" | tr -d '" ' | tr ',' '\n')
  [ -n "$members" ]
  while IFS= read -r member; do
    named | grep -qxF -- "$member" && continue
    # What it builds: the package's name and its programs' and library's.
    names=$(sed -n 's/^name *= *"\([^"]*\)"/\1/p' "$REPO_ROOT/$member/Cargo.toml")
    parent=${member%/*}
    found=0
    while [[ $parent == */* ]] && ! named | grep -qxF -- "$parent"; do parent=${parent%/*}; done
    row=$(rows | grep -F -- "| \`$parent/\`" || true)
    for name in $names; do
      [[ $row == *"$name"* || $row == *"${name//-/_}"* ]] && found=1
    done
    ((found)) || missing+=("$member")
  done <<<"$members"
  [ "${#missing[@]}" -eq 0 ] || { printf 'not in the table: %s\n' "${missing[@]}"; false; }
}
