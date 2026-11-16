#!/usr/bin/env bats

# The menu's file search (plugins/menu/files.sh), on a home made here: what
# it lists and leaves out, how it ranks what it finds, and that it lists
# again only as the menu opens, and not twice in 30 s.

load ../test_helper

files="$REPO_ROOT/src/shell/plugins/menu/files.sh"

setup() {
  setup_scratch
  export HOME=$SCRATCH/home XDG_RUNTIME_DIR=$SCRATCH/run
  mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
}

teardown() { teardown_scratch; }

put() { # path... (a trailing / makes a folder)
  local path
  for path; do
    if [[ $path == */ ]]; then mkdir -p "$HOME/$path"; else mkdir -p "$(dirname "$HOME/$path")" && : >"$HOME/$path"; fi
  done
}

find_() { "$files" find "$@" | sed "s#$HOME/##"; }

@test "the best first: the name, its start, a word's start, anywhere; and a folder down counts" {
  put Documents/ Projects/app/src/doc/ Downloads/tax-2025.pdf Downloads/2025-taxes.ods Documents/syntax.txt \
    Documents/tax/ Documents/taxes.pdf Projects/app/src/tax.rs
  run find_ tax
  [ "${lines[0]}" = $'d\tDocuments/tax' ]
  # Two that start with it, the shorter name first.
  [ "${lines[1]}" = $'f\tDocuments/taxes.pdf' ]
  [ "${lines[2]}" = $'f\tDownloads/tax-2025.pdf' ]
  # The name itself three folders down is as good as a word's start one
  # down, and goes first; the five shown leave out syntax.txt.
  [ "${lines[3]}" = $'f\tProjects/app/src/tax.rs' ]
  [ "${lines[4]}" = $'f\tDownloads/2025-taxes.ods' ]
  [ "${#lines[@]}" -eq 5 ]
  # ~/Documents, one down, before an exact doc folder four down.
  run find_ doc
  [ "${lines[0]}" = $'d\tDocuments' ]
  [ "${lines[1]}" = $'d\tProjects/app/src/doc' ]
}

@test "every word in the name, in any case; a path's folders are not its name" {
  put Music/Live/Song.flac Downloads/Tax-Return-2025.PDF Downloads/notes.txt
  run find_ "return tax"
  [ "$output" = $'f\tDownloads/Tax-Return-2025.PDF' ]
  run find_ live
  [ "$output" = $'d\tMusic/Live' ]
  # Characters grep and awk would read as patterns are only letters.
  run find_ "[x"
  [ -z "$output" ]
  run find_ 'n.t*s'
  [ -z "$output" ]
}

@test "hidden folders, git, node_modules and what a cache tag marks stay out" {
  put .config/notes.txt notes/.git/notes.pack app/node_modules/notes/ app/__pycache__/notes.pyc \
    app/target/CACHEDIR.TAG app/target/debug/notes.d app/notes.md
  run find_ notes
  [ "$output" = "$(printf 'd\tnotes\nf\tapp/notes.md')" ]
  # The cache found is passed by on the next walk.
  grep -qx "$HOME/app/target" "$XDG_RUNTIME_DIR/nova/menu-files.caches"
  put app/target/release/notes.d
  touch -d '-1 min' "$XDG_RUNTIME_DIR/nova/menu-files"
  "$files" list
  fails grep -q target "$XDG_RUNTIME_DIR/nova/menu-files"
}

@test "five folders down, and no more" {
  put a/b/c/d/report.txt a/b/c/d/e/report-deep.txt
  run find_ report
  [ "$output" = $'f\ta/b/c/d/report.txt' ]
}

@test "listed again as the menu opens, not twice in 30 s; the first search lists itself" {
  put old.txt
  run find_ old
  [ "$output" = $'f\told.txt' ]
  put new.txt
  "$files" list
  run find_ new
  [ -z "$output" ]
  touch -d '-31 sec' "$XDG_RUNTIME_DIR/nova/menu-files"
  "$files" list
  run find_ new
  [ "$output" = $'f\tnew.txt' ]
}

@test "nothing searched, nothing found; anything else is how to use it" {
  put a.txt
  run "$files" find "  "
  [ "$status" -eq 0 ] && [ -z "$output" ]
  run "$files" sideways
  [ "$status" -eq 2 ]
  [[ $output == *"files.sh find <words>"* ]]
}
