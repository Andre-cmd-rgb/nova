#!/usr/bin/env bats

# services/hidden-entries.sh: the desktop entries the menu leaves out, and
# the ones that ask to run on the discrete GPU, from one read of them.

load ../test_helper

setup() {
  setup_scratch
  export HOME=$SCRATCH/home XDG_DATA_DIRS=$SCRATCH/system:$SCRATCH/flatpak
  mkdir -p "$HOME/.local/share/applications" "$SCRATCH/system/applications" \
    "$SCRATCH/flatpak/applications" "$SCRATCH/app"
  SCAN=$REPO_ROOT/src/shell/services/hidden-entries.sh
}

teardown() { teardown_scratch; }

# The IDs of one list (hidden or discrete), sorted, on a line.
list() { # name output
  sed -n "s/^$1 //p" <<<"$2" | sort | tr '\n' ' '
}

entry() { # dir id lines...
  local dir=$1 id=$2
  shift 2
  printf '[Desktop Entry]\nType=Application\nName=%s\n' "$id" >"$dir/applications/$id.desktop"
  printf '%s\n' "$@" >>"$dir/applications/$id.desktop"
}

@test "hidden: NoDisplay, Hidden, and OnlyShowIn or NotShowIn for this desktop" {
  entry "$SCRATCH/system" shown
  entry "$SCRATCH/system" nodisplay NoDisplay=true
  entry "$SCRATCH/system" gone Hidden=true
  entry "$SCRATCH/system" elsewhere 'OnlyShowIn=GNOME;KDE;'
  entry "$SCRATCH/system" here 'OnlyShowIn=GNOME;Hyprland;'
  entry "$SCRATCH/system" not-here 'NotShowIn=Hyprland;'
  run bash "$SCAN" Hyprland
  [ "$status" -eq 0 ]
  [ "$(list hidden "$output")" = "elsewhere gone nodisplay not-here " ]
  [ "$(list discrete "$output")" = "" ]
}

@test "the first directory to have an ID wins, and Flatpak's linked entries count" {
  entry "$SCRATCH/system" editor NoDisplay=true
  entry "$HOME/.local/share" editor
  printf '[Desktop Entry]\nName=Game\nNoDisplay=true\nPrefersNonDefaultGPU=true\n' >"$SCRATCH/app/org.game.Game.desktop"
  ln -s "$SCRATCH/app/org.game.Game.desktop" "$SCRATCH/flatpak/applications/org.game.Game.desktop"
  ln -s "$SCRATCH/app/missing.desktop" "$SCRATCH/flatpak/applications/broken.desktop"
  run bash "$SCAN" Hyprland
  [ "$output" = "hidden org.game.Game"$'\n'"discrete org.game.Game" ]
}

@test "discrete: PrefersNonDefaultGPU or KDE's key, true, in the entry's own section" {
  entry "$SCRATCH/system" steam PrefersNonDefaultGPU=true
  entry "$SCRATCH/system" kde-game X-KDE-RunOnDiscreteGpu=true
  entry "$SCRATCH/system" plain
  entry "$SCRATCH/system" says-no PrefersNonDefaultGPU=false
  entry "$SCRATCH/system" in-action '[Desktop Action big]' PrefersNonDefaultGPU=true
  run bash "$SCAN" Hyprland
  [ "$status" -eq 0 ]
  [ "$(list discrete "$output")" = "kde-game steam " ]
  [ "$(list hidden "$output")" = "" ]
}
