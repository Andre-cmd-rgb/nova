#!/usr/bin/env bats

load ../test_helper

setup() {
  setup_scratch
  export NOVA_BROWSER_THEME_SOURCE="$SCRATCH/greeter/chromium.theme"
  export NOVA_BROWSER_POLICY_DIRS="$SCRATCH/chrome $SCRATCH/chromium $SCRATCH/absent"
  mkdir -p "$SCRATCH/greeter" "$SCRATCH/chrome" "$SCRATCH/chromium"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/data/browser/nova-browser-theme"
}

teardown() { teardown_scratch; }

fails() { if "$@"; then return 1; fi; }

@test "theme_hex: three numbers from 0 to 255, nothing else" {
  [ "$(theme_hex 255,255,255)" = "#ffffff" ]
  [ "$(theme_hex 30,30,46)" = "#1e1e2e" ]
  [ "$(theme_hex 008,0,09)" = "#080009" ]
  for bad in 256,0,0 1,2 1,2,3,4 "1, 2, 3" -1,0,0 '#ffffff' '' '1,2,3;rm -rf /'; do
    fails theme_hex "$bad"
  done
}

@test "the policy follows the mirrored color, in every browser directory there is" {
  echo 30,30,46 >"$NOVA_BROWSER_THEME_SOURCE"
  main
  [ "$(cat "$SCRATCH/chrome/nova-theme.json")" = '{"BrowserThemeColor": "#1e1e2e"}' ]
  [ "$(cat "$SCRATCH/chromium/nova-theme.json")" = '{"BrowserThemeColor": "#1e1e2e"}' ]
  [ "$(stat -c %a "$SCRATCH/chrome/nova-theme.json")" = 644 ]
  [ ! -e "$SCRATCH/absent" ]
  [ "$(ls -A "$SCRATCH/chrome")" = nova-theme.json ]
}

@test "garbage, a symlink or no file at all leave the policy as it was" {
  echo 255,255,255 >"$NOVA_BROWSER_THEME_SOURCE"
  main
  echo 'not a color' >"$NOVA_BROWSER_THEME_SOURCE"
  run main
  [ "$status" -eq 1 ]
  rm "$NOVA_BROWSER_THEME_SOURCE"
  echo 0,0,0 >"$SCRATCH/elsewhere"
  ln -s "$SCRATCH/elsewhere" "$NOVA_BROWSER_THEME_SOURCE"
  main
  rm "$NOVA_BROWSER_THEME_SOURCE"
  main
  [ "$(cat "$SCRATCH/chrome/nova-theme.json")" = '{"BrowserThemeColor": "#ffffff"}' ]
}

@test "only the first line, and only so much of it, is read" {
  { echo 1,2,3; echo 4,5,6; } >"$NOVA_BROWSER_THEME_SOURCE"
  main
  [ "$(cat "$SCRATCH/chrome/nova-theme.json")" = '{"BrowserThemeColor": "#010203"}' ]
  printf '%0100d\n' 0 >"$NOVA_BROWSER_THEME_SOURCE"
  run main
  [ "$status" -eq 1 ]
}
