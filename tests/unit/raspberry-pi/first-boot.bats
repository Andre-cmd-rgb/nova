#!/usr/bin/env bats

# nova-first-boot, a Pi's first start from Nova's image: the questions in
# their order, the Wi-Fi as NetworkManager lists and joins it, the country's
# channels, and what an attempt cut short leaves to the next.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_SETUP_SHARE="$REPO_ROOT/installer"
  export NOVA_TARGET="$SCRATCH/root" NOVA_BOOT="$SCRATCH/boot" NOVA_FIRST_BOOT_LOG="$SCRATCH/log"
  export NOVA_NM_CONNECTIONS="$SCRATCH/nm" NOVA_ZONE_TAB="$SCRATCH/zone.tab" NOVA_ZONEINFO="$SCRATCH/zoneinfo"
  mkdir -p "$NOVA_TARGET/etc" "$NOVA_BOOT" "$NOVA_ZONEINFO/Europe"
  touch "$NOVA_ZONEINFO/UTC" "$NOVA_ZONEINFO/Europe/Rome"
  printf '# comment\nIT\t+4154+01229\tEurope/Rome\nDE\t+5230+01322\tEurope/Berlin\n' >"$NOVA_ZONE_TAB"
  echo 'root=PARTUUID=0a0b0c0d-02 rw rootwait quiet' >"$NOVA_BOOT/cmdline.txt"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/data/raspberry-pi/bin/nova-first-boot"
  sleep() { :; }
  loadkeys() { :; }
  iw() { echo "iw $*" >>"$SCRATCH/calls"; }
  valid_keymap() { [[ $1 =~ ^(us|de|it)$ ]]; }
  timezones() { printf '%s\n' UTC Europe/Rome; }
}

teardown() { teardown_scratch; }

# What `nmcli -t -e yes -f SIGNAL,SECURITY,SSID device wifi list` prints: two
# access points of one network, names with a colon and a backslash, WPA3, an
# open café, an enterprise and a WEP network, and a hidden one.
NMCLI_LIST='54:WPA2:Casa
81:WPA2:Casa
70:WPA1 WPA2:Bar\: Sport\\2
40:WPA3:Attic
35::Cafe
60:WPA2 802.1X:eduroam
20:WEP:Old
75:WPA2:'

@test "wifi_networks: strongest first, each once, and only what a password or nothing joins" {
  nmcli() { printf '%s\n' "$NMCLI_LIST"; }
  run wifi_networks wld0
  [ "$status" -eq 0 ]
  [ "$output" = "Casa	psk
Bar: Sport\\2	psk
Attic	sae
Cafe	open" ]
}

@test "nm_write_wifi: the network's name byte by byte, the password as GLib reads it" {
  file=$(nm_write_wifi "Bar; x" psk ' pa\ss	word')
  [ "$(stat -c %a "$file")" = 600 ]
  [[ $file == "$NOVA_NM_CONNECTIONS/Bar__x-"*.nmconnection ]]
  grep -qx 'id=Bar; x' "$file"
  grep -qx 'ssid=66;97;114;59;32;120;' "$file"
  grep -qx 'key-mgmt=wpa-psk' "$file"
  grep -qxF 'psk=\spa\\ss\tword' "$file"
  fails grep -q hidden "$file"
}

@test "nm_write_wifi: WPA3 alone is SAE, an open network has no password, a hidden one says so" {
  grep -qx 'key-mgmt=sae' "$(nm_write_wifi Attic sae hunter2222)"
  open=$(nm_write_wifi Cafe open)
  fails grep -q 'wifi-security' "$open"
  grep -qx 'hidden=true' "$(nm_write_wifi Den psk hunter2222 yes)"
}

@test "connect_wifi: a network picked from the list is joined, its password never an argument" {
  nmcli() {
    echo "nmcli $*" >>"$SCRATCH/calls"
    [[ $* != *"wifi list"* ]] || printf '%s\n' "$NMCLI_LIST"
  }
  wait_online() { :; }
  stub_gum 0 hunter2222
  connect_wifi wld0 2>/dev/null
  [ "$NETWORK" = Casa ]
  grep -q '^nmcli connection load .*/Casa-' "$SCRATCH/calls"
  grep -q '^nmcli --wait 30 connection up uuid ' "$SCRATCH/calls"
  fails grep -q hunter2222 "$SCRATCH/calls"
  grep -qx 'psk=hunter2222' "$NOVA_NM_CONNECTIONS"/Casa-*.nmconnection
  grep -q 'Cafe  (open)' "$GUM_LOG"
}

@test "connect_wifi: a network joined that reaches no internet is kept, and the summary says what waits" {
  # A router's parental control or a captive portal: the network is joined, the
  # AUR does not answer through it.
  nmcli() { [[ $* != *"wifi list"* ]] || printf '%s\n' "$NMCLI_LIST"; }
  online() { return 1; }
  stub_gum 0 hunter2222
  connect_wifi wld0 2>"$SCRATCH/screens"
  [ "$NETWORK" = Casa ]
  [ "$ONLINE" = 0 ]
  fails grep -q 'Could not connect' "$SCRATCH/screens"
  [ "$(ls "$NOVA_NM_CONNECTIONS" | wc -l)" -eq 1 ]
  ACCOUNT=ada FULLNAME=Ada COMPUTER=pi TIMEZONE=UTC KEYMAP=us
  [[ $(summary_lines) == *"Network      Casa, no internet: Chrome, VS Code, Claude Code and Codex come later"* ]]
}

@test "connect_wifi: a password refused is forgotten and asked again; no network is a choice" {
  nmcli() {
    case $* in
      *"wifi list"*) printf '%s\n' "$NMCLI_LIST" ;;
      *"connection up"*) return 4 ;;
      *"connection delete"*) return 10 ;;
    esac
  }
  stub_gum 0 wrong-password 0 short none
  run connect_wifi wld0
  [ "$status" -eq 2 ]
  [[ $output == *"Could not connect to Casa."* ]]
  [[ $output == *"A Wi-Fi password has 8 characters or more."* ]]
  [ "$(gum_replies_left)" = 0 ]
  [ -z "$(ls -A "$NOVA_NM_CONNECTIONS")" ]
}

@test "use_regdom: the time zone's country, now and on the kernel's command line" {
  use_regdom Europe/Rome
  [ "$(cat "$NOVA_BOOT/cmdline.txt")" = 'root=PARTUUID=0a0b0c0d-02 rw rootwait quiet cfg80211.ieee80211_regdom=IT' ]
  grep -qx 'iw reg set IT' "$SCRATCH/calls"
  # Going back and picking another replaces it.
  use_regdom Europe/Berlin
  [ "$(cat "$NOVA_BOOT/cmdline.txt")" = 'root=PARTUUID=0a0b0c0d-02 rw rootwait quiet cfg80211.ieee80211_regdom=DE' ]
  # A zone of no country leaves the Pi to the channels every country allows.
  use_regdom UTC
  grep -q 'regdom=DE' "$NOVA_BOOT/cmdline.txt"
}

@test "screens: the keyboard, this computer, the network, you, then what it will do" {
  online() { :; }
  current_network() { echo Casa; }
  stub_gum "German (de)" "" Europe/Rome "Ada Lovelace" "" s3cret-pass s3cret-pass 0
  questions_on_screen 2>"$SCRATCH/screens"
  [ "$(gum_replies_left)" = 0 ]
  [ "$KEYMAP" = de ] && [ "$COMPUTER" = nova ] && [ "$TIMEZONE" = Europe/Rome ]
  [ "$ACCOUNT" = ada ] && [ "$PASSWORD" = s3cret-pass ] && [ "$NETWORK" = Casa ]
  grep -q 'regdom=IT' "$NOVA_BOOT/cmdline.txt"
  grep -q 'Account      ada (Ada Lovelace) on nova' "$SCRATCH/screens"
  grep -q 'Network      Casa' "$SCRATCH/screens"
  grep -q 'Set up Nova  ·  ready' "$SCRATCH/screens"
}

@test "screens: Esc on the first one stays there, and No at the end goes back to you" {
  online() { :; }
  current_network() { echo Ethernet; }
  stub_gum '!1' "Italian (it)" "" UTC "Ada" "" s3cret-pass s3cret-pass '!1' "Ada" "" s3cret-pass s3cret-pass 0
  questions_on_screen 2>/dev/null
  [ "$(gum_replies_left)" = 0 ]
  [ "$KEYMAP" = it ] && [ "$ACCOUNT" = ada ]
  [ "$(grep -c '^filter.*Keyboard layout' "$GUM_LOG")" = 2 ]
}

@test "no network at all: the setup goes on, and says what waits for one" {
  online() { return 1; }
  wifi_device() { :; }
  stub_gum "English (US) (us)" "" UTC '!1' "Ada" "" s3cret-pass s3cret-pass 0
  questions_on_screen 2>"$SCRATCH/screens"
  [ -z "$NETWORK" ]
  grep -q 'Network      none: Chrome, VS Code, Claude Code and Codex come later' "$SCRATCH/screens"
}

@test "init_keyring: a packager's key refused stops the attempt, and says the clock" {
  # What a clock behind a key's making leaves: gpg skips the key, and
  # pacman-key cannot sign it.
  pacman-key() { [[ $1 == --init ]]; }
  run init_keyring
  [ "$status" -eq 1 ]
  [[ $output == *"pacman's keyring refused a packager's key, with the clock at "* ]]
  grep -qx '+ pacman-key --populate' "$NOVA_FIRST_BOOT_LOG"
}

@test "attempts: a step that fails ends the attempt there, and the next starts from the first" {
  # In a bash of its own, as the service runs it: the test's shell has an ERR
  # trap of bats's. The setup is a stand-in with the real one's trap, around a
  # second step that fails the first time.
  cat >"$SCRATCH/first-boot" <<'EOF'
source "$1"
sleep() { :; }
set_up() {
  set -E
  trap 'stopped "$LINENO" "$BASH_COMMAND"' ERR
  echo first >>"$SCRATCH/calls"
  second_step
  echo third >>"$SCRATCH/calls"
}
second_step() {
  [[ ! -e $SCRATCH/failed ]] || return 0
  touch "$SCRATCH/failed"
  grep -q never /dev/null
}
attempts </dev/null
EOF
  run bash "$SCRATCH/first-boot" "$REPO_ROOT/data/raspberry-pi/bin/nova-first-boot"
  [ "$status" -eq 0 ]
  [ "$(cat "$SCRATCH/calls")" = "first
first
third" ]
  [[ $output == *"the setup stopped at line "*" (grep -q never /dev/null)"* ]]
}

@test "an attempt cut short: the account it made is made again, no other is touched" {
  printf 'root:x:0:0::/root:/bin/bash\nada:x:1000:1000::/home/ada:/bin/bash\nnobody:x:65534:65534::/:/usr/bin/nologin\n' >"$NOVA_TARGET/etc/passwd"
  userdel() { echo "userdel $*" >>"$SCRATCH/calls"; }
  forget_earlier_attempt
  [ "$(cat "$SCRATCH/calls")" = "userdel -r ada" ]
}
