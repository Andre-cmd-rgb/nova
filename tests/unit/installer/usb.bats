#!/usr/bin/env bats

load ../test_helper

setup() {
  setup_scratch
  export NOVA_USB_HOME="$SCRATCH/home"
  export NOVA_USB_PRESET="$SCRATCH/config/usb.toml"
  export NOVA_USB_CACHE="$SCRATCH/cache"
  export NOVA_USB_SYSROOT="$SCRATCH/sys"
  export NOVA_USB_OLD_PACKAGE_LISTS="$SCRATCH/old"
  export NOVA_DMI_PATH="$SCRATCH/dmi"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  mkdir -p "$NOVA_USB_HOME" "$NOVA_USB_SYSROOT" "$SCRATCH/plan"
  PLAN=$SCRATCH/plan
  # shellcheck source=/dev/null
  source "$REPO_ROOT/installer/nova-usb"
}

teardown() { teardown_scratch; }

fails() { if "$@"; then return 1; fi; }

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

repo() { # home-relative dir
  git -C "$NOVA_USB_HOME" init -q "$1"
}

# The member names of an archive the writer made, sorted.
members() { zstd -dc "$1" | tar -t | sed 's,/$,,' | sort; }

@test "catalog: unique ids, known kinds, and the defaults are in it" {
  [ "$(catalog | cut -f1 | sort | uniq -d)" = "" ]
  [ "$(catalog | cut -f3 | sort -u | tr '\n' ' ')" = "folders home list projects system " ]
  for id in "${DEFAULT_ITEMS[@]}"; do valid_item "$id"; done
  fails valid_item nonsense
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
  findmnt() { echo "${@: -1}" >>"$SCRATCH/asked"; }
  swapon() { :; }
  system_disks
  [ "$(paste -sd' ' "$SCRATCH/asked")" = "/ /boot /efi /boot/efi /home" ]
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

@test "home_relative: folders inside the home only" {
  mkdir -p "$NOVA_USB_HOME/Projects/Coding" "$SCRATCH/elsewhere"
  [ "$(home_relative Projects)" = Projects ]
  [ "$(home_relative "$NOVA_USB_HOME/Projects/Coding/")" = Projects/Coding ]
  [ "$(home_relative "~/Projects")" = Projects ]
  fails home_relative "$SCRATCH/elsewhere"
  fails home_relative Missing
  fails home_relative ../elsewhere
  fails home_relative "$NOVA_USB_HOME"
}

@test "projects: what git tracks and would track, the history, and nothing ignored" {
  repo Projects/app
  cd "$NOVA_USB_HOME/Projects/app"
  printf 'target/\n' >.gitignore
  mkdir -p src target node_modules/dep
  echo main >src/main.rs
  echo gone >gone.txt
  echo build >target/out
  echo dep >node_modules/dep/index.js
  echo '-n' >-n
  git add .gitignore src/main.rs gone.txt -- -n
  rm gone.txt
  echo new >notes.md
  # A repository of its own inside it, and one hidden in node_modules.
  repo Projects/app/vendor/lib
  echo lib >vendor/lib/lib.c
  repo Projects/app/node_modules/dep
  cd "$BATS_TEST_DIRNAME"
  PROJECT_DIRS=(Projects)
  list_projects "$PLAN"
  [ "$(tr '\0' '\n' <"$PLAN/projects.files" | LC_ALL=C sort | tr '\n' ' ')" = "Projects/app/-n Projects/app/.gitignore Projects/app/notes.md Projects/app/src/main.rs Projects/app/vendor/lib/lib.c " ]
  [ "$(tr '\0' '\n' <"$PLAN/projects.gitdirs" | tr '\n' ' ')" = "Projects/app/.git Projects/app/vendor/lib/.git " ]
  make_archive projects "$PLAN" "$NOVA_USB_HOME" "$SCRATCH/projects.tar.zst"
  run members "$SCRATCH/projects.tar.zst"
  [[ $output == *"Projects/app/-n"* && $output == *"Projects/app/.git/HEAD"* && $output == *"Projects/app/vendor/lib/.git/HEAD"* ]]
  [[ $output != *target* && $output != *gone.txt* && $output != *node_modules* ]]
}

@test "projects: a deleted file listed last, or a repository git cannot read, is no failure" {
  repo Projects/app
  cd "$NOVA_USB_HOME/Projects/app"
  echo a >a.txt
  echo z >z.txt
  git add a.txt z.txt
  rm z.txt
  mkdir -p "$NOVA_USB_HOME/Projects/broken/.git"
  cd "$BATS_TEST_DIRNAME"
  run repo_files Projects/app
  [ "$status" -eq 0 ]
  [ "$(tr '\0' '\n' <<<"$output")" = "Projects/app/a.txt" ]
  run repo_files Projects/broken
  [ "$status" -eq 0 ]
  [[ $output == *"git could not read ~/Projects/broken"* ]]
}

@test "preset: what Custom chose comes back, folders with odd names included" {
  mkdir -p "$NOVA_USB_HOME/My \"Stuff\", old" "$NOVA_USB_HOME/Projects"
  PROJECT_DIRS=(Projects) FOLDER_DIRS=('My "Stuff", old')
  write_preset "ssh chrome folders projects" 1
  ITEMS=() PROJECT_DIRS=() FOLDER_DIRS=() OFFLINE=0
  read_preset
  [ "${ITEMS[*]}" = "ssh chrome folders projects" ]
  [ "${PROJECT_DIRS[*]}" = Projects ]
  [ "${FOLDER_DIRS[0]}" = 'My "Stuff", old' ]
  [ "$OFFLINE" = 1 ]
}

@test "preset: an unknown item or a folder that is gone is dropped, with a word" {
  mkdir -p "$(dirname "$NOVA_USB_PRESET")"
  printf '%s\n' 'items = ["ssh", "teleporter"]' 'projects = ["Gone"]' 'folders = []' 'offline = false' >"$NOVA_USB_PRESET"
  read_preset 2>"$SCRATCH/err"
  [ "${ITEMS[*]}" = ssh ]
  [ "${#PROJECT_DIRS[@]}" = 0 ]
  [ "$OFFLINE" = 0 ]
  grep -q teleporter "$SCRATCH/err"
  grep -q Gone "$SCRATCH/err"
}

@test "preset: none saved yet" {
  fails read_preset
}

@test "packages: what you added, without what the old system came with or the hardware decides" {
  mkdir -p "$NOVA_USB_OLD_PACKAGE_LISTS"
  printf '%s\n' '# base' hyprland waybar >"$NOVA_USB_OLD_PACKAGE_LISTS/omarchy-base.packages"
  pacman() {
    case $1 in
      -Qqen) printf '%s\n' base hyprland waybar kicad linux linux-headers intel-ucode nvidia-open steam omarchy-keyring ;;
      -Qqem) printf '%s\n' google-chrome yay spotify ;;
    esac
  }
  list_packages "$PLAN"
  [ "$(tr '\n' ' ' <"$PLAN/packages.txt")" = "kicad steam " ]
  [ "$(tr '\n' ' ' <"$PLAN/aur.txt")" = "spotify yay " ]
}

@test "archives: Chrome without its caches or the locks of a running browser" {
  local profile=$NOVA_USB_HOME/.config/google-chrome
  mkdir -p "$profile/Default/Cache" "$profile/Default/Code Cache/js" "$profile/Default/Service Worker/CacheStorage" \
    "$profile/Default/Service Worker/Database" "$NOVA_USB_HOME/.local/share/keyrings"
  echo cookies >"$profile/Default/Cookies"
  echo junk >"$profile/Default/Cache/data_0"
  echo js >"$profile/Default/Code Cache/js/x"
  echo sw >"$profile/Default/Service Worker/CacheStorage/y"
  echo db >"$profile/Default/Service Worker/Database/z"
  ln -s host-123 "$profile/SingletonLock"
  echo secret >"$NOVA_USB_HOME/.local/share/keyrings/Default_keyring.keyring"
  make_archive chrome "$PLAN" "$NOVA_USB_HOME" "$SCRATCH/chrome.tar.zst"
  run members "$SCRATCH/chrome.tar.zst"
  [[ $output == *"Default/Cookies"* && $output == *"Service Worker/Database/z"* && $output == *"keyrings/Default_keyring.keyring"* ]]
  [[ $output != *Cache/data_0* && $output != *"Code Cache"* && $output != *CacheStorage* && $output != *SingletonLock* ]]
}

@test "archives: Omarchy's history and bar layout are renamed to Nova's on the way in" {
  mkdir -p "$NOVA_USB_HOME/.local/state/omarchy-screentime/days" "$NOVA_USB_HOME/.config/omarchy"
  echo 1 >"$NOVA_USB_HOME/.local/state/omarchy-screentime/days/2026-10-19.tsv"
  echo '{}' >"$NOVA_USB_HOME/.config/omarchy/shell.json"
  make_archive history "$PLAN" "$NOVA_USB_HOME" "$SCRATCH/history.tar.zst"
  make_archive bar "$PLAN" "$NOVA_USB_HOME" "$SCRATCH/bar.tar.zst"
  members "$SCRATCH/history.tar.zst" | grep -qx '.local/state/nova-screentime/days/2026-10-19.tsv'
  [ "$(members "$SCRATCH/bar.tar.zst")" = .config/nova/shell.json ]
}

@test "archives: system items come from the root, and an item with nothing here is skipped" {
  mkdir -p "$NOVA_USB_SYSROOT/etc/NetworkManager/system-connections"
  echo '[connection]' >"$NOVA_USB_SYSROOT/etc/NetworkManager/system-connections/Home.nmconnection"
  make_archive wifi "$PLAN" "$NOVA_USB_HOME" "$SCRATCH/wifi.tar.zst"
  members "$SCRATCH/wifi.tar.zst" | grep -qx 'etc/NetworkManager/system-connections/Home.nmconnection'
  run make_archive gnupg "$PLAN" "$NOVA_USB_HOME" "$SCRATCH/gnupg.tar.zst"
  [ "$status" -eq 2 ]
  item_present wifi "$PLAN"
  fails item_present gnupg "$PLAN"
}

@test "packages on the stick: names FAT can hold, each with its signature" {
  printf 'https://archive.archlinux.org/repos/2026/10/01/extra/os/x86_64/ffmpeg-2:7.1-1-x86_64.pkg.tar.zst\t100\n' >"$PLAN/offline.urls"
  printf 'https://github.com/Andre-cmd-rgb/nova/releases/download/v1.0.0/nova-1.0.0-1-any.pkg.tar.zst\t50\n' >>"$PLAN/offline.urls"
  printf 'https://example.org/repo/libc%%2B%%2B-1-1-x86_64.pkg.tar.zst\t10\n' >>"$PLAN/offline.urls"
  curl() { cp -- "${@: -1}" "$SCRATCH/curl.config"; }
  download_packages "$PLAN/offline.urls" /stick/repo
  grep -qx 'output = "/stick/repo/ffmpeg-2_7.1-1-x86_64.pkg.tar.zst"' "$SCRATCH/curl.config"
  grep -qx 'output = "/stick/repo/ffmpeg-2_7.1-1-x86_64.pkg.tar.zst.sig"' "$SCRATCH/curl.config"
  grep -qx 'url = "https://archive.archlinux.org/repos/2026/10/01/extra/os/x86_64/ffmpeg-2:7.1-1-x86_64.pkg.tar.zst.sig"' "$SCRATCH/curl.config"
  grep -qx 'output = "/stick/repo/nova-1.0.0-1-any.pkg.tar.zst"' "$SCRATCH/curl.config"
  grep -qx 'output = "/stick/repo/libc++-1-1-x86_64.pkg.tar.zst"' "$SCRATCH/curl.config"
}

@test "packages on the stick: fetched from the release's own snapshot and repository" {
  printf 'version = "1.0.0"\narch_date = "2026/10/01"\nnova_repo = "https://github.com/Andre-cmd-rgb/nova/releases/download/v1.0.0"\n' >"$SCRATCH/release.toml"
  run offline_pacman_conf "$SCRATCH/release.toml"
  [[ $output == *'Server = https://archive.archlinux.org/repos/2026/10/01/$repo/os/$arch'* ]]
  [[ $output == *'Server = https://github.com/Andre-cmd-rgb/nova/releases/download/v1.0.0'* ]]
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
