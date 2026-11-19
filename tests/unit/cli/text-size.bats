#!/usr/bin/env bats

# nova-display-text-size: the one text size, written to the shell's
# shell.toml (its [font] base-size, the rest of the file left as it was),
# GTK's text-scaling-factor and foot's font size. gsettings, nova-session-pgrep and the
# notification are stubs; GTK's settings are $SCRATCH/gsettings.

load ../test_helper

setup() {
  setup_scratch
  export HOME=$SCRATCH/home CALLS=$SCRATCH/calls XDG_RUNTIME_DIR=$SCRATCH/run
  mkdir -p "$SCRATCH/bin" "$HOME/.config/nova" "$HOME/.config/foot" "$XDG_RUNTIME_DIR"
  printf '[main]\nfont=monospace:size=9\npad=8x8\n' >"$HOME/.config/foot/foot.ini"
  echo "font-name 'Adwaita Sans 11'" >"$SCRATCH/gsettings"
  cat >"$SCRATCH/bin/gsettings" <<'STUB'
#!/bin/bash
echo "gsettings $*" >>"$CALLS"
case $1 in
  get) value=$(sed -n "s/^$3 //p" "$SCRATCH/gsettings"); [[ -n $value ]] && echo "$value" || echo 1.0 ;;
esac
STUB
  printf '#!/bin/bash\n[[ -e %s/foot-up ]]\n' "$SCRATCH" >"$SCRATCH/bin/nova-session-pgrep"
  printf '#!/bin/bash\necho "notify $*" >>"%s"\necho 42\n' "$CALLS" >"$SCRATCH/bin/nova-notification-send"
  chmod +x "$SCRATCH/bin"/*
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

size() { "$REPO_ROOT/src/cli/bin/nova-display-text-size" "$@"; }
toml() { cat "$HOME/.config/nova/shell.toml"; }

@test "a size is the shell's base size, GTK's factor on a whole point, and foot's points" {
  size 16
  [ "$(toml)" = $'[font]\nbase-size = 16' ]
  grep -qx 'gsettings set org.gnome.desktop.interface text-scaling-factor 1.3636' "$CALLS"
  grep -qx 'font=monospace:size=12' "$HOME/.config/foot/foot.ini"
  grep -qx 'pad=8x8' "$HOME/.config/foot/foot.ini"
  size 13
  grep -qx 'font=monospace:size=10' "$HOME/.config/foot/foot.ini"
}

@test "the base size goes where [font] has it, or at the end of [font], and nothing else moves" {
  printf '# mine\n[bar]\nheight = 30\n\n[font]\nfamily = "Inter"\nbase-size = 12 # was\n\n[osd]\nwide = true\n' >"$HOME/.config/nova/shell.toml"
  size 14
  [ "$(toml)" = $'# mine\n[bar]\nheight = 30\n\n[font]\nfamily = "Inter"\nbase-size = 14\n\n[osd]\nwide = true' ]
  printf '[font]\nfamily = "Inter"\n[osd]\nwide = true' >"$HOME/.config/nova/shell.toml"
  size 15
  [ "$(toml)" = $'[font]\nfamily = "Inter"\nbase-size = 15\n[osd]\nwide = true' ]
  printf '[bar]\nheight = 30\n' >"$HOME/.config/nova/shell.toml"
  size 10
  [ "$(toml)" = $'[bar]\nheight = 30\n\n[font]\nbase-size = 10' ]
}

@test "with no size it says the size and GTK's factor" {
  printf '[font]\nbase-size = 14\n' >"$HOME/.config/nova/shell.toml"
  run size
  [ "$output" = $'text size: 14 px\ngtk text-scaling-factor: 1.0' ]
  rm "$HOME/.config/nova/shell.toml"
  run size
  [ "$output" = $'text size:  px\ngtk text-scaling-factor: 1.0' ]
}

@test "reset takes the base size out and GTK and foot back to theirs" {
  printf '[font]\nbase-size = 14\nfamily = "Inter"\n' >"$HOME/.config/nova/shell.toml"
  sed -i 's/size=9/size=11/' "$HOME/.config/foot/foot.ini"
  size reset
  [ "$(toml)" = $'[font]\nfamily = "Inter"' ]
  grep -qx 'gsettings reset org.gnome.desktop.interface text-scaling-factor' "$CALLS"
  grep -qx 'font=monospace:size=9' "$HOME/.config/foot/foot.ini"
}

@test "with foot open, one notification says so, replaced on the next change" {
  touch "$SCRATCH/foot-up"
  size 14
  size 15
  [ "$(grep '^notify' "$CALLS")" = 'notify New terminal windows use the new text size -p
notify New terminal windows use the new text size -r 42 -p' ]
}

@test "a size out of range, or anything else, is refused" {
  for wrong in 8 21 big 1.5; do
    run size "$wrong"
    [ "$status" -eq 2 ] || { echo "took $wrong"; return 1; }
  done
  [ ! -e "$HOME/.config/nova/shell.toml" ]
}
