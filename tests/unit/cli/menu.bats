#!/usr/bin/env bats

# The default menu: every entry has an icon. Nerd Font glyphs in U+E000-U+F8FF
# are easy to lose when the file is rewritten, and an empty one only shows as
# a gap in the menu.

load ../test_helper

@test "every menu entry has an icon" {
  run grep -n '"icon":""' "$REPO_ROOT/data/defaults/menu.jsonc"
  [[ $status -eq 1 ]] || { echo "$output"; false; }
  grep -q '"icon":' "$REPO_ROOT/data/defaults/menu.jsonc"
}
