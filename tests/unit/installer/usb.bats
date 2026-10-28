#!/usr/bin/env bats

load ../test_helper

setup() {
  setup_scratch
  export NOVA_USB_HOME="$SCRATCH/home"
  export NOVA_USB_CACHE="$SCRATCH/cache"
  export NOVA_USB_SYSROOT="$SCRATCH/sys"
  export NOVA_USB_STAGE_ROOT="$SCRATCH/staging"
  export NOVA_USB_UDEV_RULE="$SCRATCH/rules.d/90-nova-usb.rules"
  export NOVA_DMI_PATH="$SCRATCH/dmi"
  mkdir -p "$NOVA_USB_HOME" "$NOVA_USB_SYSROOT" "$SCRATCH/plan"
  # shellcheck source=/dev/null
  source "$REPO_ROOT/installer/nova-usb"
  PLAN=$SCRATCH/plan
}

teardown() { teardown_scratch; }

GB=$((1000 * 1000 * 1000))

# lsblk -J for the disks on stdin, one per line: name size rm ro tran [model]
disks_json() {
  local name size rm ro tran model sep=
  printf '{"blockdevices":['
  while read -r name size rm ro tran model; do
    [[ $tran == null ]] || tran="\"$tran\""
    printf '%s{"name":"%s","path":"/dev/%s","size":%s,"model":"%s","serial":"S-%s","type":"disk","rm":%s,"ro":%s,"tran":%s}' \
      "$sep" "$name" "$name" "$size" "$model" "$name" "$rm" "$ro" "$tran"
    sep=,
  done
  printf ']}\n'
}

# The member names of an archive the writer made, sorted.
members() { zstd -dc "$1" | tar -t | sed 's,/$,,' | sort; }

@test "items: the SSH keys and the files picked, and nothing else" {
  [ "$(item_label ssh)" = "SSH keys" ] && [ "$(item_kind ssh)" = home ]
  [ "$(item_label files)" = "Files and folders" ] && [ "$(item_kind files)" = folders ]
  valid_item ssh
  valid_item files
  fails valid_item chrome
  fails valid_item ''
}

@test "stick_candidates: removable or USB disks only, never the system's own" {
  lsblk_disks() {
    disks_json <<EOF
nvme0n1 $((512 * GB)) 0 0 nvme Internal
sda $((32 * GB)) 1 0 usb SanDisk
sdb $((64 * GB)) 0 0 usb SSD
sdc $((16 * GB)) 1 1 usb Locked
sdd $((1 * GB)) 1 0 usb Tiny
mmcblk0 $((64 * GB)) 0 0 null Card
sde $((32 * GB)) 1 0 usb Booted
EOF
  }
  system_disks() { printf '%s\n' /dev/nvme0n1 /dev/sde; }
  [ "$(stick_candidates | cut -f1 | tr '\n' ' ')" = "/dev/sda /dev/sdb " ]
  [ "$(stick_candidates | awk -F'\t' '$1 == "/dev/sda" { print $3, $4 }')" = "SanDisk S-sda" ]
  # Allowing any disk lets the card reader in; the system disks stay out.
  [ "$(NOVA_USB_ALLOW_ANY=1 stick_candidates | cut -f1 | tr '\n' ' ')" = "/dev/sda /dev/sdb /dev/mmcblk0 " ]
}

@test "system_disks: each file system it runs from is looked up on its own" {
  mkdir -p "$NOVA_USB_CACHE"
  findmnt() { echo "${@: -1}" >>"$SCRATCH/asked"; }
  swapon() { :; }
  system_disks
  [ "$(paste -sd' ' "$SCRATCH/asked")" = "/ /boot /efi /boot/efi /home /usr /var /opt /srv $NOVA_USB_HOME $NOVA_USB_CACHE" ]
}

@test "disk_contents: one line per partition, with or without a label" {
  lsblk() {
    echo '{"blockdevices":[{"name":"sdb","size":"114.6G","fstype":null,"label":null,"children":[
      {"name":"sdb1","size":"114.6G","fstype":"exfat","label":"andre backups"},
      {"name":"sdb2","size":"16M","fstype":null,"label":null}]}]}'
  }
  [ "$(disk_contents /dev/sdb)" = $'sdb1  114.6G  exfat  "andre backups"\nsdb2  16M  no file system' ]
}

@test "ask_paths: what was typed before comes back, and a name not in the home is skipped" {
  mkdir -p "$NOVA_USB_HOME/Projects/app" "$NOVA_USB_HOME/Work"
  echo notes >"$NOVA_USB_HOME/Work/notes.md"
  stub_gum "Projects/app, Work/notes.md" " Work/notes.md , nowhere" '!1'
  TYPED_PATHS=(Projects/app Work/notes.md)
  ask_paths
  [ "${TYPED_PATHS[*]}" = "Projects/app Work/notes.md" ]
  grep -q -- '--value Projects/app, Work/notes.md ' "$GUM_LOG"
  ask_paths 2>"$SCRATCH/err"
  [ "${TYPED_PATHS[*]}" = Work/notes.md ]
  grep -q 'Nothing called nowhere in your home' "$SCRATCH/err"
  # Esc leaves them as they were.
  fails ask_paths
  [ "${TYPED_PATHS[*]}" = Work/notes.md ]
}

@test "writer_cleanup: a mount that will not let go does not stop the rest" {
  mkdir -p "$SCRATCH/work/data" "$SCRATCH/work/stick" "$SCRATCH/work/iso"
  touch "$SCRATCH/rule"
  run bash -c 'source "$1"; WORK=$2/work UDEV_RULE=$2/rule
    mountpoint() { return 0; }
    umount() { return 32; }
    udevadm() { :; }
    writer_cleanup
    echo finished' _ "$REPO_ROOT/installer/nova-usb" "$SCRATCH"
  [ "$status" -eq 0 ]
  [ "$output" = finished ]
  [ ! -e "$SCRATCH/work" ] && [ ! -e "$SCRATCH/rule" ]
}

@test "stick_matches: the writer refuses a disk that changed since it was picked" {
  json=$(disks_json <<<"sda $((32 * GB)) 1 0 usb SanDisk")
  stick_matches $((32 * GB)) S-sda <<<"$json"
  fails stick_matches $((64 * GB)) S-sda <<<"$json"
  fails stick_matches $((32 * GB)) S-other <<<"$json"
  internal=$(disks_json <<<"nvme0n1 $((32 * GB)) 0 0 nvme Disk")
  fails stick_matches $((32 * GB)) S-nvme0n1 <<<"$internal"
  NOVA_USB_ALLOW_ANY=1 stick_matches $((32 * GB)) S-nvme0n1 <<<"$internal"
}

@test "home_relative: files and folders inside the home only" {
  mkdir -p "$NOVA_USB_HOME/Projects/Coding" "$SCRATCH/elsewhere"
  echo notes >"$NOVA_USB_HOME/Projects/notes.md"
  ln -s "$SCRATCH/elsewhere" "$NOVA_USB_HOME/out"
  [ "$(home_relative Projects)" = Projects ]
  [ "$(home_relative "$NOVA_USB_HOME/Projects/Coding/")" = Projects/Coding ]
  [ "$(home_relative "~/Projects")" = Projects ]
  [ "$(home_relative Projects/notes.md)" = Projects/notes.md ]
  fails home_relative "$SCRATCH/elsewhere"
  fails home_relative out
  fails home_relative Missing
  fails home_relative ../elsewhere
  fails home_relative "$NOVA_USB_HOME"
  # A home reached through a link is still the home.
  ln -s "$NOVA_USB_HOME" "$SCRATCH/linked-home"
  USB_HOME=$SCRATCH/linked-home
  [ "$(home_relative Projects/notes.md)" = Projects/notes.md ]
  [ "$(home_relative "$SCRATCH/linked-home/Projects")" = Projects ]
}

@test "home_entries: the top of the home with sizes, by name, the hidden left out" {
  mkdir -p "$NOVA_USB_HOME/Documents" "$NOVA_USB_HOME/bin" "$NOVA_USB_HOME/.config"
  head -c 5000 /dev/zero >"$NOVA_USB_HOME/Documents/a"
  echo notes >"$NOVA_USB_HOME/notes.txt"
  echo rc >"$NOVA_USB_HOME/.bashrc"
  echo odd >"$NOVA_USB_HOME/with"$'\t'"tab"
  run home_entries
  [ "$status" -eq 0 ]
  [ "$(cut -f2 <<<"$output" | paste -sd' ')" = "bin Documents notes.txt" ]
  [ "$(awk -F'\t' '$2 == "Documents" { print $1 }' <<<"$output")" -ge 5000 ]
  # A folder du cannot read all of is still listed, with what it could read.
  if ((EUID != 0)); then
    mkdir -p "$NOVA_USB_HOME/bin/locked"
    chmod 000 "$NOVA_USB_HOME/bin/locked"
    run home_entries
    chmod 700 "$NOVA_USB_HOME/bin/locked"
    [ "$status" -eq 0 ]
    [ "$(cut -f2 <<<"$output" | paste -sd' ')" = "bin Documents notes.txt" ]
  fi
}

@test "list_files: each path once, and none inside another picked" {
  FILE_PATHS=(Work Documents/a.txt Work/notes Documents/a.txt "Odd, name" Workshop)
  list_files "$PLAN"
  [ "$(tr '\0' '\n' <"$PLAN/files.list" | paste -sd'|')" = "Work|Documents/a.txt|Odd, name|Workshop" ]
  FILE_PATHS=()
  list_files "$PLAN"
  [ ! -s "$PLAN/files.list" ]
  fails item_present files "$PLAN"
}

@test "archives: the SSH keys as they are, and nothing for an item with nothing here" {
  run make_archive ssh "$PLAN" "$NOVA_USB_HOME" "$SCRATCH/ssh.tar.zst"
  [ "$status" -eq 2 ]
  fails item_present ssh "$PLAN"
  mkdir -m 700 "$NOVA_USB_HOME/.ssh"
  echo key >"$NOVA_USB_HOME/.ssh/id_ed25519"
  chmod 600 "$NOVA_USB_HOME/.ssh/id_ed25519"
  item_present ssh "$PLAN"
  make_archive ssh "$PLAN" "$NOVA_USB_HOME" "$SCRATCH/ssh.tar.zst"
  [ "$(members "$SCRATCH/ssh.tar.zst" | paste -sd' ')" = ".ssh .ssh/id_ed25519" ]
  zstd -dc "$SCRATCH/ssh.tar.zst" | tar -tv | grep -Eq '^-rw------- .* \.ssh/id_ed25519$'
  [ "$(item_bytes ssh "$PLAN")" -gt 0 ]
  # Picked files that have all gone since are nothing to carry either.
  printf '%s\0' gone.txt >"$PLAN/files.list"
  run make_archive files "$PLAN" "$NOVA_USB_HOME" "$SCRATCH/files.tar.zst"
  [ "$status" -eq 2 ]
  run make_archive chrome "$PLAN" "$NOVA_USB_HOME" "$SCRATCH/chrome.tar.zst"
  [ "$status" -eq 1 ]
}

@test "archives: the files and folders picked, less what a program tagged as its cache" {
  local work=$NOVA_USB_HOME/Work
  mkdir -p "$work/game/src" "$work/game/target/debug" "$work/notes/target"
  echo main >"$work/game/src/main.rs"
  echo 'Signature: 8a477f597d28d172789f06886806bc55' >"$work/game/target/CACHEDIR.TAG"
  head -c 100000 /dev/zero >"$work/game/target/debug/game"
  # A tag without the signature tags nothing.
  echo 'keep me' >"$work/notes/target/CACHEDIR.TAG"
  echo plan >"$work/notes/target/plan.md"
  echo todo >"$NOVA_USB_HOME/todo.txt"
  echo other >"$NOVA_USB_HOME/other.txt"
  FILE_PATHS=(Work todo.txt)
  list_files "$PLAN"
  make_archive files "$PLAN" "$NOVA_USB_HOME" "$SCRATCH/files.tar.zst"
  run members "$SCRATCH/files.tar.zst"
  [[ $output == *"Work/game/src/main.rs"* && $output == *"Work/notes/target/plan.md"* ]]
  grep -qx todo.txt <<<"$output"
  [[ $output != *debug* && $output != *other.txt* ]]
  # The size shown is of what is carried, with a cache or without one.
  [ "$(item_bytes files "$PLAN")" -lt 100000 ]
  FILE_PATHS=(Work/notes)
  list_files "$PLAN"
  [ "$(item_bytes files "$PLAN")" -gt 0 ]
}

@test "packages on the stick: names FAT can hold, each with its signature" {
  printf 'https://archive.archlinux.org/repos/2026/10/01/extra/os/x86_64/ffmpeg-2:7.1-1-x86_64.pkg.tar.zst\t100\n' >"$PLAN/offline.urls"
  printf 'https://nova-packages.piserver.stream/v1.0.0/nova-1.0.0-1-any.pkg.tar.zst\t50\n' >>"$PLAN/offline.urls"
  printf 'https://example.org/repo/libc%%2B%%2B-1-1-x86_64.pkg.tar.zst\t10\n' >>"$PLAN/offline.urls"
  curl() { cp -- "${@: -1}" "$SCRATCH/curl.config"; }
  download_packages "$PLAN/offline.urls" /stick/repo
  grep -qx 'output = "/stick/repo/ffmpeg-2_7.1-1-x86_64.pkg.tar.zst"' "$SCRATCH/curl.config"
  grep -qx 'output = "/stick/repo/ffmpeg-2_7.1-1-x86_64.pkg.tar.zst.sig"' "$SCRATCH/curl.config"
  grep -qx 'url = "https://archive.archlinux.org/repos/2026/10/01/extra/os/x86_64/ffmpeg-2:7.1-1-x86_64.pkg.tar.zst.sig"' "$SCRATCH/curl.config"
  grep -qx 'output = "/stick/repo/nova-1.0.0-1-any.pkg.tar.zst"' "$SCRATCH/curl.config"
  grep -qx 'output = "/stick/repo/libc++-1-1-x86_64.pkg.tar.zst"' "$SCRATCH/curl.config"
}

@test "packages on the stick: a name that decodes to a path is refused" {
  printf 'https://example.org/repo/..%%2F..%%2Fetc%%2Fcron.d%%2Fx.pkg.tar.zst\t10\n' >"$PLAN/offline.urls"
  curl() { touch "$SCRATCH/curl.ran"; }
  run download_packages "$PLAN/offline.urls" /stick/repo
  [ "$status" -ne 0 ]
  [[ $output == *refusing* ]]
  [ ! -e "$SCRATCH/curl.ran" ]
}

# A disk with room, a package server, and an indexer. No block devices used.
staging_setup() {
  mkdir -p "$NOVA_USB_STAGE_ROOT" "$SCRATCH/stick" "$SCRATCH/pkg"
  printf 'https://example.org/a-1-1-any.pkg.tar.zst\t4\n' >"$PLAN/offline.urls"
  findmnt() { echo ext4; }
  df() { printf 'Filesystem 1B-blocks Used Available Use%% Mounted\n/disk 999999999 0 999999999 0%% /\n'; }
  pacman-conf() { echo "$SCRATCH/pkg"; }
  curl() {
    cp -- "${@: -1}" "$SCRATCH/curl.config"
    local line path
    while IFS= read -r line; do
      [[ $line == 'output = '* ]] || continue
      path=${line#output = \"}
      path=${path%\"}
      printf data >"$path"
    done <"${@: -1}"
  }
  make_offline_repo() { printf db >"$1/nova-offline.db"; }
}

@test "packages stage on local disk, then copy one file at a time" {
  staging_setup
  stage_packages "$PLAN/offline.urls"
  [[ $PACKAGE_STAGE == "$NOVA_USB_STAGE_ROOT"/nova-usb-packages.* ]]
  [ -f "$PACKAGE_STAGE/a-1-1-any.pkg.tar.zst.sig" ]
  [ ! -e "$SCRATCH/stick/a-1-1-any.pkg.tar.zst" ]
  cp() { printf '%s\n' "$*" >>"$SCRATCH/copies"; command cp "$@"; }
  copy_packages "$PACKAGE_STAGE" "$SCRATCH/stick"
  [ "$(wc -l <"$SCRATCH/copies")" -eq 3 ]
  diff -r "$PACKAGE_STAGE" "$SCRATCH/stick"
  local staged=$PACKAGE_STAGE
  writer_cleanup
  [ ! -e "$staged" ]
}

@test "packages fall back to the stick when local disk space is short" {
  staging_setup
  df() { printf 'Filesystem 1B-blocks Used Available Use%% Mounted\n/disk 100 0 100 0%% /\n'; }
  stage_packages "$PLAN/offline.urls" 2>"$SCRATCH/notice"
  [ -z "$PACKAGE_STAGE" ]
  [ "$(wc -l <"$SCRATCH/notice")" -eq 1 ]
  grep -q 'straight to the stick' "$SCRATCH/notice"
  [ ! -e "$SCRATCH/curl.config" ]
  download_packages "$PLAN/offline.urls" "$SCRATCH/stick"
  [ -f "$SCRATCH/stick/a-1-1-any.pkg.tar.zst.sig" ]
}

@test "packages never stage on tmpfs even when it has room" {
  staging_setup
  findmnt() { echo tmpfs; }
  stage_packages "$PLAN/offline.urls"
  [ -z "$PACKAGE_STAGE" ]
  [ ! -e "$SCRATCH/curl.config" ]
}

@test "the package space check includes a margin above the plan's bytes" {
  staging_setup
  printf 'https://example.org/a.pkg.tar.zst\t200000000\n' >"$PLAN/offline.urls"
  df() { printf 'Filesystem 1B-blocks Used Available Use%% Mounted\n/disk 210000000 0 210000000 0%% /\n'; }
  stage_packages "$PLAN/offline.urls"
  [ -z "$PACKAGE_STAGE" ]
}

@test "the EXIT trap removes staged packages after success or a failed download" {
  staging_setup
  export -f findmnt df pacman-conf curl make_offline_repo
  run bash -c 'source "$REPO_ROOT/installer/nova-usb"; make_offline_repo() { :; }; trap writer_cleanup EXIT; stage_packages "$1/offline.urls"' _ "$PLAN"
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$NOVA_USB_STAGE_ROOT")" ]
  curl() { touch "$SCRATCH/partial"; return 22; }
  export -f curl
  run bash -c 'source "$REPO_ROOT/installer/nova-usb"; trap writer_cleanup EXIT; stage_packages "$1/offline.urls"' _ "$PLAN"
  [ "$status" -ne 0 ]
  [[ $output == *"nothing was written"* ]]
  [ -e "$SCRATCH/partial" ]
  [ -z "$(ls -A "$NOVA_USB_STAGE_ROOT")" ]
}

@test "packages reuse a cache entry only with the same name, size and a signature" {
  staging_setup
  printf data >"$SCRATCH/pkg/a-1-1-any.pkg.tar.zst"
  printf signed >"$SCRATCH/pkg/a-1-1-any.pkg.tar.zst.sig"
  download_packages "$PLAN/offline.urls" "$SCRATCH/stick"
  [ ! -e "$SCRATCH/curl.config" ]
  [ "$(cat "$SCRATCH/stick/a-1-1-any.pkg.tar.zst.sig")" = signed ]
  printf wrong-size >"$SCRATCH/pkg/a-1-1-any.pkg.tar.zst"
  download_packages "$PLAN/offline.urls" "$SCRATCH/stick"
  [ -e "$SCRATCH/curl.config" ]
  rm "$SCRATCH/curl.config" "$SCRATCH/pkg/a-1-1-any.pkg.tar.zst.sig"
  printf data >"$SCRATCH/pkg/a-1-1-any.pkg.tar.zst"
  download_packages "$PLAN/offline.urls" "$SCRATCH/stick"
  [ -e "$SCRATCH/curl.config" ]
}

@test "still_there: a listed name that leaves the home is dropped" {
  mkdir -p "$NOVA_USB_HOME/Documents" "$SCRATCH/secret"
  printf '%s\0' Documents ../secret "$SCRATCH/secret" Documents/../../secret >"$PLAN/files.list"
  [ "$(still_there "$NOVA_USB_HOME" "$PLAN/files.list" | tr '\0' ' ')" = "Documents " ]
}

@test "packages on the stick: fetched from the release's own snapshot and repository" {
  printf 'version = "1.0.0"\narch_date = "2026/10/01"\nnova_repo = "https://nova-packages.piserver.stream/v1.0.0"\n' >"$SCRATCH/release.toml"
  run offline_pacman_conf "$SCRATCH/release.toml"
  [[ $output == *'Server = https://archive.archlinux.org/repos/2026/10/01/$repo/os/$arch'* ]]
  [[ $output == *'Server = https://nova-packages.piserver.stream/v1.0.0'* ]]
  printf 'arch_date = "yesterday"\n' >"$SCRATCH/bad.toml"
  run offline_pacman_conf "$SCRATCH/bad.toml"
  [ "$status" -ne 0 ]
}

@test "while writing, the stick and its partitions are hidden from the desktop's automounter" {
  UDEV_RULE="$SCRATCH/rules.d/90-nova-usb.rules"
  udevadm() { :; }
  hide_from_desktop /dev/sdb
  grep -qx 'KERNEL=="sdb|sdb\[0-9\]\*", ENV{UDISKS_IGNORE}="1"' "$UDEV_RULE"
  grep -qx 'ENV{DM_NAME}=="nova-usb-data", ENV{UDISKS_IGNORE}="1"' "$UDEV_RULE"
  hide_from_desktop /dev/nvme1n1
  grep -q 'KERNEL=="nvme1n1|nvme1n1p\[0-9\]\*"' "$UDEV_RULE"
  writer_cleanup
  [ ! -e "$UDEV_RULE" ]
}

@test "console_keymap: this computer's console layout, quoted or not, or nothing" {
  run console_keymap
  [ "$status" -eq 0 ] && [ -z "$output" ]
  mkdir -p "$NOVA_USB_SYSROOT/etc"
  printf 'KEYMAP=es\nXKBLAYOUT=es\n' >"$NOVA_USB_SYSROOT/etc/vconsole.conf"
  [ "$(console_keymap)" = es ]
  printf 'FONT=ter-v16n\nKEYMAP="de-latin1"\n' >"$NOVA_USB_SYSROOT/etc/vconsole.conf"
  [ "$(console_keymap)" = de-latin1 ]
  printf 'KEYMAP=$(reboot)\n' >"$NOVA_USB_SYSROOT/etc/vconsole.conf"
  run console_keymap
  [ "$status" -eq 0 ] && [ -z "$output" ]
}

@test "the installer partition: the ISO, the packages, and room to spare" {
  [ "$(installer_mib $((1200 * MiB)) 0)" = 1388 ]
  [ "$(installer_mib $((1200 * MiB)) $((2000 * MiB)))" = 3488 ]
}

@test "machine_hash: nova usb and the installer agree on a computer" {
  mkdir -p "$NOVA_DMI_PATH"
  echo 4c4c4544-0042 >"$NOVA_DMI_PATH/product_uuid"
  echo PF3ABCDE >"$NOVA_DMI_PATH/product_serial"
  usb=$(machine_hash)
  installer=$(bash -c 'source "$1"; machine_hash' _ "$REPO_ROOT/installer/nova-install")
  [ -n "$usb" ]
  [ "$usb" = "$installer" ]
  rm "$NOVA_DMI_PATH"/*
  [ -z "$(machine_hash)" ]
}

# ------------------------------------------------------------ the wizard

# A wizard ready to run: one 32 GB stick, an ISO, no packages on the stick.
wizard_setup() {
  ISO=$SCRATCH/nova.iso RELEASE_DIR=$SCRATCH NO_OFFLINE="not in this test" DRY=1
  head -c 1000 /dev/zero >"$ISO"
  mkdir -p "$NOVA_USB_HOME/.ssh"
  echo key >"$NOVA_USB_HOME/.ssh/id_ed25519"
  stick_candidates() { printf '/dev/sdx\t%s\tCruzer\tS1\n' "$((32 * GB))"; }
  disk_contents() { echo 'sdx1  28G  exfat  "old"'; }
  mounted_partitions() { :; }
  console_keymap() { echo es; }
  UI_NOTES=$SCRATCH/notes
  # The summary checks the writer's tools are there; where this machine lacks
  # one (CI has no cryptsetup), a stand-in at the end of PATH answers for it.
  local tool
  mkdir -p "$SCRATCH/writer-bin"
  for tool in sudo sfdisk wipefs mkfs.fat tar zstd diff cryptsetup mkfs.btrfs repo-add; do
    printf '#!/bin/sh\nexit 0\n' >"$SCRATCH/writer-bin/$tool"
    chmod +x "$SCRATCH/writer-bin/$tool"
  done
  PATH=$PATH:$SCRATCH/writer-bin
}

@test "wizard: Custom with what is ticked, a passphrase, and the plan for the writer" {
  wizard_setup
  mkdir -p "$NOVA_USB_HOME/Documents"
  echo hi >"$NOVA_USB_HOME/Documents/a.txt"
  echo todo >"$NOVA_USB_HOME/todo.txt"
  stub_gum 0 custom 'item:ssh\npath:Documents\npath:todo.txt' secret-pass secret-pass
  wizard 2>"$SCRATCH/screens"
  [ "$(gum_replies_left)" = 0 ]
  [ "${ITEMS[*]}" = "ssh files" ]
  [ "${CARRIED[*]}" = "ssh files" ]
  [ "$PASSPHRASE" = secret-pass ]
  [ "$(tr '\0' ' ' <"$PLAN/files.list")" = "Documents todo.txt " ]
  [ "$(plan_value "$PLAN" device)" = /dev/sdx ]
  [ "$(plan_value "$PLAN" items)" = "ssh files" ]
  [ "$(plan_value "$PLAN" keymap)" = es ]
  [ "$(plan_value "$PLAN" offline)" = 0 ]
  # The stick's list shows what is on each; the summary what is erased and
  # brought, the files by name.
  grep -q -- 'sdx  32.0 GB  Cruzer  ·  sdx1  28G  exfat  "old"' "$GUM_LOG"
  grep -q 'Erased     sdx  32.0 GB  Cruzer' "$SCRATCH/screens"
  grep -q 'now holds sdx1' "$SCRATCH/screens"
  grep -Eq 'SSH keys +[0-9]+ B' "$SCRATCH/screens"
  grep -Eq 'Files and folders +[0-9]+ B' "$SCRATCH/screens"
  grep -qx ' *~/Documents' "$SCRATCH/screens"
  grep -qx ' *~/todo.txt' "$SCRATCH/screens"
}

@test "wizard: the summary names the first few files, then how many more" {
  wizard_setup
  local i
  for i in 1 2 3 4 5 6 7; do echo "$i" >"$NOVA_USB_HOME/file$i.txt"; done
  stub_gum 0 custom 'path:file1.txt\npath:file2.txt\npath:file3.txt\npath:file4.txt\npath:file5.txt\npath:file6.txt\npath:file7.txt' pass-word pass-word
  wizard 2>"$SCRATCH/screens"
  [ "${CARRIED[*]}" = files ]
  grep -qx ' *~/file5.txt' "$SCRATCH/screens"
  fails grep -q 'file6.txt' "$SCRATCH/screens"
  grep -qx ' *and 2 more' "$SCRATCH/screens"
}

@test "wizard: the checklist has the SSH keys ticked, and the top of the home with sizes" {
  wizard_setup
  mkdir -p "$NOVA_USB_HOME/Documents" "$NOVA_USB_HOME/.config"
  head -c 3000 /dev/zero >"$NOVA_USB_HOME/Documents/a"
  echo rc >"$NOVA_USB_HOME/.bashrc"
  echo odd >"$NOVA_USB_HOME/one, two"
  stub_gum 0 custom '!1' '!1' '!1'
  run wizard
  [ "$status" -eq 1 ]
  grep -q -- '--selected SSH keys .*[0-9] B ' "$GUM_LOG"
  grep -Eq 'Documents/ +3 KB'$'\t''path:Documents' "$GUM_LOG"
  # gum splits its selection on commas, so a label has none; the value keeps it.
  grep -Eq 'one  two +[0-9]+ B'$'\t''path:one, two' "$GUM_LOG"
  grep -q $'Something further in, typed by hand\tother' "$GUM_LOG"
  fails grep -q 'path:\.' "$GUM_LOG"
}

@test "wizard: something further in is typed, and Esc there goes back to the checklist as it was" {
  wizard_setup
  mkdir -p "$NOVA_USB_HOME/Projects/app/src" "$NOVA_USB_HOME/Music"
  echo main >"$NOVA_USB_HOME/Projects/app/src/main.rs"
  # SSH keys unticked, Music and something further in ticked; Esc on the
  # typing; Enter on the checklist again; then the path.
  stub_gum 0 custom 'path:Music\nother' '!1' 'path:Music\nother' 'Projects/app, nowhere' pass-word pass-word
  wizard 2>"$SCRATCH/screens"
  [ "$(gum_replies_left)" = 0 ]
  [ "${CARRIED[*]}" = files ]
  [ "$(tr '\0' ' ' <"$PLAN/files.list")" = "Music Projects/app " ]
  grep -q 'Nothing called nowhere in your home' "$SCRATCH/screens"
  # The second checklist kept Music ticked and the SSH keys not.
  [ "$(grep -c -- '--selected Music/' "$GUM_LOG")" = 1 ]
  fails grep -q -- '--selected SSH keys' <(grep -- '--selected Music/' "$GUM_LOG")
  # The home was measured once.
  [ "$(grep -c 'Measuring what is in your home' "$SCRATCH/screens")" = 1 ]
}

@test "wizard: Esc goes back a question, and on the first one stops" {
  wizard_setup
  # stick, mode Custom, Esc on the checklist, then Clean instead.
  stub_gum 0 custom '!1' clean
  wizard 2>/dev/null
  [ "$MODE" = clean ]
  [ "${#CARRIED[@]}" = 0 ]
  [ "$(grep -c '^choose .*What goes on the stick' "$GUM_LOG")" = 2 ]
  # Clean asks for no passphrase.
  fails grep -q -- --password "$GUM_LOG"
  stub_gum '!1'
  run wizard
  [ "$status" -eq 1 ]
  [[ $output == *"nothing was written"* ]]
}

@test "wizard: Ctrl+C stops anywhere, with nothing written" {
  wizard_setup
  stub_gum 0 custom '!130'
  run wizard
  [ "$status" -eq 130 ]
  [[ $output == *"nova usb stopped; nothing was written."* ]]
  [ ! -e "$PLAN/plan.env" ]
}

@test "wizard: the stick's name is typed back before anything is written" {
  wizard_setup
  DRY=0
  stub_gum 0 clean sdy sdx
  wizard 2>"$SCRATCH/screens"
  grep -q 'That is not sdx' "$SCRATCH/screens"
  [ "$(gum_replies_left)" = 0 ]
  # Esc there goes back to the question before.
  MODE='' STICK=''
  stub_gum 0 clean '!1' '!1' '!1'
  run wizard
  [ "$status" -eq 1 ]
  [ "$(grep -c '^choose .*What goes on the stick' "$GUM_LOG")" = 2 ]
}

@test "wizard: what does not fit is not written" {
  wizard_setup
  stick_candidates() { printf '/dev/sdx\t%s\tCruzer\tS1\n' "$((3 * GB))"; }
  installer_mib() { echo 2900; }
  stub_gum 0 custom item:ssh pass-word pass-word '!1'
  run wizard
  [ "$status" -eq 1 ]
  [[ $output == *"That is more than the stick holds."* ]]
  [[ $output == *"it does not fit on the stick; nothing was written."* ]]
}

@test "the nova-usb on a release page carries its look and wordmark inside" {
  "$REPO_ROOT/tools/inline-ui" >"$SCRATCH/nova-usb"
  bash -n "$SCRATCH/nova-usb"
  fails grep -q '^source ' "$SCRATCH/nova-usb"
  run bash -c 'source "$1"; ui_wordmark; declare -F ui_choose ui_box step_stick' _ "$SCRATCH/nova-usb"
  [ "$status" -eq 0 ]
  [ "${lines[3]}" = "$(sed -n 4p "$REPO_ROOT/theme/wordmark/nova.txt")" ]
  [[ $output == *ui_choose*ui_box*step_stick* ]]
  run bash "$SCRATCH/nova-usb" --help
  [ "$status" -eq 0 ]
  [[ $output == *"nova usb --dry-run"* ]]
  # Nova's key too, to check the release's files with on a system without it.
  [ "$(NOVA_USB_KEY=/nonexistent bash -c 'source "$1"; release_key' _ "$SCRATCH/nova-usb")" = "$(cat "$REPO_ROOT/packaging/nova-keyring/nova.gpg")" ]
}

# GitHub with one release, v1.0.0, and its package repository at
# https://packages.example.org/v1.0.0, both serving $SCRATCH/served: the
# release page has release.toml and the ISO with its .sha256, the repository
# the rest. `serve_release page` puts it all on the page, as releases before
# 1.0.0-beta.6 did. Each file but the ISO is signed by the test's key, which
# stands in for Nova's.
serve_release() { # [page]
  test_key
  export NOVA_USB_KEY=$TEST_KEY
  local served=$SCRATCH/served name assets=''
  local page=(release.toml release.toml.sig nova-1.0.0-x86_64.iso nova-1.0.0-x86_64.iso.sha256)
  mkdir -p "$served"
  printf 'version = "1.0.0"\nnova_repo = "https://packages.example.org/v1.0.0"\n' >"$served/release.toml"
  echo nova >"$served/packages.txt"
  echo 'an ISO' >"$served/nova-1.0.0-x86_64.iso"
  (cd "$served" && sha256sum -- nova-1.0.0-x86_64.iso >nova-1.0.0-x86_64.iso.sha256)
  for name in release.toml packages.txt nova-1.0.0-x86_64.iso.sha256; do test_sign "$served/$name"; done
  [[ ${1:-} != page ]] || page=("$served"/*)
  for name in "${page[@]}"; do
    name=${name##*/}
    assets+="${assets:+,}{\"name\":\"$name\",\"size\":7,\"browser_download_url\":\"https://dl.example.org/$name\"}"
  done
  echo "[{\"tag_name\":\"v1.0.0\",\"draft\":false,\"prerelease\":false,\"assets\":[$assets]}]" >"$SCRATCH/releases.json"
  curl() {
    local url=${*: -1} out='' prev='' arg
    for arg; do [[ $prev != -o ]] || out=$arg; prev=$arg; done
    case $url in
      *'?per_page='*) cat "$SCRATCH/releases.json" ;;
      https://dl.example.org/* | https://packages.example.org/v1.0.0/*)
        echo "$url" >>"$SCRATCH/downloaded"
        [[ -e $SCRATCH/served/${url##*/} ]] && cp -- "$SCRATCH/served/${url##*/}" "$out"
        ;;
      *) return 22 ;;
    esac
  }
}

@test "fetch_release: the release's files are Nova's, and the ISO matches its checksum" {
  serve_release
  run fetch_release
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "$NOVA_USB_CACHE/v1.0.0/nova-1.0.0-x86_64.iso" ]
  [ "$(cat "$NOVA_USB_CACHE/v1.0.0/nova-1.0.0-x86_64.iso")" = 'an ISO' ]
  [ -s "$NOVA_USB_CACHE/v1.0.0/packages.txt" ]
  # The page for release.toml and the ISO, the package repository for the rest.
  [ "$(paste -sd' ' "$SCRATCH/downloaded")" = "https://dl.example.org/release.toml https://dl.example.org/release.toml.sig \
https://packages.example.org/v1.0.0/packages.txt https://packages.example.org/v1.0.0/packages.txt.sig \
https://packages.example.org/v1.0.0/nova-1.0.0-x86_64.iso.sha256 https://packages.example.org/v1.0.0/nova-1.0.0-x86_64.iso.sha256.sig \
https://dl.example.org/nova-1.0.0-x86_64.iso" ]
}

@test "fetch_release_files: a selected release gets the same signature and ISO checks" {
  serve_release
  release=$(jq -c '.[0]' "$SCRATCH/releases.json")
  run fetch_release_files "$release"
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "$NOVA_USB_CACHE/v1.0.0/nova-1.0.0-x86_64.iso" ]
  rm -rf "$NOVA_USB_CACHE"
  echo changed >>"$SCRATCH/served/release.toml"
  run fetch_release_files "$release"
  [ "$status" -ne 0 ]
  [[ $output == *"release.toml is not signed by Nova's key"* ]]
}

@test "fetch_release: a release from before beta.6, with everything on its page, still works" {
  serve_release page
  run fetch_release
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "$NOVA_USB_CACHE/v1.0.0/nova-1.0.0-x86_64.iso" ]
  [ -s "$NOVA_USB_CACHE/v1.0.0/packages.txt" ]
  fails grep -q packages.example.org "$SCRATCH/downloaded"
}

@test "fetch_release: without the package list, the stick is made without offline packages" {
  serve_release
  rm "$SCRATCH/served/packages.txt"
  run fetch_release
  [ "$status" -eq 0 ]
  [ ! -e "$NOVA_USB_CACHE/v1.0.0/packages.txt" ]
  [ "${lines[-1]}" = "$NOVA_USB_CACHE/v1.0.0/nova-1.0.0-x86_64.iso" ]
}

@test "fetch_release: a file changed after it was signed stops it before the ISO" {
  serve_release
  sed -i 's/^[0-9a-f]*/0000/' "$SCRATCH/served/nova-1.0.0-x86_64.iso.sha256"
  run fetch_release
  [ "$status" -ne 0 ]
  [[ $output == *"nova-1.0.0-x86_64.iso.sha256 is not signed by Nova's key"* ]]
  [ ! -e "$NOVA_USB_CACHE/v1.0.0/nova-1.0.0-x86_64.iso.sha256" ]
  fails grep -q '/nova-1.0.0-x86_64.iso$' "$SCRATCH/downloaded"
}

@test "fetch_release: a release whose files are not signed is not used" {
  serve_release
  rm "$SCRATCH/served/release.toml.sig"
  sed -i 's/,{"name":"release.toml.sig"[^}]*}//; s/{"name":"release.toml.sig"[^}]*},//' "$SCRATCH/releases.json"
  run fetch_release
  [ "$status" -ne 0 ]
  [[ $output == *"has no release.toml.sig"* ]]
  [ ! -e "$SCRATCH/downloaded" ]
}

@test "fetch_release: a signature by some other key is refused" {
  serve_release
  export NOVA_USB_KEY=$SCRATCH/other-key.asc
  GNUPGHOME=$SCRATCH/gnupg-other
  mkdir -m 700 "$GNUPGHOME"
  gpg --batch --quiet --passphrase '' --quick-gen-key 'Other <other@example.org>' ed25519 sign never 2>/dev/null
  gpg --batch --armor --export >"$NOVA_USB_KEY"
  gpgconf --kill all
  run fetch_release
  [ "$status" -ne 0 ]
  [[ $output == *"release.toml is not signed by Nova's key"* ]]
}

@test "local_timezone: this computer's zone, for the installer to offer first" {
  mkdir -p "$NOVA_USB_SYSROOT/etc"
  ln -s /usr/share/zoneinfo/Europe/Rome "$NOVA_USB_SYSROOT/etc/localtime"
  [ "$(local_timezone)" = Europe/Rome ]
  rm "$NOVA_USB_SYSROOT/etc/localtime"
  [ "$(local_timezone)" = "" ]
}
