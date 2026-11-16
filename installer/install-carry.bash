# shellcheck shell=bash
# installer/install-carry.bash: what nova usb carried on the stick, opened
# before the questions and put back into the new home.
# Sourced by nova-install, never run.

# ------------------------------------------------- what nova usb carried
#
# A stick made by nova usb with things of yours on it has a second partition,
# NOVA-DATA: LUKS2, then btrfs, then carry/ with one tar.zst per item, their
# SHA-256 sums and manifest.json. It is opened read-only at $CARRY before the
# questions, so the account can default to the old one's name, and the install
# puts the SSH keys and the files back once the account exists.

carry_ready() { [[ -r $CARRY/carry/manifest.json ]]; }

# The stick's NOVA-DATA partition: on the disk the live system booted from
# when that can be told, anywhere otherwise.
carry_partition() {
  local disk
  disk=$(boot_disk)
  if [[ -n $disk ]]; then
    lsblk -nrpo PATH,PARTLABEL -- "$disk" 2>/dev/null
  else
    lsblk -nrpo PATH,PARTLABEL 2>/dev/null
  fi | awk '$2 == "NOVA-DATA" { print $1; exit }'
}

carry_items() { # -> id, kind, file and label of each item, tab-separated
  jq -r '.items[] | [.id, .kind, .file, (.label // .id)] | @tsv' "$CARRY/carry/manifest.json"
}

carry_value() { # jq path
  jq -r "$1 // empty" "$CARRY/carry/manifest.json"
}

# This computer, hashed the way nova usb hashes the one it ran on.
machine_hash() {
  local id
  id=$(cat "$DMI/product_uuid" "$DMI/product_serial" 2>/dev/null) || true
  [[ -n $id ]] || return 0
  printf '%s' "$id" | sha256sum | awk '{ print $1 }'
}

# Asks for the passphrase until it opens (or Enter skips), mounts the
# partition and checks every archive against its sum. All or nothing: a stick
# that reads back wrong carries nothing over.
carry_unlock() {
  carry_ready && return 0
  local part pass tries
  part=$(carry_partition)
  [[ -n $part ]] || return 1
  if [[ -n $ANSWERS ]]; then
    say "Your things are on this stick, encrypted"
  else
    screen Network "Your things"
    ui_note "What nova usb brought from your other computer is on this stick, encrypted."
    echo >&2
  fi
  for ((tries = 0; tries < 5; tries++)); do
    if [[ -n $ANSWERS ]]; then
      pass=$(answer passphrase)
      tries=4
    else
      # Esc, or Enter on an empty field, installs without them.
      ui_ask ui_secret "Its passphrase" "Enter to install without them" || REPLY=''
      pass=$REPLY
    fi
    if [[ -z $pass ]]; then
      : >"$CARRY_DECLINED"
      return 1
    fi
    if printf '%s' "$pass" | cryptsetup open --readonly --key-file - "$part" "$CARRY_MAPPER" 2>/dev/null; then
      mkdir -p "$CARRY"
      mount -o ro "/dev/mapper/$CARRY_MAPPER" "$CARRY" || {
        cryptsetup close "$CARRY_MAPPER"
        warn "The partition opened but would not mount; installing without your things."
        return 1
      }
      if ! (cd "$CARRY/carry" && sha256sum --quiet -c SHA256SUMS >&2); then
        warn "Some of it does not read back as it was written (above); installing without your things."
        umount "$CARRY"
        cryptsetup close "$CARRY_MAPPER"
        return 1
      fi
      info "$(carry_items | wc -l) things, from $(carry_value .source.host)"
      return 0
    fi
    [[ -z $ANSWERS ]] || die "the answers file's passphrase does not open what this stick carries; nothing was changed."
    warn "That is not the passphrase."
  done
  return 1
}

unpack() { # archive directory [tar options]
  local archive=$1 dir=$2
  shift 2
  mkdir -p "$dir"
  printf '+ unpack %s into %s\n' "$archive" "$dir" >>"$LOG"
  zstd -dc "$CARRY/carry/$archive" 2>>"$LOG" | tar -x -C "$dir" "$@" >>"$LOG" 2>&1
}

target_ids() { # user -> uid:gid in the new system
  awk -F: -v u="$1" '$1 == u { print $3 ":" $4 }' "$TARGET/etc/passwd"
}

# What this installer puts back: the SSH keys and the files picked. A stick
# from an older nova usb may carry more (a browser, Wi-Fi networks, a package
# list); that is left on the stick.
restorable() { # id kind
  [[ $1:$2 == ssh:home || $2 == folders || $2 == projects ]]
}

# The labels of what restore_carry puts back, one a line.
restorable_labels() {
  local id kind file label
  while IFS=$'\t' read -r id kind file label; do
    ! restorable "$id" "$kind" || echo "$label"
  done < <(carry_items)
}

# Puts each carried item back into the new home, as it was in the old one,
# and hands it all to the account.
restore_carry() { # user
  local user=$1 home=$TARGET/home/$1 id kind file label
  carry_ready || return 0
  say "Putting your things back"
  while IFS=$'\t' read -r id kind file label; do
    if ! restorable "$id" "$kind"; then
      info "$label: left out, this installer brings back only SSH keys and files"
      continue
    fi
    info "$label"
    unpack "$file" "$home" || warn "$label did not unpack completely; the log is in $LOG"
  done < <(carry_items)
  chown -R "$(target_ids "$user")" "$home"
}
