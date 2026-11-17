#!/usr/bin/env bats

load ../test_helper

setup() {
  setup_scratch
  export HOME="$SCRATCH/home"
  export NOVA_PATH="$SCRATCH/share"
  export NOVA_POWER_SUPPLY="$SCRATCH/power_supply"
  export NOVA_DMI_PATH="$SCRATCH/dmi"
  export NOVA_RFKILL_PATH="$SCRATCH/rfkill"
  export NOVA_USB_PATH="$SCRATCH/usb" XDG_RUNTIME_DIR="$SCRATCH/run"
  mkdir -p "$NOVA_USB_PATH" "$XDG_RUNTIME_DIR"
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
  ln -s "$REPO_ROOT/data/hardware/bin/nova-hw-model" "$SCRATCH/bin/nova-hw-model"
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
  [ "$(jq -c .appearance <<<"$output")" = '{"theme":"","themes":[],"background":"","backgrounds":0,"font":"","fonts":[],"textSize":12,"adaptive":""}' ]
  [ "$(jq -c .battery <<<"$output")" = '{"present":false}' ]
  [ "$(jq -c .screenTime <<<"$output")" = false ]
  [ "$(jq -c .lock <<<"$output")" = '{"seconds":300,"screensaver":180,"fingerprint":false}' ]
  [ "$(jq -c '[.apps.browsers, .apps.editors, .apps.terminals]' <<<"$output")" = '[[],[],[]]' ]
  [ "$(jq -r .bar.position <<<"$output")" = top ]
  [ "$(jq -c '.bar.shown | index("nova.power") != null' <<<"$output")" = true ]
  [ "$(jq -c .updates <<<"$output")" = '{"candidates":false,"firmware":false}' ]
  [ "$(jq -c .displays <<<"$output")" = '{"displays":[],"pending":null}' ]
  [ "$(jq -c .bluetooth <<<"$output")" = null ]
  [ "$(jq -c .airdrop <<<"$output")" = '{"available":false,"bell":false}' ]
  [ "$(jq -c .iphone <<<"$output")" = '{"on":false,"active":false}' ]
}

@test "state: iPhone notifications as systemd has them for this user: switched on, and running" {
  stub systemctl '[[ $* == "--user is-enabled --quiet nova-iphone-notifications.service" || $* == "--user is-active --quiet nova-iphone-notifications.service" ]]'
  [ "$(state .iphone)" = '{"on":true,"active":true}' ]
  # On, but stopped (crashed, or failing to start).
  stub systemctl '[[ $* == "--user is-enabled --quiet nova-iphone-notifications.service" ]]'
  [ "$(state .iphone)" = '{"on":true,"active":false}' ]
  stub systemctl 'exit 1'
  [ "$(state .iphone)" = '{"on":false,"active":false}' ]
}

@test "state: AirDrop where the Wi-Fi card can, and its doorbell as systemd has it for this user" {
  stub nova-airdrop '[[ $* == available ]]'
  stub systemctl "[[ \$* == \"is-enabled --quiet nova-airdrop-bell@$UID.service\" ]]"
  [ "$(state .airdrop)" = '{"available":true,"bell":true}' ]
  stub systemctl 'exit 1'
  [ "$(state .airdrop)" = '{"available":true,"bell":false}' ]
}

@test "state: the displays as nova monitor lists them" {
  stub nova-monitor '[[ $* == "list --json" ]] && echo "{\"displays\":[{\"name\":\"eDP-1\"}],\"pending\":{\"until\":99}}"'
  [ "$(state .displays)" = '{"displays":[{"name":"eDP-1"}],"pending":{"until":99}}' ]
}

@test "state: the keyboard and the pointer as nova input has them, or nothing where it cannot say" {
  [ "$(state .input)" = '{}' ]
  stub nova-input '[[ $* == "--json" ]] && echo "{\"layouts\":[\"us\",\"de\"],\"touchpad\":true}"'
  [ "$(state .input)" = '{"layouts":["us","de"],"touchpad":true}' ]
}

@test "state: whether this system tests release candidates" {
  stub nova-update '[[ $* == --candidates ]] && echo on'
  [ "$(state .updates.candidates)" = true ]
}

@test "state: themes with their colors, and the current one" {
  stub nova-theme 'case "$*" in
    "list --colors") printf "white\t#ffffff\t#000000\t#6e6e6e\nnord\t#2e3440\t#d8dee9\t#88c0d0\n" ;;
    current) echo white ;;
    "bg list") printf "/s/current/theme/backgrounds/nova.svg\n/h/.config/nova/backgrounds/lake.jpg\n" ;;
    *) exit 1 ;;
  esac'
  [ "$(state '.appearance.theme')" = '"white"' ]
  [ "$(state '.appearance.themes[1]')" = '{"name":"nord","background":"#2e3440","foreground":"#d8dee9","accent":"#88c0d0"}' ]
  # Not an adaptive theme: nothing to choose between.
  [ "$(state '.appearance.adaptive')" = '""' ]
  # The wordmark and a photo: one other to change to (the welcome offers it).
  [ "$(state '.appearance.backgrounds')" = 2 ]
}

@test "state: whether an adaptive theme is dark, light or as its background is" {
  stub nova-theme 'case "$*" in
    current) echo adaptive ;;
    adaptive) echo dark ;;
    *) exit 1 ;;
  esac'
  [ "$(state '.appearance.adaptive')" = '"dark"' ]
}

@test "state: the battery's health, charge limit, lid and power button" {
  mkdir -p "$NOVA_POWER_SUPPLY/BAT0"
  echo Battery >"$NOVA_POWER_SUPPLY/BAT0/type"
  echo 81000000 >"$NOVA_POWER_SUPPLY/BAT0/energy_full"
  echo 100000000 >"$NOVA_POWER_SUPPLY/BAT0/energy_full_design"
  echo 586 >"$NOVA_POWER_SUPPLY/BAT0/cycle_count"
  stub nova-battery-limit 'echo "{\"kind\":\"threshold\",\"limit\":80,\"on\":true}"'
  stub nova-power-lid 'echo lock'
  stub nova-power-button 'echo sleep'
  stub nova-power-hibernate 'echo 4h'
  [ "$(state .battery)" = '{"present":true,"health":81,"cycles":586,"limit":{"kind":"threshold","limit":80,"on":true},"lid":"lock","powerButton":"sleep","hibernate":"4h"}' ]
}

@test "state: no hibernate choice where the computer cannot hibernate" {
  mkdir -p "$NOVA_POWER_SUPPLY/BAT0"
  echo Battery >"$NOVA_POWER_SUPPLY/BAT0/type"
  stub nova-power-hibernate 'echo "nova power hibernate: this computer cannot hibernate" >&2; exit 1'
  [ "$(state .battery.hibernate)" = '""' ]
}

@test "state: the power modes, GPU mode and undervolt, on Performance, battery or not" {
  stub nova-power-profile 'printf "power-saver\t0\nbalanced\t1\n"'
  stub nova-power-gpu '[[ $* == mode ]] && echo off'
  stub nova-power-undervolt '[[ $* == "status --json" ]] && echo "{\"core\":-80,\"cache\":-70,\"state\":\"applied\",\"reason\":null,\"intel\":true}"'
  [ "$(state .performance)" = '{"profiles":[{"name":"power-saver","active":false},{"name":"balanced","active":true}],"gpu":"off","undervolt":{"core":-80,"cache":-70,"state":"applied","reason":null,"intel":true}}' ]
}

@test "state: no undervolt where its tool cannot answer" {
  stub nova-power-undervolt 'exit 1'
  [ "$(state .performance.undervolt)" = null ]
}

@test "state: no GPU mode where the GPU cannot be switched" {
  [ "$(state .performance.gpu)" = '""' ]
  stub nova-power-gpu 'echo "nova power gpu: this computer has no switchable discrete GPU" >&2; exit 1'
  [ "$(state .performance.gpu)" = '""' ]
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

@test "state: the night light's schedule and warmth as shell.json has them, or nothing set" {
  [ "$(state .nightlight)" = '{}' ]
  mkdir -p "$HOME/.config/nova"
  echo '{"version":1,"nightlight":{"schedule":"hours","from":"21:00","to":"06:30","temperature":3400}}' >"$HOME/.config/nova/shell.json"
  [ "$(state .nightlight)" = '{"schedule":"hours","from":"21:00","to":"06:30","temperature":3400}' ]
  echo '{"version":1,"nightlight":"sunset"}' >"$HOME/.config/nova/shell.json"
  [ "$(state .nightlight)" = '{}' ]
}

@test "state: Do Not Disturb's hours as shell.json has them, or nothing set" {
  [ "$(state .doNotDisturb)" = '{}' ]
  mkdir -p "$HOME/.config/nova"
  echo '{"version":1,"doNotDisturb":{"schedule":"hours","from":"22:00","to":"07:00"}}' >"$HOME/.config/nova/shell.json"
  [ "$(state .doNotDisturb)" = '{"schedule":"hours","from":"22:00","to":"07:00"}' ]
}

@test "state and idle: the settings the shell has, Nova's where the user's lack a version, Nova's bar where they lack one" {
  mkdir -p "$HOME/.config/nova"
  echo '{"idle":{"lock":60},"bar":{"position":"bottom"}}' >"$HOME/.config/nova/shell.json"
  [ "$(state '[.lock.seconds, .bar.position]')" = '[300,"top"]' ]
  [ "$(nova-idle-lock)" = "5 min" ]
  echo '{"version":1,"idle":{"lock":600}}' >"$HOME/.config/nova/shell.json"
  [ "$(state '[.lock.seconds, .bar.position, .bar.shown[0]]')" = '[600,"top","nova.menu"]' ]
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

@test "state: fprintd is asked once while the same USB devices are plugged in, and again when one comes" {
  stub fprintd-enroll
  stub busctl 'echo asked >>"$SCRATCH/busctl-calls"; echo "ao 1 \"/net/reactivated/Fprint/Device/0\""'
  mkdir -p "$NOVA_USB_PATH/1-1"
  echo 06cb >"$NOVA_USB_PATH/1-1/idVendor"
  echo 00f9 >"$NOVA_USB_PATH/1-1/idProduct"
  [ "$(state .lock.fingerprint)" = true ]
  [ "$(state .lock.fingerprint)" = true ]
  [ "$(wc -l <"$SCRATCH/busctl-calls")" -eq 1 ]
  # A reader taken away: another device list, asked again.
  stub busctl 'echo asked >>"$SCRATCH/busctl-calls"; echo "ao 0"'
  rm -r "$NOVA_USB_PATH/1-1"
  [ "$(state .lock.fingerprint)" = false ]
  [ "$(state .lock.fingerprint)" = false ]
  [ "$(wc -l <"$SCRATCH/busctl-calls")" -eq 2 ]
  # No answer from fprintd is not kept.
  stub busctl 'echo asked >>"$SCRATCH/busctl-calls"; exit 1'
  mkdir -p "$NOVA_USB_PATH/1-2"
  echo 1d6b >"$NOVA_USB_PATH/1-2/idVendor"
  echo 0002 >"$NOVA_USB_PATH/1-2/idProduct"
  [ "$(state .lock.fingerprint)" = false ]
  [ "$(state .lock.fingerprint)" = false ]
  [ "$(wc -l <"$SCRATCH/busctl-calls")" -eq 4 ]
}

@test "state: this computer, named the way its maker names it" {
  echo "ThinkPad P1 Gen 4i" >"$NOVA_DMI_PATH/product_version"
  echo 20Y4S0ER00 >"$NOVA_DMI_PATH/product_name"
  echo LENOVO >"$NOVA_DMI_PATH/sys_vendor"
  [ "$(state '[.about.model, .about.vendor]')" = '["ThinkPad P1 Gen 4i","LENOVO"]' ]
  echo "None" >"$NOVA_DMI_PATH/product_version"
  echo "Legion 5 15ACH6H" >"$NOVA_DMI_PATH/product_name"
  [ "$(state .about.model)" = '"Legion 5 15ACH6H"' ]
  # Another maker keeps a revision in product_version: not the name.
  echo Framework >"$NOVA_DMI_PATH/sys_vendor"
  echo A6 >"$NOVA_DMI_PATH/product_version"
  echo "Laptop 13 (AMD Ryzen 7040Series)" >"$NOVA_DMI_PATH/product_name"
  [ "$(state .about.model)" = '"Laptop 13 (AMD Ryzen 7040Series)"' ]
}

@test "state: the radios, once each, switched off or not" {
  [ "$(state .radios)" = '[]' ]
  local i=0 type
  for type in wlan bluetooth bluetooth wwan; do
    mkdir -p "$NOVA_RFKILL_PATH/rfkill$i"
    echo "$type" >"$NOVA_RFKILL_PATH/rfkill$i/type"
    i=$((i + 1))
  done
  [ "$(state .radios)" = '["bluetooth","wlan","wwan"]' ]
}

@test "state: Firmware is offered only where fwupd is" {
  [ "$(state .updates.firmware)" = false ]
  stub fwupdmgr
  [ "$(state .updates.firmware)" = true ]
}

@test "state: Bluetooth LE as nova bluetooth le has it, or null where it cannot say" {
  [ "$(state .bluetooth)" = null ]
  stub nova-bluetooth-le '[[ $* == "--json" ]] && echo "{\"le\":false}"'
  [ "$(state .bluetooth)" = '{"le":false}' ]
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
