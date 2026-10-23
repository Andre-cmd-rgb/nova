# shellcheck shell=bash
# Wi-Fi on the installer stick: networks written as iwd's own files, so a
# password never goes on a command line, where any process can read it.
# Sourced by nova-install (carried networks) and nova-install-start (the
# network screen).

IWD_DIR=${NOVA_IWD_DIR:-/var/lib/iwd}

# The name iwd gives a network's file: the SSID itself when it is plain, else
# "=" and its bytes in hex.
iwd_name() {
  local LC_ALL=C
  if [[ $1 =~ ^[A-Za-z0-9\ _-]+$ ]]; then
    echo "$1"
  else
    printf '=%s\n' "$(printf '%s' "$1" | od -An -tx1 | tr -d ' \n')"
  fi
}

# A value as iwd's files hold it. iwd reads \\, \t and \s (a leading space)
# as escapes and refuses any other backslash, so a password written as typed
# could come out another, or not at all.
iwd_value() {
  local value=${1//\\/\\\\}
  value=${value//$'\t'/\\t}
  [[ $value != ' '* ]] || value="\\s${value:1}"
  printf '%s' "$value"
}

# A personal (WPA2/WPA3) network iwd joins with this passphrase.
iwd_write_psk() { # ssid passphrase [hidden]
  mkdir -p "$IWD_DIR"
  {
    printf '[Security]\nPassphrase=%s\n' "$(iwd_value "$2")"
    [[ -z ${3:-} ]] || printf '\n[Settings]\nHidden=true\n'
  } | install -m 600 /dev/stdin "$IWD_DIR/$(iwd_name "$1").psk"
}

# iwd notices a new file by itself, a moment after it is written.
iwd_wait_known() { # ssid
  local i
  for ((i = 0; i < 20; i++)); do
    iwctl known-networks "$1" show >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}
