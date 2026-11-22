#!/usr/bin/env bats

# tools/site-palettes: each of the site's photos gets the palette Nova's own
# `nova-theme palette` gives it, from a stand-in here, and a write that fails
# leaves the palette there whole.

load ../test_helper

setup() {
  setup_scratch
  ROOT=$SCRATCH/root
  WALLS=$SCRATCH/walls
  mkdir -p "$ROOT/usr/lib/nova/bin" "$WALLS"
  # palette <photo> [light|dark]; none for broken.jpg.
  cat >"$ROOT/usr/lib/nova/bin/nova-theme" <<'STUB'
#!/bin/bash
[[ $1 == palette && ${2##*/} != broken.jpg ]] || exit 1
printf '# made by the stand-in\nmode = "%s"\nbackground = "#101010"\nforeground = "#f0f0f0"\n' "${3:-dark}"
STUB
  chmod +x "$ROOT/usr/lib/nova/bin/nova-theme"
  touch "$WALLS/aurora.jpg" "$WALLS/coast.jpg"
}

teardown() { teardown_scratch; }

palettes() { "$REPO_ROOT/tools/site-palettes" --root "$ROOT" --dir "$WALLS" "$@"; }

@test "each photo gets its palette, and the opening one (--default) its light palette too" {
  run palettes --default coast
  [ "$status" -eq 0 ]
  [[ $output == *"wrote palettes for 2 wallpapers"* ]]
  grep -qx 'mode = "dark"' "$WALLS/aurora.colors.toml"
  grep -qx 'mode = "dark"' "$WALLS/coast.colors.toml"
  grep -qx 'mode = "light"' "$WALLS/coast.light.colors.toml"
  [ ! -e "$WALLS/aurora.light.colors.toml" ]
  # Its comment is the tool's, not the stand-in's.
  fails grep -q 'stand-in' "$WALLS/aurora.colors.toml"
  [ -z "$(find "$WALLS" -name '*.colors.toml.*')" ]
}

@test "a write that fails, or a photo with no palette, leaves the palette there as it was" {
  write_file "$WALLS/aurora.colors.toml" 'mode = "dark"
background = "#000000"
'
  before=$(cat "$WALLS/aurora.colors.toml")
  # A grep that fails as the palette's lines are copied: the file was cut to
  # its two comment lines when it was written in place.
  mkdir -p "$SCRATCH/bin"
  printf '#!/bin/bash\n[[ $1 != -v ]] || exit 1\nexec /usr/bin/grep "$@"\n' >"$SCRATCH/bin/grep"
  chmod +x "$SCRATCH/bin/grep"
  PATH=$SCRATCH/bin:$PATH run palettes
  [ "$status" -ne 0 ]
  [ "$(cat "$WALLS/aurora.colors.toml")" = "$before" ]
  [ -z "$(find "$WALLS" -name '*.colors.toml.*')" ]
  # No palette for a photo: the run fails, and its old palette stays.
  rm "$SCRATCH/bin/grep"
  write_file "$WALLS/broken.colors.toml" 'old'
  touch "$WALLS/broken.jpg"
  run palettes
  [ "$status" -ne 0 ]
  [ "$(cat "$WALLS/broken.colors.toml")" = old ]
}
