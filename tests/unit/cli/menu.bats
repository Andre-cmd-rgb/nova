#!/usr/bin/env bats

# The default menu: every entry has an icon. Nerd Font glyphs in U+E000-U+F8FF
# are easy to lose when the file is rewritten, and an empty one only shows as
# a gap in the menu. A search finds every Settings page, and no route is
# taken twice.

load ../test_helper

@test "every menu entry has an icon" {
  run grep -n '"icon":""' "$REPO_ROOT/data/defaults/menu.jsonc"
  [[ $status -eq 1 ]] || { echo "$output"; false; }
  grep -q '"icon":' "$REPO_ROOT/data/defaults/menu.jsonc"
}

# The default menu as JSON: its comments, which are whole lines, and the
# comma before its closing brace out.
menu_json() {
  sed -E '/^\s*\/\//d' "$REPO_ROOT/data/defaults/menu.jsonc" | tr '\n' ' ' | sed -E 's/,\s*\}/}/g'
}

# One entry for each page nova settings opens, in its order, each opening
# its own page.
@test "the menu has an entry for every Settings page, which opens it" {
  pages=$(sed -n 's/^PAGES="\(.*\)"$/\1/p' "$REPO_ROOT/src/cli/bin/nova-settings")
  [ -n "$pages" ]
  listed=$(menu_json | jq -r 'to_entries[] | select(.key | startswith("settings.")) | "\(.key) \(.value.action)"')
  expected=$(for page in $pages; do echo "settings.$page nova-settings $page"; done)
  [ "$listed" = "$expected" ]
}

# An alias is a route too (nova menu toggle theme), and the first entry that
# has it is the one opened: no alias is another entry's, nor an entry's id.
@test "no alias is used twice, nor is an entry's id" {
  taken=$(menu_json | jq -r 'keys_unsorted as $ids | [.[] | .aliases // [] | .[]]
    | (group_by(.) | map(select(length > 1) | .[0])) + map(select(. as $alias | $ids | index($alias)))
    | .[]')
  [ -z "$taken" ]
}
