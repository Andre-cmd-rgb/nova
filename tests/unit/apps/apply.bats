#!/usr/bin/env bats

# nova-apps-apply, the root half of an install from Arch's repositories,
# in a scratch root (NOVA_ROOT) with pacman stubbed: what it installs and
# removes, and each thing it refuses, above all a partial upgrade.

load ../test_helper

APPLY=$REPO_ROOT/src/apps/bin/nova-apps-apply

setup() {
  setup_scratch
  # As root the script drops NOVA_ROOT and works on this computer itself.
  ((EUID != 0)) || skip "run the tests as an ordinary account"
  export CALLS="$SCRATCH/calls" NOVA_ROOT="$SCRATCH/root"
  mkdir -p "$SCRATCH/bin" "$NOVA_ROOT/usr/share/swcatalog/xml" "$NOVA_ROOT/var/lib/pacman/sync" "$NOVA_ROOT/etc/pacman.d"
  : >"$CALLS"
  printf '<components>\n<component type="desktop-application"><id>org.gimp.GIMP</id><pkgname>gimp</pkgname></component>\n</components>\n' |
    gzip >"$NOVA_ROOT/usr/share/swcatalog/xml/extra.xml.gz"
  touch "$NOVA_ROOT/var/lib/pacman/sync/core.db" "$NOVA_ROOT/var/lib/pacman/sync/extra.db"
  touch "$NOVA_ROOT/etc/pacman.d/nova-mirrorlist" "$NOVA_ROOT/etc/pacman.d/nova-repo"
  # pacman as a system with gimp in its repositories and firefox installed,
  # an app; nothing behind unless $SCRATCH/behind says what.
  cat >"$SCRATCH/bin/pacman" <<'EOF'
#!/bin/bash
echo "pacman $*" >>"$CALLS"
case $1 in
  -Si) [[ $3 == gimp ]] ;;
  -Qu) cat "$SCRATCH/behind" 2>/dev/null; exit 0 ;;
  -Q) [[ $3 == firefox || $3 == bigapp || $3 == nova-keyring || $3 == foot || $3 == libfoo ]] ;;
  -Qlq) [[ $3 == bigapp ]] && { echo /usr/share/applications/bigapp.desktop; exec seq 1 300000; }
    [[ $3 == libfoo ]] || echo "/usr/share/applications/$3.desktop" ;;
  -Qi) printf 'Name            : nova\nDepends On      : nova-keyring  hyprland  foot>=1.0\n                  quickshell\nOptional Deps   : None\n' ;;
  *) exit 0 ;;
esac
EOF
  # The real nova-hw-packages, on a computer of the test's own with no
  # display controller (graphics_machine gives it one).
  mkdir -p "$SCRATCH/pci"
  printf 'vendor_id\t: GenuineIntel\n' >"$SCRATCH/cpuinfo"
  export NOVA_HW_PACKAGES=$REPO_ROOT/data/hardware/bin/nova-hw-packages
  export NOVA_PCI_DEVICES_PATH=$SCRATCH/pci NOVA_CPUINFO=$SCRATCH/cpuinfo
  printf '#!/bin/bash\nprintf "%%s\\n" core extra\n' >"$SCRATCH/bin/pacman-conf"
  chmod +x "$SCRATCH/bin/pacman" "$SCRATCH/bin/pacman-conf"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

@test "install: an app of Arch's catalog, from the lists there are, nothing else upgraded" {
  run "$APPLY" install gimp
  [ "$status" -eq 0 ]
  grep -qx 'pacman -S --needed --noconfirm -- gimp' "$CALLS"
  fails grep -q -- '-Sy' "$CALLS"
  fails grep -q -- '-Su' "$CALLS"
}

@test "install: the lists read first where one is missing, as on a new install" {
  rm "$NOVA_ROOT/var/lib/pacman/sync/extra.db"
  run "$APPLY" install gimp
  [ "$status" -eq 0 ]
  [ "$(grep -n 'pacman -Sy --noconfirm' "$CALLS" | cut -d: -f1)" -lt "$(grep -n 'pacman -S --needed' "$CALLS" | cut -d: -f1)" ]
}

@test "install: refused while the packages are behind their lists, which is an update not finished" {
  printf 'glibc 2.41-1 -> 2.42-1\nlinux 7.2-1 -> 7.3-1 [ignored]\n' >"$SCRATCH/behind"
  run "$APPLY" install gimp
  [ "$status" -eq 3 ]
  [[ $output == *"this computer's packages are older than its package lists (glibc): update Nova first, in Settings, Updates"* ]]
  fails grep -q 'pacman -S --needed' "$CALLS"
}

@test "install: one held back by the owner does not count" {
  printf 'linux 7.2-1 -> 7.3-1 [ignored]\n' >"$SCRATCH/behind"
  run "$APPLY" install gimp
  [ "$status" -eq 0 ]
}

# The other root helper that installs from the pinned lists, nova update's
# repair (nova-update-apply --repair), keeps a copy of the same guard: both
# refuse the same packages behind their lists, and let the same held ones by.
@test "nova update's repair refuses what an install refuses, and passes what it passes" {
  mkdir -p "$SCRATCH/lib"
  cp "$REPO_ROOT/src/cli/bin/nova-update-apply" "$SCRATCH/lib/"
  printf '#!/bin/bash\nexit 1\n' >"$SCRATCH/lib/nova-hw-detect"
  chmod +x "$SCRATCH/lib/nova-hw-detect"
  printf 'glibc 2.41-1 -> 2.42-1\nlinux 7.2-1 -> 7.3-1 [ignored]\n' >"$SCRATCH/behind"
  run "$APPLY" install gimp
  [ "$status" -eq 3 ]
  [[ $output == *"this computer's packages are older than its package lists (glibc)"* ]]
  run "$SCRATCH/lib/nova-update-apply" --repair --noconfirm
  [ "$status" -eq 1 ]
  [[ $output == *"this computer's packages are older than its package lists (glibc)"* ]]
  fails grep -qE '^pacman -(S|U|Rns) ' "$CALLS"
  printf 'linux 7.2-1 -> 7.3-1 [ignored]\n' >"$SCRATCH/behind"
  run "$APPLY" install gimp
  [ "$status" -eq 0 ]
  run "$SCRATCH/lib/nova-update-apply" --repair --noconfirm
  [ "$status" -eq 0 ]
}

@test "install: refused after an update that stopped halfway" {
  touch "$NOVA_ROOT/etc/pacman.d/nova-mirrorlist.nova-prev"
  run "$APPLY" install gimp
  [ "$status" -eq 3 ]
  [[ $output == *"the last update did not finish"* ]]
}

@test "install: only an app, and only one in the release's repositories" {
  run "$APPLY" install openssl
  [ "$status" -eq 1 ]
  [[ $output == *"openssl is not an app in Arch's catalog"* ]]
  printf '<pkgname>gone</pkgname>\n' | gzip >"$NOVA_ROOT/usr/share/swcatalog/xml/core.xml.gz"
  run "$APPLY" install gone
  [ "$status" -eq 1 ]
  [[ $output == *"gone is not in the release's repositories"* ]]
}

@test "remove: an app, and what it alone needed" {
  run "$APPLY" remove firefox
  [ "$status" -eq 0 ]
  grep -qx 'pacman -Rns --noconfirm -- firefox' "$CALLS"
}

@test "remove: an app with more files than grep reads before it is satisfied is still one" {
  run "$APPLY" remove bigapp
  [ "$status" -eq 0 ]
  grep -qx 'pacman -Rns --noconfirm -- bigapp' "$CALLS"
}

@test "remove: never Nova, what Nova needs, a library, or one not installed" {
  run "$APPLY" remove nova-keyring
  [ "$status" -eq 1 ]
  [[ $output == *"nova-keyring is part of Nova"* ]]
  run "$APPLY" remove foot
  [ "$status" -eq 1 ]
  [[ $output == *"foot is part of Nova"* ]]
  run "$APPLY" remove libfoo
  [ "$status" -eq 1 ]
  [[ $output == *"libfoo is not an app"* ]]
  run "$APPLY" remove gimp
  [ "$status" -eq 1 ]
  [[ $output == *"gimp is not installed"* ]]
  fails grep -q -- '-R' "$CALLS"
}

@test "an update or another install under way: try again later" {
  mkdir -p "$NOVA_ROOT/run"
  exec {held}>"$NOVA_ROOT/run/nova-update.lock"
  flock "$held"
  run "$APPLY" install gimp
  exec {held}>&-
  [ "$status" -eq 75 ]
  [[ $output == *"try again once it is done"* ]]
}

@test "a built package goes to nova-update-apply, the lock let go first" {
  printf '#!/bin/bash\nflock -n %s/run/nova-update.lock true && echo "apply $*" >>"$CALLS"\n' "$NOVA_ROOT" >"$SCRATCH/update-apply"
  chmod +x "$SCRATCH/update-apply"
  NOVA_UPDATE_APPLY=$SCRATCH/update-apply run "$APPLY" built /var/cache/nova/google-chrome.pkg.tar.zst
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "apply --packages-only --package /var/cache/nova/google-chrome.pkg.tar.zst" ]
}

@test "arguments that are not a package's name" {
  run "$APPLY" install --overwrite=*
  [ "$status" -eq 2 ]
  run "$APPLY" install 'gimp foo'
  [ "$status" -eq 2 ]
  run "$APPLY" upgrade gimp
  [ "$status" -eq 2 ]
}

# An app whose install needs a Vulkan driver, on a bus of the test's own:
# pacman -Sp says what the app would bring in ($SCRATCH/brought), -Q what is
# installed ($INSTALLED), and the real nova-hw-packages reads the bus.
graphics_machine() { # class:vendor:device...
  local i=0 dev class vendor device
  mkdir -p "$SCRATCH/pci"
  for dev; do
    IFS=: read -r class vendor device <<<"$dev"
    mkdir -p "$SCRATCH/pci/0000:0$i:00.0"
    echo "$class" >"$SCRATCH/pci/0000:0$i:00.0/class"
    echo "$vendor" >"$SCRATCH/pci/0000:0$i:00.0/vendor"
    echo "$device" >"$SCRATCH/pci/0000:0$i:00.0/device"
    i=$((i + 1))
  done
  printf 'vendor_id\t: GenuineIntel\n' >"$SCRATCH/cpuinfo"
  export NOVA_PCI_DEVICES_PATH=$SCRATCH/pci NOVA_CPUINFO=$SCRATCH/cpuinfo
  export NOVA_HW_PACKAGES=$REPO_ROOT/data/hardware/bin/nova-hw-packages
  printf '<components><component><pkgname>steam</pkgname></component></components>\n' |
    gzip >"$NOVA_ROOT/usr/share/swcatalog/xml/multilib.xml.gz"
  cat >"$SCRATCH/bin/pacman" <<'STUB'
#!/bin/bash
echo "pacman $*" >>"$CALLS"
case $1 in
  -Si) exit 0 ;;
  -T) [[ $2 == NVIDIA-MODULE && -n ${NO_NVIDIA_MODULE:-} ]] && exit 127; exit 0 ;;
  -Sp) cat "$SCRATCH/brought" ;;
  -Qu) exit 0 ;;
  -Q) [[ " $INSTALLED " == *" $3 "* ]] ;;
  *) exit 0 ;;
esac
STUB
}

@test "install: Steam on an Intel laptop goes in with Intel's 32-bit drivers, which go with it" {
  graphics_machine 0x030000:0x8086:0x9a49
  printf '%s\n' steam lib32-glibc lib32-nvidia-utils nvidia-utils >"$SCRATCH/brought"
  INSTALLED="mesa vulkan-intel" run "$APPLY" install steam
  [ "$status" -eq 0 ]
  grep -qx 'pacman -S --needed --noconfirm -- steam mesa vulkan-intel lib32-mesa lib32-vulkan-intel' "$CALLS"
  grep -qx 'pacman -D --asdeps -- lib32-mesa lib32-vulkan-intel' "$CALLS"
  [[ $output == *"With this computer's graphics drivers: lib32-mesa lib32-vulkan-intel"* ]]
}

@test "install: on the P1, Intel's and NVIDIA's, for the client on one and a game on the other" {
  graphics_machine 0x030000:0x8086:0x9a60 0x030200:0x10de:0x25b8
  printf '%s\n' steam lib32-glibc lib32-nvidia-utils >"$SCRATCH/brought"
  INSTALLED="mesa vulkan-intel nvidia-utils lib32-mesa" run "$APPLY" install steam
  [ "$status" -eq 0 ]
  grep -qx 'pacman -S --needed --noconfirm -- steam mesa vulkan-intel nvidia-utils lib32-mesa lib32-vulkan-intel lib32-nvidia-utils' "$CALLS"
  grep -qx 'pacman -D --asdeps -- lib32-vulkan-intel lib32-nvidia-utils' "$CALLS"
}

@test "install: Steam on an NVIDIA card run on nouveau gets NVK, never the driver that blacklists nouveau" {
  graphics_machine 0x030000:0x10de:0x2786
  printf '%s\n' steam lib32-glibc lib32-nvidia-utils nvidia-utils >"$SCRATCH/brought"
  NO_NVIDIA_MODULE=1 INSTALLED="mesa" run "$APPLY" install steam
  [ "$status" -eq 0 ]
  grep -qx 'pacman -S --needed --noconfirm -- steam mesa vulkan-nouveau lib32-mesa lib32-vulkan-nouveau' "$CALLS"
}

@test "install: an app that needs no graphics driver gets none, and nothing is marked" {
  graphics_machine 0x030000:0x1002:0x73df
  printf '%s\n' gimp babl gegl >"$SCRATCH/brought"
  run "$APPLY" install gimp
  [ "$status" -eq 0 ]
  grep -qx 'pacman -S --needed --noconfirm -- gimp' "$CALLS"
  fails grep -q -- '-D' "$CALLS"
}

@test "install: as root nothing of the environment is read, not the root, not the helpers" {
  grep -q 'if ((EUID == 0)); then' "$APPLY"
  # The root branch reads no NOVA_ variable, and drops every one first, so
  # neither what it runs (nova-update-apply, pacman's hooks) reads one.
  run sed -n '/^if ((EUID == 0)); then$/,/^else$/p' "$APPLY"
  [[ $output != *'$NOVA_'* && $output != *'${NOVA_'* ]]
  [[ $output == *"ROOT=''"* ]]
  [[ $(sed -n 2p <<<"$output") == *"compgen -e -X '!NOVA_*'"*'unset'* ]]
  # And the hardware helper runs with an empty environment.
  grep -q 'env -i PATH=/usr/bin "$HW_PACKAGES"' "$APPLY"
}

# --- recipes -----------------------------------------------------------------
# The recipe file in the scratch root, as /usr/share/nova/apps/recipes, and a
# pacman that knows the packages in $REPO, has those in $INSTALLED
# (name:e asked for by name, name:d a dependency) and says who needs a
# package from $SCRATCH/required/<name>, and who may use it from
# $SCRATCH/optional/<name>; systemctl and gpasswd log (gpasswd never runs).
recipe_machine() { # recipe text
  mkdir -p "$NOVA_ROOT/usr/share/nova/apps" "$SCRATCH/required"
  printf '%s\n' "$1" >"$NOVA_ROOT/usr/share/nova/apps/recipes"
  printf '<components>%s</components>\n' "$(for p in $REPO; do printf '<component><pkgname>%s</pkgname></component>' "$p"; done)" |
    gzip >"$NOVA_ROOT/usr/share/swcatalog/xml/extra.xml.gz"
  cat >"$SCRATCH/bin/pacman" <<'STUB'
#!/bin/bash
echo "pacman $*" >>"$CALLS"
have() { local p; for p in $INSTALLED; do [[ ${p%:*} == "$1" && ( -z ${2:-} || ${p#*:} == "$2" ) ]] && return 0; done; return 1; }
case $1 in
  -Si) [[ " $REPO " == *" $3 "* ]] ;;
  -Sp | -Qu) exit 0 ;;
  -Rsp) cat "$SCRATCH/going" 2>/dev/null; exit 0 ;;
  -Q) have "$3" ;;
  -Qqd) have "$3" d && echo "$3"; exit 0 ;;
  -Qlq) echo "/usr/share/applications/$3.desktop" ;;
  -Qqo) [[ $3 == /usr/lib/systemd/system/libvirtd.socket ]] && echo libvirt ;;
  -Qi)
    if [[ $3 == nova ]]; then printf 'Depends On      : hyprland\n'; exit 0; fi
    printf 'Name            : %s\nRequired By     : %s\nOptional For    : %s\n' "$3" \
      "$(cat "$SCRATCH/required/$3" 2>/dev/null || echo None)" "$(cat "$SCRATCH/optional/$3" 2>/dev/null || echo None)" ;;
  *) exit 0 ;;
esac
STUB
  for tool in systemctl gpasswd; do
    printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n' "$tool" >"$SCRATCH/bin/$tool"
  done
  chmod +x "$SCRATCH"/bin/*
}

@test "recipe: what it names goes in with the app, as dependencies, and what the release lacks is left out" {
  REPO="vlc vlc-plugins-all" recipe_machine $'# media\nvlc with vlc-plugins-all gone-plugin # why\nvlc skip vlc-gui-ncurses\nvlc prefer arch\nother with not-mine'
  REPO="vlc vlc-plugins-all" INSTALLED="" run "$APPLY" install vlc
  [ "$status" -eq 0 ]
  grep -qx 'pacman -S --needed --noconfirm -- vlc vlc-plugins-all' "$CALLS"
  grep -qx 'pacman -D --asdeps -- vlc-plugins-all' "$CALLS"
  [[ $output == *"With it: vlc-plugins-all"* ]]
  [[ $output == *"not in the release's repositories, so left out: gone-plugin"* ]]
  fails grep -q 'not-mine' "$CALLS"
}

@test "recipe: an extra already installed is not marked, whoever installed it" {
  REPO="vlc vlc-plugins-all" recipe_machine 'vlc with vlc-plugins-all'
  REPO="vlc vlc-plugins-all" INSTALLED="vlc-plugins-all:e" run "$APPLY" install vlc
  [ "$status" -eq 0 ]
  grep -qx 'pacman -S --needed --noconfirm -- vlc vlc-plugins-all' "$CALLS"
  fails grep -q -- '-D' "$CALLS"
}

@test "recipe: its step once the app is in: a packaged socket turned on, and no account put in a group" {
  REPO="virt-manager qemu-desktop" recipe_machine "$(grep '^virt-manager ' "$REPO_ROOT/src/apps/data/recipes")"
  mkdir -p "$NOVA_ROOT/usr/lib/systemd/system" && touch "$NOVA_ROOT/usr/lib/systemd/system/libvirtd.socket"
  REPO="virt-manager qemu-desktop dnsmasq" PKEXEC_UID=1000 run "$APPLY" install virt-manager
  [ "$status" -eq 0 ]
  grep -qx 'systemctl enable --now -- libvirtd.socket' "$CALLS"
  fails grep -q gpasswd "$CALLS"
  # The install before the steps.
  [ "$(grep -n 'pacman -S ' "$CALLS" | cut -d: -f1)" -lt "$(grep -n systemctl "$CALLS" | cut -d: -f1)" ]
}

@test "recipe: a socket no package ships stays off" {
  REPO="virt-manager" recipe_machine 'virt-manager after enable-socket evil.socket'
  mkdir -p "$NOVA_ROOT/usr/lib/systemd/system" && touch "$NOVA_ROOT/usr/lib/systemd/system/evil.socket"
  REPO="virt-manager" run env -u PKEXEC_UID "$APPLY" install virt-manager
  [ "$status" -eq 0 ]
  [[ $output == *"evil.socket is not a socket of an installed package; it is left off"* ]]
  fails grep -q -e systemctl -e gpasswd "$CALLS"
}

@test "recipe: anything but names and the fixed steps stops the install with nothing changed" {
  local bad
  for bad in \
    'vlc with --overwrite=*' \
    'vlc with -dd' \
    'vlc with ../../etc/passwd' \
    'vlc with /tmp/evil.pkg.tar.zst' \
    'vlc with *' \
    'vlc with $(touch /tmp/nova-pwned)' \
    'vlc with' \
    'vlc after run-script /tmp/x' \
    'vlc after enable-socket ../../evil.socket' \
    'vlc after enable-socket sshd.service' \
    'vlc after add-group wheel' \
    'vlc after add-group libvirt' \
    'vlc prefer somewhere' \
    'vlc install-hook x'; do
    : >"$CALLS"
    REPO="vlc" recipe_machine "$bad"
    REPO="vlc" run "$APPLY" install vlc
    [ "$status" -eq 1 ] || { echo "accepted: $bad"; false; }
    [[ $output == *"the recipe for vlc is broken"* ]]
    fails grep -q -e 'pacman -S ' -e systemctl -e gpasswd "$CALLS"
  done
  [ ! -e /tmp/nova-pwned ]
}

@test "recipe: a broken one stops the install before the package lists are read, as on a new install" {
  REPO="vlc" recipe_machine 'vlc with --overwrite=*'
  rm "$NOVA_ROOT/var/lib/pacman/sync/extra.db"
  REPO="vlc" run "$APPLY" install vlc
  [ "$status" -eq 1 ]
  [[ $output == *"the recipe for vlc is broken"* ]]
  fails grep -q -- '-Sy' "$CALLS"
}

@test "recipe: one the caller gives is never read, by argument or environment" {
  REPO="vlc vlc-plugins-all" recipe_machine 'vlc with vlc-plugins-all'
  printf 'vlc with evil-package\n' >"$SCRATCH/evil"
  REPO="vlc vlc-plugins-all" RECIPES=$SCRATCH/evil NOVA_RECIPES=$SCRATCH/evil run "$APPLY" install vlc
  [ "$status" -eq 0 ]
  fails grep -q evil-package "$CALLS"
  run "$APPLY" install vlc "$SCRATCH/evil"
  [ "$status" -eq 2 ]
  # A link in its place is no recipe file.
  ln -sf "$SCRATCH/evil" "$NOVA_ROOT/usr/share/nova/apps/recipes"
  : >"$CALLS"
  REPO="vlc" run "$APPLY" install vlc
  [ "$status" -eq 1 ]
  [[ $output == *"is not a plain file"* ]]
  fails grep -q 'pacman -S ' "$CALLS"
}

@test "remove: the extras it brought go with it, unless asked for by name or needed by what stays" {
  REPO="lutris" recipe_machine 'lutris with umu-launcher lib32-gnutls innoextract'
  echo wine >"$SCRATCH/required/lib32-gnutls"
  INSTALLED="lutris:e umu-launcher:d lib32-gnutls:d innoextract:e" run "$APPLY" remove lutris
  [ "$status" -eq 0 ]
  grep -qx 'pacman -Rns --noconfirm -- lutris umu-launcher' "$CALLS"
  [[ $output == *"With what it brought: umu-launcher"* ]]
}

@test "remove: an extra needed only by another extra that goes goes too; one the app needs is the app's" {
  REPO="retroarch" recipe_machine 'retroarch with libretro-core-info retroarch-assets-ozone'
  echo retroarch >"$SCRATCH/required/libretro-core-info"
  echo 'libretro-core-info  retroarch' >"$SCRATCH/required/retroarch-assets-ozone"
  INSTALLED="retroarch:e libretro-core-info:d retroarch-assets-ozone:d" run "$APPLY" remove retroarch
  [ "$status" -eq 0 ]
  grep -qx 'pacman -Rns --noconfirm -- retroarch libretro-core-info retroarch-assets-ozone' "$CALLS"
}

@test "remove: an extra two apps' recipes share stays while the other app does, whichever goes first" {
  # Pacman lists an optional dependency in neither app's Required By: each
  # recipe's with is all that says the other still uses the dictionary.
  REPO="firefox thunderbird" recipe_machine $'firefox with hunspell-en_us\nthunderbird with hunspell-en_us'
  mkdir -p "$SCRATCH/optional"
  local app other
  for app in firefox thunderbird; do
    other=thunderbird
    [[ $app == firefox ]] || other=firefox
    : >"$CALLS"
    INSTALLED="$app:e $other:e hunspell-en_us:d" run "$APPLY" remove "$app"
    [ "$status" -eq 0 ]
    grep -qx "pacman -Rns --noconfirm -- $app" "$CALLS"
    # The last of the two takes it with it.
    : >"$CALLS"
    INSTALLED="$app:e hunspell-en_us:d" run "$APPLY" remove "$app"
    [ "$status" -eq 0 ]
    grep -qx "pacman -Rns --noconfirm -- $app hunspell-en_us" "$CALLS"
  done
}

@test "remove: an extra another installed package may use stays; one only what goes may use goes" {
  REPO="firefox" recipe_machine 'firefox with hunspell-en_us'
  mkdir -p "$SCRATCH/optional"
  # LibreOffice, installed by hand, has no recipe: its optional dependency
  # on a dictionary is pacman's Optional For.
  echo 'firefox  libreoffice-fresh' >"$SCRATCH/optional/hunspell-en_us"
  INSTALLED="firefox:e libreoffice-fresh:e hunspell-en_us:d" run "$APPLY" remove firefox
  [ "$status" -eq 0 ]
  grep -qx 'pacman -Rns --noconfirm -- firefox' "$CALLS"
  # One that goes with the app itself (pacman -Rsp) keeps nothing.
  echo 'firefox  firefox-spell-helper' >"$SCRATCH/optional/hunspell-en_us"
  printf '%s\n' firefox firefox-spell-helper >"$SCRATCH/going"
  : >"$CALLS"
  INSTALLED="firefox:e firefox-spell-helper:d hunspell-en_us:d" run "$APPLY" remove firefox
  [ "$status" -eq 0 ]
  grep -qx 'pacman -Rns --noconfirm -- firefox hunspell-en_us' "$CALLS"
}

@test "remove: the socket the recipe turned on goes off when its package goes, not when it stays" {
  REPO="virt-manager" recipe_machine $'virt-manager with qemu-desktop\nvirt-manager after enable-socket libvirtd.socket'
  mkdir -p "$NOVA_ROOT/usr/lib/systemd/system" && touch "$NOVA_ROOT/usr/lib/systemd/system/libvirtd.socket"
  printf '%s\n' virt-manager qemu-desktop libvirt >"$SCRATCH/going"
  INSTALLED="virt-manager:e qemu-desktop:d libvirt:d" run "$APPLY" remove virt-manager
  [ "$status" -eq 0 ]
  grep -qx 'systemctl disable --now -- libvirtd.socket' "$CALLS"
  [ "$(grep -n systemctl "$CALLS" | cut -d: -f1)" -lt "$(grep -n 'pacman -Rns' "$CALLS" | cut -d: -f1)" ]
  printf '%s\n' virt-manager qemu-desktop >"$SCRATCH/going"
  : >"$CALLS"
  INSTALLED="virt-manager:e qemu-desktop:d libvirt:d" run "$APPLY" remove virt-manager
  fails grep -q systemctl "$CALLS"
}

@test "the shipped recipes are all ones nova-apps-apply takes" {
  local package
  while read -r package; do
    : >"$CALLS"
    REPO="$package" recipe_machine "$(cat "$REPO_ROOT/src/apps/data/recipes")"
    REPO="$package" run "$APPLY" install "$package"
    [[ $output != *"is broken"* ]] || { echo "$package: $output"; false; }
  done < <(sed 's/#.*//' "$REPO_ROOT/src/apps/data/recipes" | awk 'NF { print $1 }' | sort -u)
}

@test "install: a hardware helper that fails stops the install: left to pacman, NVIDIA's would go in" {
  graphics_machine 0x030000:0x8086:0x9a49
  printf '%s\n' steam lib32-glibc lib32-nvidia-utils nvidia-utils >"$SCRATCH/brought"
  printf '#!/bin/bash\nexit 1\n' >"$SCRATCH/hw-broken"
  chmod +x "$SCRATCH/hw-broken"
  NOVA_HW_PACKAGES=$SCRATCH/hw-broken INSTALLED="mesa vulkan-intel" run "$APPLY" install steam
  [ "$status" -eq 1 ]
  [[ $output == *"could not tell which graphics drivers this computer needs; nothing was installed"* ]]
  fails grep -q 'pacman -S ' "$CALLS"
}
