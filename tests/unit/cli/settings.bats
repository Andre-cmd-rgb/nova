#!/usr/bin/env bats

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home"
  export NOVA_PATH="$SCRATCH/share"
  export NOVA_POWER_SUPPLY="$SCRATCH/power_supply"
  export NOVA_DMI_PATH="$SCRATCH/dmi"
  mkdir -p "$HOME" "$NOVA_PATH/default" "$NOVA_PATH/shell/plugins" "$NOVA_POWER_SUPPLY" "$NOVA_DMI_PATH" "$SCRATCH/bin" "$SCRATCH/sys"
  cp "$REPO_ROOT/data/defaults/shell.json" "$NOVA_PATH/default/"
  # Only the tools the commands need, so whatever this machine has installed
  # (browsers, editors, a real nova) cannot leak into the results.
  local tool
  for tool in bash cat jq sed awk grep df find xargs uname sort head tail tr mkdir mv mktemp dirname rm env; do
    ln -s "$(command -v "$tool")" "$SCRATCH/sys/$tool"
  done
  ln -s "$REPO_ROOT/src/cli/bin/nova-settings" "$SCRATCH/bin/nova-settings"
  ln -s "$REPO_ROOT/src/cli/bin/nova-idle-lock" "$SCRATCH/bin/nova-idle-lock"
  ln -s "$REPO_ROOT/src/cli/bin/nova-idle-screensaver" "$SCRATCH/bin/nova-idle-screensaver"
  ln -s "$REPO_ROOT/src/cli/bin/nova-shell-config" "$SCRATCH/bin/nova-shell-config"
  SAFE_PATH="$SCRATCH/bin:$SCRATCH/sys"
}

nova-settings() { PATH=$SAFE_PATH "$SCRATCH/bin/nova-settings" "$@"; }
nova-idle-lock() { PATH=$SAFE_PATH "$SCRATCH/bin/nova-idle-lock" "$@"; }
nova-idle-screensaver() { PATH=$SAFE_PATH "$SCRATCH/bin/nova-idle-screensaver" "$@"; }

teardown() { teardown_scratch; }

stub() { # name [body]
  printf '#!/bin/bash\n%s\n' "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

state() { nova-settings state | jq -c "$1"; }

@test "state: everything missing still makes a whole answer" {
  run nova-settings state
  [ "$status" -eq 0 ]
  [ "$(jq -c .appearance <<<"$output")" = '{"theme":"","themes":[],"background":"","font":"","fonts":[],"textSize":12}' ]
  [ "$(jq -c .battery <<<"$output")" = '{"present":false}' ]
  [ "$(jq -c .screenTime <<<"$output")" = false ]
  [ "$(jq -c .lock <<<"$output")" = '{"seconds":300,"screensaver":180,"fingerprint":false}' ]
  [ "$(jq -c '[.apps.browsers, .apps.editors, .apps.terminals]' <<<"$output")" = '[[],[],[]]' ]
  [ "$(jq -r .bar.position <<<"$output")" = top ]
  [ "$(jq -c '.bar.shown | index("nova.power") != null' <<<"$output")" = true ]
  [ "$(jq -c .updates <<<"$output")" = '{"candidates":false}' ]
}

@test "state: whether this system tests release candidates" {
  stub nova-update '[[ $* == --candidates ]] && echo on'
  [ "$(state .updates.candidates)" = true ]
}

@test "state: themes with their colors, and the current one" {
  stub nova-theme 'case "$*" in
    "list --colors") printf "white\t#ffffff\t#000000\t#6e6e6e\nnord\t#2e3440\t#d8dee9\t#88c0d0\n" ;;
    current) echo white ;;
    *) exit 1 ;;
  esac'
  [ "$(state '.appearance.theme')" = '"white"' ]
  [ "$(state '.appearance.themes[1]')" = '{"name":"nord","background":"#2e3440","foreground":"#d8dee9","accent":"#88c0d0"}' ]
}

@test "state: the battery's health, power modes, charge limit, GPU mode and undervolt" {
  mkdir -p "$NOVA_POWER_SUPPLY/BAT0"
  echo Battery >"$NOVA_POWER_SUPPLY/BAT0/type"
  echo 81000000 >"$NOVA_POWER_SUPPLY/BAT0/energy_full"
  echo 100000000 >"$NOVA_POWER_SUPPLY/BAT0/energy_full_design"
  echo 586 >"$NOVA_POWER_SUPPLY/BAT0/cycle_count"
  stub nova-power-profile 'printf "power-saver\t0\nbalanced\t1\n"'
  stub nova-battery-limit 'echo "{\"kind\":\"threshold\",\"limit\":80,\"on\":true}"'
  stub nova-power-gpu '[[ $* == mode ]] && echo off'
  stub nova-power-undervolt '[[ $* == "status --json" ]] && echo "{\"offset\":-70,\"state\":\"applied\",\"reason\":null}"'
  [ "$(state .battery)" = '{"present":true,"health":81,"cycles":586,"profiles":[{"name":"power-saver","active":false},{"name":"balanced","active":true}],"limit":{"kind":"threshold","limit":80,"on":true},"gpu":"off","undervolt":{"offset":-70,"state":"applied","reason":null}}' ]
}

@test "state: no undervolt where its tool cannot answer" {
  mkdir -p "$NOVA_POWER_SUPPLY/BAT0"
  echo Battery >"$NOVA_POWER_SUPPLY/BAT0/type"
  stub nova-power-undervolt 'exit 1'
  [ "$(state .battery.undervolt)" = null ]
}

@test "state: no GPU mode where the GPU cannot be switched" {
  mkdir -p "$NOVA_POWER_SUPPLY/BAT0"
  echo Battery >"$NOVA_POWER_SUPPLY/BAT0/type"
  [ "$(state .battery.gpu)" = '""' ]
  stub nova-power-gpu 'echo "nova power gpu: this computer has no switchable discrete GPU" >&2; exit 1'
  [ "$(state .battery.gpu)" = '""' ]
}

@test "state: a charge limit that prints garbage reads as none" {
  mkdir -p "$NOVA_POWER_SUPPLY/BAT0"
  echo Battery >"$NOVA_POWER_SUPPLY/BAT0/type"
  stub nova-battery-limit 'echo "not json"'
  [ "$(state .battery.limit.kind)" = '"none"' ]
  [ "$(state .battery.health)" = null ]
}

@test "state: the user's shell.json, and Nova's default when theirs is broken" {
  mkdir -p "$HOME/.config/nova"
  echo '{"version":1,"idle":{"lock":600},"bar":{"position":"bottom","layout":{"left":[{"id":"nova.menu"}]}}}' >"$HOME/.config/nova/shell.json"
  [ "$(state '[.lock.seconds, .bar.position, .bar.shown]')" = '[600,"bottom",["nova.menu"]]' ]
  echo '{broken' >"$HOME/.config/nova/shell.json"
  [ "$(state '[.lock.seconds, .bar.position]')" = '[300,"top"]' ]
}

@test "state: bar widgets from their manifests, without the spacer and Screen Time" {
  mkdir -p "$NOVA_PATH/shell/plugins/bar/widgets" "$NOVA_PATH/shell/plugins/screentime" "$NOVA_PATH/shell/plugins/settings"
  cp "$REPO_ROOT"/src/shell/plugins/bar/widgets/{Tray,Spacer}.manifest.json "$NOVA_PATH/shell/plugins/bar/widgets/"
  cp "$REPO_ROOT/src/shell/plugins/screentime/manifest.json" "$NOVA_PATH/shell/plugins/screentime/"
  cp "$REPO_ROOT/src/shell/plugins/settings/manifest.json" "$NOVA_PATH/shell/plugins/settings/"
  [ "$(state '[.bar.widgets[].id]')" = '["nova.tray"]' ]
}

@test "state: default apps list only what is installed, and screen time and fingerprint follow their commands" {
  stub foot
  stub google-chrome-stable
  stub fprintd-enroll
  stub busctl 'echo "ao 1 \"/net/reactivated/Fprint/Device/0\""'
  stub nova-screentime '[[ $1 == enabled ]]'
  stub nova-default-browser 'echo chrome'
  [ "$(state '[.apps.browsers, .apps.terminals, .apps.browser, .screenTime, .lock.fingerprint]')" = '[["chrome"],["foot"],"chrome",true,true]' ]
}

@test "state: no fingerprint setup without a reader, or without fprintd" {
  stub fprintd-enroll
  stub busctl 'echo "ao 0"'
  [ "$(state .lock.fingerprint)" = false ]
  stub busctl 'exit 1'
  [ "$(state .lock.fingerprint)" = false ]
  rm "$SCRATCH/bin/fprintd-enroll"
  stub busctl 'echo "ao 1 \"/net/reactivated/Fprint/Device/0\""'
  [ "$(state .lock.fingerprint)" = false ]
}

@test "state: this computer, named the way its maker names it" {
  echo "ThinkPad P1 Gen 4i" >"$NOVA_DMI_PATH/product_version"
  echo 20Y4S0ER00 >"$NOVA_DMI_PATH/product_name"
  echo LENOVO >"$NOVA_DMI_PATH/sys_vendor"
  [ "$(state '[.about.model, .about.vendor]')" = '["ThinkPad P1 Gen 4i","LENOVO"]' ]
  echo "None" >"$NOVA_DMI_PATH/product_version"
  echo "Legion 5 15ACH6H" >"$NOVA_DMI_PATH/product_name"
  [ "$(state .about.model)" = '"Legion 5 15ACH6H"' ]
}

@test "open: a known page goes to the shell, an unknown one is refused" {
  stub nova-shell 'echo "$*" >"$HOME/summoned"'
  nova-settings battery
  [ "$(<"$HOME/summoned")" = 'shell summon nova.settings {"page":"battery"}' ]
  nova-settings
  [ "$(<"$HOME/summoned")" = 'shell summon nova.settings {"page":""}' ]
  run nova-settings frobnicate
  [ "$status" -eq 2 ]
}

@test "idle lock: reads, sets in minutes, never, and refuses nonsense" {
  stub nova-shell
  [ "$(nova-idle-lock)" = "5 min" ]
  nova-idle-lock 10
  [ "$(jq .idle.lock "$HOME/.config/nova/shell.json")" = 600 ]
  [ "$(nova-idle-lock)" = "10 min" ]
  nova-idle-lock never
  [ "$(nova-idle-lock)" = never ]
  for bad in 0 721 abc -5 "1 2"; do
    run nova-idle-lock "$bad"
    [ "$status" -eq 1 ]
  done
  [ "$(jq -c .bar.layout.right "$HOME/.config/nova/shell.json" | jq length)" -gt 0 ]
}

@test "idle screensaver: reads, sets in minutes, never, and refuses nonsense" {
  stub nova-shell
  [ "$(nova-idle-screensaver)" = "3 min" ]
  nova-idle-screensaver 5
  [ "$(jq -c .idle "$HOME/.config/nova/shell.json")" = '{"lock":300,"screensaver":300}' ]
  [ "$(nova-idle-screensaver)" = "5 min" ]
  [ "$(state .lock.screensaver)" = 300 ]
  nova-idle-screensaver never
  [ "$(nova-idle-screensaver)" = never ]
  for bad in 0 721 abc -5 "1 2"; do
    run nova-idle-screensaver "$bad"
    [ "$status" -eq 1 ]
  done
}
