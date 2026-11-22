#!/usr/bin/env bats

# The shell's plugins README is where a reader finds each plugin: one that
# has a README of its own is linked from its name in the table there.

load ../test_helper

@test "every plugin's own README is linked from the plugins table" {
  local readme dir missing=()
  for readme in "$REPO_ROOT"/src/shell/plugins/*/README.md; do
    dir=${readme%/README.md}
    dir=${dir##*/}
    grep -qE "^\| \[[^]]+\]\($dir/README\.md\) \|" "$REPO_ROOT/src/shell/plugins/README.md" || missing+=("$dir")
  done
  [ "${#missing[@]}" -eq 0 ] || { printf 'not linked: %s\n' "${missing[@]}"; false; }
}
