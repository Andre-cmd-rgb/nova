#!/usr/bin/env bats

# nova-update-home, which nova-session-settle runs once a release is in: an
# account's starting file that is still byte for byte one Nova's skel
# shipped becomes the skel's of this release; any other is the user's and
# kept. A home of the test's own; the skel is the tree's (data/skel).

load ../test_helper

setup() {
  setup_scratch
  export HOME=$SCRATCH/home NOVA_PATH=$SCRATCH/nova
  mkdir -p "$HOME" "$NOVA_PATH"
  ln -s "$REPO_ROOT/data/skel" "$NOVA_PATH/skel"
  OLD=$FIXTURES/skel/bashrc-rc14
  NEW=$REPO_ROOT/data/skel/.bashrc
}

teardown() {
  chmod -R u+w "$SCRATCH" 2>/dev/null || true
  teardown_scratch
}

update_home() { "$REPO_ROOT/src/cli/bin/nova-update-home"; }

# The sums the helper lists for a file.
listed() { # path
  sed -n "s/^  \"$1 \([0-9a-f]\{64\}\)\"\$/\1/p" "$REPO_ROOT/src/cli/bin/nova-update-home"
}

@test "an untouched ~/.bashrc of an earlier release becomes this release's, its mode kept" {
  cp "$OLD" "$HOME/.bashrc"
  chmod 600 "$HOME/.bashrc"
  run update_home
  [ "$status" -eq 0 ]
  [ "$output" = "Replaced ~/.bashrc, still the one Nova gave this account, with this release's." ]
  cmp "$NEW" "$HOME/.bashrc"
  [ "$(stat -c %a "$HOME/.bashrc")" = 600 ]
  [ "$(find "$HOME" -name '.bashrc.*' | wc -l)" -eq 0 ]

  run update_home
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a ~/.bashrc the user changed, even by a line at its end, is theirs and kept" {
  { cat "$OLD"; echo "alias ll='ls -l'"; } >"$HOME/.bashrc"
  cp -p "$HOME/.bashrc" "$SCRATCH/before"
  run update_home
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  cmp "$SCRATCH/before" "$HOME/.bashrc"
  [ "$(stat -c %Y "$HOME/.bashrc")" = "$(stat -c %Y "$SCRATCH/before")" ]
}

@test "a missing ~/.bashrc stays missing, and a link stays a link to what it was" {
  run update_home
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.bashrc" ]

  mkdir "$HOME/dotfiles"
  cp "$OLD" "$HOME/dotfiles/bashrc"
  ln -s dotfiles/bashrc "$HOME/.bashrc"
  run update_home
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(readlink "$HOME/.bashrc")" = dotfiles/bashrc ]
  cmp "$OLD" "$HOME/dotfiles/bashrc"
}

@test "a home it cannot write to: said, the file kept, and no failure for the update" {
  cp "$OLD" "$HOME/.bashrc"
  chmod 555 "$HOME"
  run update_home
  [ "$status" -eq 0 ]
  [[ $output == *"~/.bashrc could not be replaced; it stays as it was"* ]]
  cmp "$OLD" "$HOME/.bashrc"
}

@test "every file it lists is in the skel, and each one's sums hold every version shipped, this one's too" {
  local files
  files=$(sed -n 's/^  "\([^ ]*\) [0-9a-f]\{64\}"$/\1/p' "$REPO_ROOT/src/cli/bin/nova-update-home" | sort -u)
  [ -n "$files" ]
  for file in $files; do
    [ -f "$REPO_ROOT/data/skel/$file" ]
    # A change to the skel's file adds its sum to the list.
    listed "$file" | grep -qx "$(sha256sum <"$REPO_ROOT/data/skel/$file" | cut -d' ' -f1)" ||
      { echo "data/skel/$file as it is now is not listed in nova-update-home"; false; }
  done
  # The one 2026-10-20 to 1.0.0-rc.14 shipped.
  listed .bashrc | grep -qx "$(sha256sum <"$OLD" | cut -d' ' -f1)"
}
