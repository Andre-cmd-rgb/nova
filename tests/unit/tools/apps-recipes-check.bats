#!/usr/bin/env bats

# tools/apps-recipes-check: every optional dependency of an Arch app on the
# App Center's front page has a with or a skip. Real pacman, on repositories
# of the test's own, and a catalog program that lists the front page as the
# test says.

load ../test_helper

check=$REPO_ROOT/tools/apps-recipes-check

setup() {
  setup_scratch
  command -v pacman >/dev/null && command -v bsdtar >/dev/null || skip "no pacman or bsdtar"
  mkdir -p "$SCRATCH/db/sync" "$SCRATCH/repo" "$SCRATCH/swcatalog/xml"
  # The front page: the apps the featured file names, each a package of the
  # same name; the catalog program sees nothing else (env -i).
  cat >"$SCRATCH/catalog" <<'EOF'
#!/bin/bash
mkdir -p "$NOVA_APPS_CACHE"
jq -R -s '{apps: [split("\n")[] | select(length > 0) | {id: ., featured: "play", sources: [{kind: "arch", package: .}]}]
  + [{id: "not.featured", sources: [{kind: "arch", package: "elsewhere"}]}]}' \
  <(awk '!/^#/ && NF { print $2 }' "$NOVA_PATH/apps/featured") >"$NOVA_APPS_CACHE/catalog.json"
echo "$NOVA_APPS_CACHE/catalog.json"
EOF
  chmod +x "$SCRATCH/catalog"
  : >"$SCRATCH/featured"
}

teardown() { teardown_scratch; }

front() { printf 'popular %s\n' "$@" >"$SCRATCH/featured"; }

package() { # name [depends] [optdepends] [provides], each a space-separated list
  local dir=$SCRATCH/repo/$1-1-1
  mkdir -p "$dir"
  printf '%%NAME%%\n%s\n\n%%VERSION%%\n1-1\n\n%%ARCH%%\nany\n\n%%FILENAME%%\n%s-1-1-any.pkg.tar\n\n' "$1" "$1" >"$dir/desc"
  field "$dir" DEPENDS "${2:-}" ''
  field "$dir" OPTDEPENDS "${3:-}" ': what it is for'
  field "$dir" PROVIDES "${4:-}" ''
}

field() { # dir name list suffix
  local word
  [[ -n $3 ]] || return 0
  {
    printf '%%%s%%\n' "$2"
    for word in $3; do printf '%s%s\n' "$word" "$4"; done
    echo
  } >>"$1/desc"
}

run_check() { # recipe text
  printf '%s\n' "$1" >"$SCRATCH/recipes"
  (cd "$SCRATCH/repo" && bsdtar -czf "$SCRATCH/db/sync/extra.db" -- *)
  bsdtar -czf "$SCRATCH/db/sync/core.db" --files-from /dev/null
  cp "$SCRATCH/db/sync/core.db" "$SCRATCH/db/sync/multilib.db"
  run "$check" --dbpath "$SCRATCH/db" --swcatalog "$SCRATCH/swcatalog" --catalog "$SCRATCH/catalog" \
    --recipes "$SCRATCH/recipes" --featured "$SCRATCH/featured"
}

@test "every optional dependency decided: by a with, a skip, the app's own dependencies or what a with provides" {
  package player 'libplayer' 'plugins docs libplayer spell-dictionary'
  package libplayer
  package plugins
  package docs
  package spell-en '' '' 'spell-dictionary'
  front player
  run_check $'player with plugins spell-en # comment\nplayer skip docs'
  [ "$status" -eq 0 ]
  [ "$output" = "apps-recipes-check: 1 apps from Arch on the front page, every optional dependency decided" ]
}

@test "an optional dependency nothing decides is named, with the app" {
  package player '' 'plugins docs'
  package plugins
  package docs
  front player
  run_check 'player with plugins'
  [ "$status" -eq 1 ]
  [[ $output == *"player: nothing decides its optional dependency docs (a with or a skip)"* ]]
  [[ $output != *plugins\ \(a* ]]
}

@test "a with or a recipe's app not in the repositories, and a skip that is no optional dependency any more" {
  package player '' 'plugins'
  package plugins
  front player
  run_check $'player with plugins gone\nplayer skip dropped\nvanished with plugins'
  [ "$status" -eq 1 ]
  [[ $output == *"player: with gone, which is not in the repositories"* ]]
  [[ $output == *"player: skip dropped, which is not one of its optional dependencies"* ]]
  [[ $output == *"vanished: a recipe names it, and it is not in the repositories"* ]]
}

@test "an app off the front page needs no decisions, but its recipe is still checked" {
  package elsewhere '' 'extra-thing'
  package extra-thing
  package player
  front player
  run_check 'elsewhere skip not-optional'
  [ "$status" -eq 1 ]
  [[ $output == *"elsewhere: skip not-optional"* ]]
  [[ $output != *extra-thing* ]]
  run_check ''
  [ "$status" -eq 0 ]
}

@test "without its inputs it says which is missing, and it takes no other arguments" {
  run "$check" --dbpath "$SCRATCH/none"
  [ "$status" -eq 2 ]
  [[ $output == *"core.db"* ]]
  run "$check" --bogus
  [ "$status" -eq 2 ]
  run "$check" --help
  [ "$status" -eq 0 ]
  [[ $output == *"--flathub"* ]]
}

# Where it stops a release: against the snapshot the release pins, the
# packages its systems install apps from, before anything is published.
@test "the release runs it on the snapshot it pins, and publishes only once it passes" {
  local wf=$REPO_ROOT/.github/workflows/release.yml job
  job=$(sed -n '/^  recipes:$/,/^  [a-z-]*:$/p' "$wf")
  [[ $job == *"needs: pin"* ]]
  [[ $job == *'tools/ci-setup --date "${{ needs.pin.outputs.arch_date }}"'* ]]
  [[ $job == *"tools/apps-recipes-check --flathub"* ]]
  sed -n '/^  publish:$/,/needs:/p' "$wf" | grep -qE '^    needs: \[.*\<recipes\>.*\]$'
}
