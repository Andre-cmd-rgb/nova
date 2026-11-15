# shellcheck shell=bash
# Wi-Fi on the installer stick: networks written as iwd's own files, so a
# password never goes on a command line, where any process can read it.
# Sourced by nova-install (the networks the new system starts with) and
# nova-install-start (the network screen).

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

# The networks joined on the stick, as NetworkManager's own files in the new
# system: without them a laptop with no Ethernet port starts offline, and asks
# again for the password typed here. Personal and open networks; iwd's
# escapes (\\, \t, a leading \s) are those of NetworkManager's files too, so
# a passphrase goes over as it is. An SSID in hex (iwd's name for one that is
# not plain) goes over as its bytes.
iwd_to_networkmanager() { # directory
  local dest=$1 file base name kind passphrase hidden id ssid hex i
  for file in "$IWD_DIR"/*.psk "$IWD_DIR"/*.open; do
    [[ -f $file ]] || continue
    base=${file##*/} name=${base%.*} kind=${base##*.}
    passphrase=$(sed -n 's/^Passphrase=//p' "$file" | head -n 1)
    [[ $kind == open || -n $passphrase ]] || continue
    hidden=false
    ! grep -qx 'Hidden=true' "$file" || hidden=true
    if [[ $name == =* ]]; then
      hex=${name#=} ssid='' id=''
      for ((i = 0; i < ${#hex}; i += 2)); do
        ssid+="$((16#${hex:i:2}));"
        id+="\\x${hex:i:2}"
      done
      id=$(printf '%b' "$id" | LC_ALL=C tr -c '[:print:]' '?')
      id=${id//\\/\\\\}
    else
      ssid=$name id=$name
    fi
    # A leading space is one GKeyFile would drop.
    [[ $ssid != ' '* ]] || ssid="\\s${ssid:1}"
    [[ $id != ' '* ]] || id="\\s${id:1}"
    {
      printf '[connection]\nid=%s\nuuid=%s\ntype=wifi\n\n' "$id" "$(cat /proc/sys/kernel/random/uuid)"
      printf '[wifi]\nmode=infrastructure\nssid=%s\nhidden=%s\n\n' "$ssid" "$hidden"
      [[ $kind == open ]] || printf '[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n' "$passphrase"
      printf '[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n'
    } | install -D -m 600 /dev/stdin "$dest/$name.nmconnection"
  done
}

