#!/usr/bin/env bats

# nova-capture-text: a region picked as a screenshot's is, the still ended as
# soon as grim has it and before the text is read, the text put on the
# clipboard and said; nothing for a pick given up or no text. The picker,
# grim, tesseract, wl-copy and the notification are stubs that log.

load ../test_helper

setup() {
  setup_scratch
  export CALLS=$SCRATCH/calls
  mkdir -p "$SCRATCH/bin"
  echo '10,10 300x200' >"$SCRATCH/region"
  echo 'Hello there' >"$SCRATCH/text"
  stub nova-capture-region 'if [[ $1 == --thaw ]]; then echo "thaw $2" >>"$CALLS"; exit; fi
echo "region $*" >>"$CALLS"; echo shell:frozen; cat "$SCRATCH/region"'
  stub grim 'echo "grim $*" >>"$CALLS"; echo PNG >"$3"'
  stub tesseract 'echo "tesseract $(cat "$1")" >>"$CALLS"; cat "$SCRATCH/text"'
  stub wl-copy 'echo "wl-copy $(cat)" >>"$CALLS"'
  stub nova-notification-send 'echo "notify $*" >>"$CALLS"'
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name body
  printf '#!/bin/bash\n%s\n' "$2" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

text() { "$REPO_ROOT/src/cli/bin/nova-capture-text" "$@"; }

@test "the text of a region drawn on the still, on the clipboard, the still gone before it is read" {
  run text
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "region region --keep-freeze
grim -g 10,10 300x200 $(sed -n 's/^grim -g 10,10 300x200 //p' "$CALLS")
thaw shell:frozen
tesseract PNG
wl-copy Hello there
notify -g 󰴑 Copied text from selection to clipboard" ]
  # The picture goes with it.
  [ ! -e "$(sed -n 's/^grim -g 10,10 300x200 //p' "$CALLS")" ]
}

@test "a pick given up reads nothing, and no text copies nothing" {
  : >"$SCRATCH/region"
  run text
  [ "$status" -eq 0 ]
  fails grep -q -e '^grim' -e '^tesseract' "$CALLS"
  echo '10,10 300x200' >"$SCRATCH/region"
  : >"$SCRATCH/text"
  : >"$CALLS"
  run text
  [ "$status" -eq 1 ]
  fails grep -q -e '^wl-copy' -e '^notify' "$CALLS"
  grep -qx 'thaw shell:frozen' "$CALLS"
}
