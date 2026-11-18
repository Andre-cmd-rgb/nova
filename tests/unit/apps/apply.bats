#!/usr/bin/env bats

# nova-apps-apply, the root half of an install from Arch's repositories,
# in a scratch root (NOVA_ROOT) with pacman stubbed: what it installs and
# removes, and each thing it refuses, above all a partial upgrade.

load ../test_helper

APPLY=$REPO_ROOT/src/apps/bin/nova-apps-apply

setup() {
  setup_scratch
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
