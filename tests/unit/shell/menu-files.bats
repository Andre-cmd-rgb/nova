#!/usr/bin/env bats

# The menu's file search (plugins/menu/files.sh), on a home made here: what
# it lists and leaves out, how it ranks what it finds, the files opened
# lately first, and that it lists the home again only behind a search whose
# list is five minutes old, one walk at a time.

load ../test_helper

files="$REPO_ROOT/src/shell/plugins/menu/files.sh"

setup() {
  setup_scratch
  export HOME=$SCRATCH/home XDG_RUNTIME_DIR=$SCRATCH/run
  unset XDG_DATA_HOME
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
  put app/target/release/notes.d app/fresh.md
  touch -d '-6 min' "$XDG_RUNTIME_DIR/nova/menu-files"
  "$files" list
  grep -q $'\tfresh.md\t' "$XDG_RUNTIME_DIR/nova/menu-files"
  fails grep -q target "$XDG_RUNTIME_DIR/nova/menu-files"
}

@test "nothing mounted under the home is walked, whatever its name" {
  put Remote\ Drive/notes.txt Projects/notes.md
  # The mount table writes a space as \040.
  export NOVA_MOUNTS=$SCRATCH/mounts
  printf '%s\n' "/dev/root / btrfs rw 0 0" "server:/srv $HOME/Remote\\040Drive nfs4 rw 0 0" >"$NOVA_MOUNTS"
  run find_ notes
  [ "$output" = $'f\tProjects/notes.md' ]
}

@test "five folders down, and no more" {
  put a/b/c/d/report.txt a/b/c/d/e/report-deep.txt
  run find_ report
  [ "$output" = $'f\ta/b/c/d/report.txt' ]
}

@test "the first search lists the home; one five minutes on answers from the old list and lists it again behind" {
  local list=$XDG_RUNTIME_DIR/nova/menu-files
  put old.txt
  run find_ old
  [ "$output" = $'f\told.txt' ]
  put new.txt
  run find_ new
  [ -z "$output" ]
  touch -d '-6 min' "$list"
  run find_ new
  [ -z "$output" ]
  for _ in {1..50}; do grep -q $'\tnew.txt\t' "$list" && break; sleep 0.1; done
  run find_ new
  [ "$output" = $'f\tnew.txt' ]
}

@test "a search while the home is being walked waits for that walk, and takes its list without walking again" {
  local list=$XDG_RUNTIME_DIR/nova/menu-files
  mkdir -p "${list%/*}"
  # Another walk, slow, whose list has a file not on the disk: one walked
  # again would not.
  (
    flock 9
    sleep 1
    printf 'f\t1\tghost.txt\t%s\n' "$HOME" >"$list"
  ) 9>"$list.lock" &
  sleep 0.2
  run find_ ghost
  wait
  [ "$output" = $'f\tghost.txt' ]
}

@test "nothing searched, nothing found; anything else is how to use it" {
  put a.txt
  run "$files" find "  "
  [ "$status" -eq 0 ] && [ -z "$output" ]
  run "$files" sideways
  [ "$status" -eq 2 ]
  [[ $output == *"files.sh find <words>"* ]]
}

# Files opened at <when>, noted in recently-used.xbel as GTK writes it: a
# bookmark a file, its href a URI written in XML, an application's own
# modified time inside it.
opened() { # when uri-path...
  local when=$1 bookmarks=$SCRATCH/bookmarks uri
  shift
  for uri; do
    printf '  <bookmark href="file://%s" added="%s" modified="%s" visited="%s">\n' "$HOME/$uri" "$when" "$when" "$when"
    printf '    <info><metadata owner="http://freedesktop.org"><bookmark:applications>\n'
    printf '      <bookmark:application name="loupe" exec="&apos;loupe %%u&apos;" modified="2020-01-01T00:00:00Z" count="1"/>\n'
    printf '    </bookmark:applications></metadata></info>\n  </bookmark>\n'
  done >>"$bookmarks"
  mkdir -p "$HOME/.local/share"
  { printf '<?xml version="1.0" encoding="UTF-8"?>\n<xbel version="1.0">\n'; cat "$bookmarks"; printf '</xbel>\n'; } \
    >"$HOME/.local/share/recently-used.xbel"
}

@test "files opened lately come first, the newest first, wherever they are in the home" {
  put Documents/tax/ Documents/taxes.pdf "Old/Tax Return 2019.pdf" .notes/tax-notes.md "a/b/c/d/e/tax deep.txt" \
    Projects/syntax.txt Mount/tax-remote.pdf
  opened 2026-11-01T09:00:00Z "Old/Tax%20Return%202019.pdf" .notes/tax-notes.md
  opened 2026-11-10T09:00:00Z "a/b/c/d/e/tax%20deep.txt" Projects/syntax.txt Gone/taxman.pdf Mount/tax-remote.pdf
  export NOVA_MOUNTS=$SCRATCH/mounts
  printf '%s\n' "/dev/root / btrfs rw 0 0" "server:/srv $HOME/Mount nfs4 rw 0 0" >"$NOVA_MOUNTS"
  run find_ tax
  # Hidden and six folders down are found too. A name that only holds the
  # word (syntax) gets no lift; one gone, or below a mount, is not shown.
  [ "${lines[0]}" = $'f\ta/b/c/d/e/tax deep.txt' ]
  [ "${lines[1]}" = $'f\tOld/Tax Return 2019.pdf' ]
  [ "${lines[2]}" = $'f\t.notes/tax-notes.md' ]
  [ "${lines[3]}" = $'d\tDocuments/tax' ]
  [ "${lines[4]}" = $'f\tDocuments/taxes.pdf' ]
  [ "${#lines[@]}" -eq 5 ]
}

@test "a file opened lately is listed once, the better match first, its name read whole" {
  put "Notes & Ideas/plan.txt" "it's a plan.md" "caffè plan.txt"
  opened 2026-11-01T09:00:00Z "Notes%20&amp;%20Ideas/plan.txt" "it&apos;s%20a%20plan.md" "caff%C3%A8%20plan.txt"
  run find_ plan
  [ "$output" = "$(printf 'f\t%s\n' "Notes & Ideas/plan.txt" "it's a plan.md" "caffè plan.txt")" ]
}

@test "no recently-used.xbel, or one that is not one: the home's files as ever" {
  put plans.txt
  run find_ plan
  [ "$output" = $'f\tplans.txt' ]
  mkdir -p "$HOME/.local/share"
  printf 'not xml at all\n<bookmark href="file://\n' >"$HOME/.local/share/recently-used.xbel"
  run find_ plan
  [ "$output" = $'f\tplans.txt' ]
}
