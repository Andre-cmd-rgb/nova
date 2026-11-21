#!/usr/bin/env bats

# theme/cursor/build: Nova's cursor theme, made once for the file, then its
# check run on it and on copies broken one way each; and a theme made from a
# copy of the sources with one cursor, broken there.

load ../test_helper

needs_tools() {
  local tool
  for tool in rsvg-convert xcursorgen hyprcursor-util bsdtar; do
    command -v "$tool" >/dev/null && continue
    # CI asks for every test (NOVA_STRICT_TESTS): there a skip would pass
    # the theme's checks unseen.
    [[ -z ${NOVA_STRICT_TESTS:-} ]] || { echo "$tool is missing" >&2; return 1; }
    skip "needs $tool (CI has it)"
  done
}

setup_file() {
  command -v rsvg-convert >/dev/null && command -v xcursorgen >/dev/null &&
    command -v hyprcursor-util >/dev/null || return 0
  "$REPO_ROOT/theme/cursor/build" "$BATS_FILE_TMPDIR/Nova" >"$BATS_FILE_TMPDIR/build.log" 2>&1 ||
    echo $? >"$BATS_FILE_TMPDIR/failed"
}

setup() {
  needs_tools
  setup_scratch
  THEME=$BATS_FILE_TMPDIR/Nova
}

teardown() { teardown_scratch; }

# A copy of the built theme, to break.
copy() {
  cp -a "$THEME" "$SCRATCH/Nova"
  echo "$SCRATCH/Nova"
}

check() { "$REPO_ROOT/theme/cursor/build" --check "$1"; }

# A copy of theme/cursor with only the designs given and their names.
sources() { # design...
  local design
  mkdir -p "$SCRATCH/cursor/src"
  cp -r "$REPO_ROOT/theme/cursor/build" "$REPO_ROOT/theme/cursor/style" "$REPO_ROOT/theme/cursor/parts" "$SCRATCH/cursor/"
  : >"$SCRATCH/cursor/names"
  for design in "$@"; do
    cp "$REPO_ROOT/theme/cursor/src/$design.svg" "$SCRATCH/cursor/src/"
    grep "^$design\b" "$REPO_ROOT/theme/cursor/names" >>"$SCRATCH/cursor/names"
  done
}

@test "the theme is made, in both forms, and passes its check" {
  [ ! -e "$BATS_FILE_TMPDIR/failed" ] || { cat "$BATS_FILE_TMPDIR/build.log"; false; }
  run check "$THEME"
  [ "$status" -eq 0 ]
  grep -qx 'Name=Nova' "$THEME/index.theme"
  grep -qx 'name = Nova' "$THEME/manifest.hl"
  # Names from each family: CSS, the cursor font, Qt, a hash Qt and Mozilla ask for.
  [ "$(readlink "$THEME/cursors/left_ptr")" = default ]
  [ "$(readlink "$THEME/cursors/hand2")" = pointer ]
  [ "$(readlink "$THEME/cursors/size_fdiag")" = nwse-resize ]
  [ "$(readlink "$THEME/cursors/e29285e634086352946a0e7090d73106")" = pointer ]
  [ -f "$THEME/cursors/default" ] && [ ! -L "$THEME/cursors/default" ]
  bsdtar -xOf "$THEME/hyprcursors/pointer.hlc" meta.hl | grep -qx 'define_override = hand2'
  bsdtar -tf "$THEME/hyprcursors/wait.hlc" | grep -qx 'wait-24.svg'
}

@test "every name a toolkit asks for, Adwaita's among them, is in the theme" {
  local name
  for name in $(ls /usr/share/icons/Adwaita/cursors 2>/dev/null) default pointer text wait progress \
    not-allowed grab grabbing all-resize dnd-ask zoom-in col-resize; do
    [ -e "$THEME/cursors/$name" ] || { echo "no $name"; false; }
  done
}

@test "the same sources make the same bytes" {
  "$REPO_ROOT/theme/cursor/build" "$SCRATCH/again" >/dev/null
  diff <(cd "$THEME" && find . -type f -exec sha256sum {} + | sort -k2) \
    <(cd "$SCRATCH/again" && find . -type f -exec sha256sum {} + | sort -k2)
}

@test "every file is readable by all" {
  [ -z "$(find "$THEME" ! -type l ! -perm -444)" ]
}

@test "a name XCursor lacks fails the check" {
  local theme
  theme=$(copy)
  rm "$theme/cursors/hand2"
  run check "$theme"
  [ "$status" -ne 0 ]
  [[ $output == *"XCursor has no hand2"* ]]
}

@test "a link to nothing, or out of the theme, fails the check" {
  local theme
  theme=$(copy)
  ln -s gone "$theme/cursors/broken"
  ln -s /usr/share/icons/Adwaita/cursors/default "$theme/cursors/borrowed"
  run check "$theme"
  [ "$status" -ne 0 ]
  [[ $output == *"broken links to gone"* ]]
  [[ $output == *"borrowed links to /usr/share/icons/Adwaita/cursors/default"* ]]
}

@test "a name Hyprcursor lacks fails the check" {
  local theme
  theme=$(copy)
  rm "$theme/hyprcursors/pointer.hlc"
  run check "$theme"
  [ "$status" -ne 0 ]
  [[ $output == *"Hyprcursor has no pointer"* ]]
  [[ $output == *"Hyprcursor has no hand2"* ]]
}

@test "a theme that inherits another fails the check" {
  local theme
  theme=$(copy)
  echo 'Inherits=Adwaita' >>"$theme/index.theme"
  run check "$theme"
  [ "$status" -ne 0 ]
  [[ $output == *"inherits another theme"* ]]
}

@test "the spinner has 24 frames at every size, each with its delay" {
  source <(sed -n '/^images() {/,/^}/p' "$REPO_ROOT/theme/cursor/build")
  run images "$THEME/cursors/wait"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq $((24 * 7)) ]
  [ "$(printf '%s\n' "${lines[@]}" | awk '{ print $1 }' | sort -n | uniq -c | awk '{ print $1 }' | sort -u)" = 24 ]
  [ "$(printf '%s\n' "${lines[@]}" | awk '{ print $6 }' | sort -u)" = 40 ]
}

@test "the pointer clicks at its tip at every size" {
  source <(sed -n '/^images() {/,/^}/p' "$REPO_ROOT/theme/cursor/build")
  run images "$THEME/cursors/default"
  [ "$status" -eq 0 ]
  # The tip is at 4,2.7 of 24 units: a sixth of the way across, a ninth down.
  printf '%s\n' "${lines[@]}" | awk '{ s = $1
    if ($4 != int(4 * s / 24 + 0.5) || $5 != int(2.7 * s / 24 + 0.5) || $7 < 96) { print; bad = 1 } }
    END { exit bad }'
}

@test "a hotspot off its drawing fails the build" {
  sources default
  sed -i 's/<!-- hotspot [^>]*-->/<!-- hotspot 20 21 -->/' "$SCRATCH/cursor/src/default.svg"
  run "$SCRATCH/cursor/build" "$SCRATCH/theme"
  [ "$status" -ne 0 ]
  [[ $output == *"default: its hotspot 20,21 is off the drawing at 24px"* ]]
}

@test "a ring's free hotspot may be off its drawing" {
  sources wait
  run "$SCRATCH/cursor/build" "$SCRATCH/theme"
  [ "$status" -eq 0 ]
  [ -e "$SCRATCH/theme/cursors/watch" ]
}

@test "a source element without a known class fails the build" {
  sources default
  sed -i 's|<!-- part dart -->|<path class="bold" d="M0 0H4"/>|' "$SCRATCH/cursor/src/default.svg"
  run "$SCRATCH/cursor/build" --svg "$SCRATCH/svg"
  [ "$status" -ne 0 ]
  [[ $output == *"an unknown class: bold"* ]]
}
