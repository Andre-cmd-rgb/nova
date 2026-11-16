# shellcheck shell=bash
# installer/install-disk.bash: the disks nova-install offers, and the one
# chosen partitioned, encrypted when asked, formatted and mounted, with its
# btrfs subvolumes and swap file.
# Sourced by nova-install, never run.

# ------------------------------------------------------------------- the disk

# The disk the live system booted from, so it is never offered. Empty when it
# cannot be told (booted with copytoram, say); removable disks are left out
# anyway.
boot_disk() {
  local src parent
  src=$(findmnt -no SOURCE -- "$STICK" 2>/dev/null) || return 0
  [[ -b $src ]] || return 0
  parent=$(lsblk -no PKNAME -- "$src" 2>/dev/null | awk 'NR == 1')
  if [[ -n $parent ]]; then echo "/dev/$parent"; else echo "$src"; fi
}

lsblk_disks() {
  lsblk -J -b -d -o NAME,PATH,SIZE,MODEL,SERIAL,TYPE,RM,RO,TRAN
}

# One tab-separated line per disk Nova may go on: path, size in bytes, model,
# serial, transport, with "-" for an unknown field so the columns never shift.
# Left out: the stick it booted from, read-only, removable and USB disks,
# virtual devices, and anything under 64 GiB. NOVA_ALLOW_USB=1 lets a USB disk
# through, for installing onto an external drive on purpose.
#
# A portable install turns the rule around: only removable and USB disks, of
# 32 GB or more. NOVA_ALLOW_ANY=1 lets any disk through, an image file on a
# loop device too, the way nova usb's own NOVA_USB_ALLOW_ANY does for tests.
candidate_disks() {
  local boot min=$MIN_DISK_BYTES
  boot=$(boot_disk)
  ((!PORTABLE)) || min=$MIN_PORTABLE_BYTES
  lsblk_disks | jq -r --arg boot "$boot" --argjson min "$min" --arg usb "${NOVA_ALLOW_USB:-0}" \
    --arg portable "$PORTABLE" --arg any "${NOVA_ALLOW_ANY:-0}" '
    def yes: . == true or . == "1" or . == 1;
    def portable: $portable == "1";
    .blockdevices[]
    | select((.type == "disk" or (portable and $any == "1" and .type == "loop")) and .path != $boot)
    | select(.ro | yes | not)
    | if portable then select($any == "1" or (.rm | yes) or .tran == "usb")
      else select($usb == "1" or ((.rm | yes | not) and .tran != "usb")) end
    | select((.name | test("^(zram|sr|ram|fd)")) | not)
    | select((.size | tonumber) >= $min)
    | def field: (. // "") | tostring | gsub("^\\s+|\\s+$"; "") | if . == "" then "-" else . end;
      [.path, (.size | tostring), (.model | field), (.serial | field), (.tran | field)]
    | @tsv'
}

# Something on the live system is using the disk: a mounted partition, active
# swap, or an LVM, RAID or dm-crypt device built on it.
disk_in_use() {
  local disk=$1
  lsblk -nro MOUNTPOINTS -- "$disk" | grep -q . && return 0
  lsblk -nro TYPE -- "$disk" | grep -Eq '^(lvm|crypt|raid[0-9]*|dm|md)$'
}

# What an install that stopped part-way left behind: its swap file in use and
# the new system mounted at $TARGET. Both are let go before the disk is chosen,
# or the disk would look in use by the live system and could not be picked.
release_target() {
  if swapon --noheadings --show=NAME 2>/dev/null | grep -qxF -- "$TARGET/swap/swapfile"; then
    swapoff -- "$TARGET/swap/swapfile" || die "could not stop using the last try's swap file; restart and try again."
  fi
  if mountpoint -q -- "$TARGET"; then
    info "Unmounting what the last try left at $TARGET"
    umount -R -- "$TARGET" || die "something still uses $TARGET; restart and try again."
  fi
  if [[ -e /dev/mapper/$CRYPT_NAME ]]; then
    cryptsetup close "$CRYPT_NAME" || die "could not close the last try's encrypted disk; restart and try again."
  fi
}

# /dev/nvme0n1 -> /dev/nvme0n1p2, /dev/sda -> /dev/sda2
partition_path() {
  local disk=$1 number=$2
  if [[ $disk =~ [0-9]$ ]]; then echo "${disk}p$number"; else echo "$disk$number"; fi
}

human_size() {
  awk -v b="$1" 'BEGIN { split("B KB MB GB TB PB", u); i = 1; while (b >= 1000 && i < 6) { b /= 1000; i++ } printf (i > 3 ? "%.1f %s" : "%.0f %s"), b, u[i] }'
}

# Swap for hibernation: the size of RAM, so a full image always fits, rounded
# up to a GiB and never more than an eighth of the disk.
swap_gib() {
  local disk_bytes=$1 ram_gib cap
  ram_gib=$(awk '/^MemTotal:/ { printf "%d", ($2 + 1048575) / 1048576 }' "$MEMINFO")
  cap=$((disk_bytes / 8 / 1024 / 1024 / 1024))
  ((ram_gib > 0)) || ram_gib=8
  if ((ram_gib > cap)); then echo "$cap"; else echo "$ram_gib"; fi
}

partition_and_format() {
  local disk=$1 esp root
  say "Partitioning $disk"
  logged wipefs -af "$disk"
  logged sfdisk --wipe always --wipe-partitions always "$disk" <<EOF
label: gpt
size=${ESP_MIB}MiB, type=uefi, name="NOVA-ESP"
type=linux, name="nova"
EOF
  logged udevadm settle
  esp=$(partition_path "$disk" 1)
  root=$(partition_path "$disk" 2)
  [[ -b $esp && -b $root ]] || die "the new partitions did not appear ($esp, $root)"
  logged mkfs.fat -F 32 -n NOVA-ESP "$esp"
  if [[ $ENCRYPT == yes ]]; then
    say "Encrypting the btrfs partition"
    # The passphrase on stdin, never on a command line. Discards pass
    # through (the flag kept in the header), so fstrim still reaches the SSD.
    printf '%s' "$DISK_PASSPHRASE" | logged cryptsetup luksFormat --type luks2 --batch-mode --label nova-crypt --key-file - "$root"
    printf '%s' "$DISK_PASSPHRASE" | logged cryptsetup open --allow-discards --persistent --key-file - "$root" "$CRYPT_NAME"
  fi
  logged mkfs.btrfs -f -L nova "$(root_device "$disk")"
}

# Where the btrfs filesystem is: the partition, or the container opened on it.
root_device() { # disk
  if [[ $ENCRYPT == yes ]]; then
    echo "/dev/mapper/$CRYPT_NAME"
  else
    partition_path "$1" 2
  fi
}

create_subvolumes_and_mount() {
  local disk=$1 swap=$2 esp root entry name mountpoint
  esp=$(partition_path "$disk" 1)
  root=$(root_device "$disk")
  say "Creating the filesystem layout"
  logged mount "$root" "$TARGET"
  for entry in "${SUBVOLUMES[@]}"; do
    logged btrfs subvolume create "$TARGET/${entry%%:*}"
  done
  logged umount "$TARGET"

  logged mount -o "$BTRFS_OPTS,subvol=@" "$root" "$TARGET"
  for entry in "${SUBVOLUMES[@]:1}"; do
    name=${entry%%:*}
    mountpoint=${entry#*:}
    logged mkdir -p "$TARGET$mountpoint"
    if [[ $name == @swap ]]; then
      logged mount -o "noatime,subvol=$name" "$root" "$TARGET$mountpoint"
    else
      logged mount -o "$BTRFS_OPTS,subvol=$name" "$root" "$TARGET$mountpoint"
    fi
  done
  logged chmod 750 "$TARGET/.snapshots"
  logged mkdir -p "$TARGET/boot"
  logged mount -o fmask=0077,dmask=0077 "$esp" "$TARGET/boot"

  # None for a portable install (swap 0), which never hibernates; its
  # subvolume stays, for a swap file made by hand later.
  ((swap > 0)) || return 0
  info "A ${swap} GiB swap file, for hibernation"
  logged btrfs filesystem mkswapfile --size "${swap}g" --uuid clear "$TARGET/swap/swapfile"
  logged swapon "$TARGET/swap/swapfile"
}
