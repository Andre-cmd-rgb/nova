#!/usr/bin/env bats

# The App Center's helpers against a catalog of six apps (fixtures) and
# stubbed flatpak, pkexec, systemd-run and pacman: searching, an app's
# facts, installing and removing from each place it comes from, in a
# terminal and as the App Center follows it, and what each says when it
# cannot.

load ../test_helper

BIN=$REPO_ROOT/src/apps/bin

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" HAVE="$SCRATCH/installed.json"
  export NOVA_PATH="$SCRATCH/share" NOVA_APPS_APPLY="$SCRATCH/apply"
  mkdir -p "$SCRATCH/bin" "$NOVA_PATH/apps"
  : >"$CALLS"
  cp "$FIXTURES/catalog.json" "$SCRATCH/catalog.json"
  have '[]' '{}'
  stub nova-apps-catalog 'echo "$SCRATCH/catalog.json"'
  stub nova-apps-installed 'cat "$HAVE"'
  # An install, an uninstall or an update prints what the test wrote for it
  # and ends as it says; adding Flathub always works.
  stub flatpak 'echo "flatpak $*" >>"$CALLS"
    [[ $1 == install || $1 == uninstall || $1 == update ]] || exit 0
    [[ ! -e $SCRATCH/flatpak-out ]] || cat "$SCRATCH/flatpak-out"
    exit "$(cat "$SCRATCH/flatpak-status" 2>/dev/null || echo 0)"'
  stub pkexec 'echo "pkexec $*" >>"$CALLS"; [[ ! -e $SCRATCH/apply-out ]] || cat "$SCRATCH/apply-out"; exit "$(cat "$SCRATCH/pkexec-status" 2>/dev/null || echo 0)"'
  export PATH="$SCRATCH/bin:$BIN:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name body
  printf '#!/bin/bash\n%s\n' "$2" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

# What nova-apps-installed says: the Flathub apps installed (a JSON list of
# {app, installation, version}) and the packages ({name: version}).
have() { # flatpak pacman [explicit] [nova]
  printf '{"flatpak":%s,"runtimes":[],"pacman":%s,"explicit":%s,"nova":%s}\n' "$1" "$2" "${3:-[]}" "${4:-[]}" >"$HAVE"
}

status_of() { # id field
  jq -r --arg id "$1" ".[\$id].$2" "$XDG_RUNTIME_DIR/nova/apps/status.json"
}

# --- search and info -------------------------------------------------------------

@test "search: every word must match, the front page's first" {
  run nova-apps-search paint
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Pinta  com.github.PintaProject.Pinta  (Flathub)" ]
  [ "${lines[2]}" = "Tux Paint  tuxpaint.desktop  (Arch Linux)" ]
  run nova-apps-search image photographs
  [ "${lines[0]}" = "GNU Image Manipulation Program  org.gimp.GIMP  (Arch Linux, Flathub)" ]
  [ "${lines[1]}" = "    Create images and edit photographs" ]
}

@test "search: what is installed says so, and nothing found says that" {
  have '[]' '{"firefox":"145.0-1"}'
  run nova-apps-search firefox
  [ "${lines[0]}" = "Firefox  org.mozilla.firefox  (Arch Linux, Flathub)  installed" ]
  run nova-apps-search nothing-like-it
  [ "$status" -eq 1 ]
  [ "$output" = "Nothing found for: nothing-like-it" ]
}

@test "info: where it comes from, by ID, package or name; one word for one app" {
  have '[{"app":"org.gimp.GIMP","installation":"user","version":"3.0.4"}]' '{}'
  run nova-apps-info gimp
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "GNU Image Manipulation Program" ]
  [[ $output == *"From        Arch Linux 3.0.4-1; or Flathub 3.0.4"* ]]
  [[ $output == *"Installed   Flathub 3.0.4 (user)"* ]]
  run nova-apps-info chrome
  [ "${lines[0]}" = "Google Chrome" ]
  [[ $output == *"From        Nova, built here from the maker's release"* ]]
  run nova-apps-info nothing
  [ "$status" -eq 1 ]
  [[ $output == *"no app called 'nothing'; nova apps search nothing looks for it"* ]]
}

@test "list: the installed apps, where from, and Nova's own said" {
  have '[{"app":"org.gimp.GIMP","installation":"user","version":"3.0.4"}]' '{"firefox":"145.0-1","tuxpaint":"1"}' '["firefox"]' '["tuxpaint"]'
  run nova-apps-list
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ ${lines[0]} == "Firefox "*"Arch Linux "*"org.mozilla.firefox" ]]
  [[ ${lines[1]} == "GNU Image Manipulation Program "*"Flathub "*"org.gimp.GIMP" ]]
  [[ ${lines[2]} == "Tux Paint "*"Arch Linux, part of Nova "*"tuxpaint.desktop" ]]
}

# --- installing ------------------------------------------------------------------

@test "install: from Arch, the first place, through pkexec and nova-apps-apply" {
  run nova-apps-job install gimp
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "pkexec $SCRATCH/apply install gimp" ]
}

@test "install --from flathub: into the user's own installation, Flathub added from Nova's file" {
  run nova-apps-job install org.gimp.GIMP --from flathub
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CALLS")" = "flatpak remote-add --user --if-not-exists flathub $NOVA_PATH/apps/flathub.flatpakrepo" ]
  [ "$(sed -n 2p "$CALLS")" = "flatpak install --user -y flathub app/org.gimp.GIMP/x86_64/stable" ]
}

@test "install: an app installed already, and a place it does not come from" {
  have '[]' '{"firefox":"145.0-1"}'
  run nova-apps-job install firefox --from flathub
  [ "$status" -eq 0 ]
  [ "$output" = "Firefox is installed already." ]
  [ ! -s "$CALLS" ]
  run nova-apps-job install pinta --from arch
  [ "$status" -eq 1 ]
  [[ $output == *"Pinta does not come from Arch Linux"* ]]
}

@test "install --status: how far, in status.json under the app's ID, and the log beside it" {
  printf 'Installing 1/2… ████ 50%%\nInstalling 2/2… ████ 100%%\n' >"$SCRATCH/flatpak-out"
  run nova-apps-job install Pinta --status
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(status_of com.github.PintaProject.Pinta state)" = done ]
  [ "$(status_of com.github.PintaProject.Pinta progress)" = 100 ]
  [ "$(status_of com.github.PintaProject.Pinta source)" = flathub ]
  grep -q 'Installing 2/2' "$XDG_RUNTIME_DIR/nova/apps/com.github.PintaProject.Pinta.log"
}

@test "install --status: a failure in words, and the next one keeps the last's entry" {
  printf 'error: Unable to load summary from remote flathub: Could not resolve hostname\n' >"$SCRATCH/flatpak-out"
  echo 1 >"$SCRATCH/flatpak-status"
  run nova-apps-job install pinta --status
  [ "$status" -eq 1 ]
  [ "$(status_of com.github.PintaProject.Pinta state)" = failed ]
  [ "$(status_of com.github.PintaProject.Pinta error)" = "could not download it; check the connection and try again" ]
  rm "$SCRATCH/flatpak-out" "$SCRATCH/flatpak-status"
  run nova-apps-job install gimp --status
  [ "$(status_of org.gimp.GIMP state)" = done ]
  [ "$(status_of com.github.PintaProject.Pinta state)" = failed ]
}

@test "install --status: pacman's progress through nova-apps-apply" {
  printf 'Packages (3) gegl-0.4 babl-0.1 gimp-3.0.4-1\n gimp-3.0.4-1 downloading...\n(1/3) installing babl...\n(3/3) installing gimp...\n:: Running post-transaction hooks...\n' >"$SCRATCH/apply-out"
  run nova-apps-job install gimp --status
  [ "$status" -eq 0 ]
  [ "$(status_of org.gimp.GIMP state)" = done ]
  [ "$(status_of org.gimp.GIMP source)" = arch ]
}

@test "install: the password not given cancels; refused, said so" {
  echo 126 >"$SCRATCH/pkexec-status"
  run nova-apps-job install gimp --status
  [ "$status" -eq 2 ]
  [ "$(status_of org.gimp.GIMP state)" = cancelled ]
  echo 75 >"$SCRATCH/pkexec-status"
  run nova-apps-job install gimp --status
  [ "$status" -eq 1 ]
  [ "$(status_of org.gimp.GIMP error)" = "Nova is installing an update or another app; try again once it is done" ]
  echo 3 >"$SCRATCH/pkexec-status"
  printf "nova-apps-apply: this computer's packages are older than its package lists (glibc): update Nova first, in Settings, Updates\n" >"$SCRATCH/apply-out"
  run nova-apps-job install gimp --status
  [ "$(status_of org.gimp.GIMP error)" = "this computer's packages are older than its package lists (glibc): update Nova first, in Settings, Updates" ]
}

@test "install --status: stopped from outside, it says so rather than staying under way" {
  # As systemd stops a service: every process of it told to end.
  stub flatpak '[[ $1 != install ]] || { echo $$ >"$SCRATCH/flatpak-pid"; exec sleep 30; }'
  nova-apps-job install pinta --status &
  job=$!
  for _ in $(seq 100); do
    [[ -s $SCRATCH/flatpak-pid ]] && break
    sleep 0.1
  done
  kill -TERM "$job" "$(cat "$SCRATCH/flatpak-pid")"
  wait "$job" || true
  [ "$(status_of com.github.PintaProject.Pinta state)" = failed ]
  [ "$(status_of com.github.PintaProject.Pinta error)" = "it stopped before it was done (status 143)" ]
}

@test "install: Chrome is built by nova apps install, then installed as an update installs it" {
  stub nova-apps-install 'echo "nova-apps-install $*" >>"$CALLS"
    if [[ $1 == --build ]]; then echo "built google-chrome abc123 $2/google-chrome.pkg.tar.zst" >"$2/result"; fi'
  run nova-apps-job install chrome
  [ "$status" -eq 0 ]
  [[ $(sed -n 1p "$CALLS") == "nova-apps-install --build "*" --only google-chrome" ]]
  [[ $(sed -n 2p "$CALLS") == "pkexec $SCRATCH/apply built "*"/google-chrome.pkg.tar.zst" ]]
  [ "$(sed -n 3p "$CALLS")" = "nova-apps-install --record google-chrome abc123" ]
}

@test "install: a recipe that changed is held, and said so" {
  stub nova-apps-install 'if [[ $1 == --build ]]; then echo "held google-chrome" >"$2/result"; fi'
  run nova-apps-job install chrome
  [ "$status" -eq 1 ]
  [[ $output == *"its recipe changed since Nova last built it"* ]]
}

# --- removing --------------------------------------------------------------------

@test "remove: from where it is, Flathub's with the runtimes no app uses" {
  have '[{"app":"org.gimp.GIMP","installation":"user","version":"3.0.4"}]' '{}'
  run nova-apps-remove gimp
  [ "$status" -eq 0 ]
  [ "$(sed -n 1p "$CALLS")" = "flatpak uninstall --user -y --noninteractive --delete-data org.gimp.GIMP" ]
  [ "$(sed -n 2p "$CALLS")" = "flatpak uninstall --user -y --noninteractive --unused" ]
  have '[]' '{"gimp":"3.0.4-1"}'
  : >"$CALLS"
  run nova-apps-remove gimp
  [ "$(cat "$CALLS")" = "pkexec $SCRATCH/apply remove gimp" ]
}

@test "remove: one not installed has nothing to do" {
  run nova-apps-remove gimp
  [ "$status" -eq 0 ]
  [ "$output" = "GNU Image Manipulation Program is not installed." ]
  [ ! -s "$CALLS" ]
}

# --- nova apps install, the App Center's way ---------------------------------------

@test "nova apps install <app> is the App Center's install" {
  stub nova-apps-job 'echo "nova-apps-job $*" >>"$CALLS"'
  run "$REPO_ROOT/src/cli/bin/nova-apps-install" org.gimp.GIMP --from flathub
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "nova-apps-job install org.gimp.GIMP --from flathub" ]
}

# --- the App Center's own -------------------------------------------------------------

@test "run: a user service per app, which the window can close on" {
  stub systemctl 'exit 3'
  stub systemd-run 'echo "systemd-run $*" >>"$CALLS"'
  run nova-apps-run install org.gimp.GIMP --from flathub
  [ "$status" -eq 0 ]
  [[ $(cat "$CALLS") == "systemd-run --user --quiet --collect --unit=nova-apps-org.gimp.GIMP --service-type=exec --setenv=PATH="*" -- $BIN/nova-apps-job install org.gimp.GIMP --from flathub --status" ]]
  run nova-apps-run install 'org.gimp.GIMP; rm -rf ~'
  [ "$status" -eq 2 ]
  run nova-apps-run install org.gimp.GIMP --force
  [ "$status" -eq 2 ]
}

@test "run: one for the app under way already, nothing more" {
  stub systemctl 'exit 0'
  stub systemd-run 'echo "systemd-run $*" >>"$CALLS"'
  run nova-apps-run remove org.gimp.GIMP
  [ "$status" -eq 0 ]
  [ ! -s "$CALLS" ]
}

@test "refresh: Flathub's catalog once a day, into the user's installation" {
  export FLATPAK_USER_DIR="$SCRATCH/flatpak"
  stamp=$FLATPAK_USER_DIR/appstream/flathub/$(uname -m)/.timestamp
  mkdir -p "$(dirname "$stamp")"
  touch "$stamp"
  run nova-apps-refresh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$CALLS" ]
  touch -d '2 days ago' "$stamp"
  run nova-apps-refresh
  [ "$status" -eq 0 ]
  [ "$output" = updated ]
  [ "$(sed -n 2p "$CALLS")" = "flatpak update --user --appstream flathub" ]
  echo 1 >"$SCRATCH/flatpak-status"
  run nova-apps-refresh --force
  [ "$status" -eq 1 ]
  [[ $output == *"could not reach Flathub"* ]]
}

@test "size: the package and what it needs that is not installed, in bytes" {
  stub pacman 'case $1 in
    -Sp) printf "gimp\ngegl\n" ;;
    -Si) printf "Name : gimp\nDownload Size : 20.00 MiB\nInstalled Size : 100.00 MiB\nName : gegl\nDownload Size : 512.00 KiB\nInstalled Size : 2.00 MiB\n" ;;
  esac'
  run nova-apps-size gimp
  [ "$status" -eq 0 ]
  [ "$output" = "21495808 106954752" ]
  run nova-apps-size -- '--rf'
  [ "$status" -eq 2 ]
  run nova-apps-size gimp '-dd'
  [ "$status" -eq 2 ]
}

@test "size: with what its recipe installs with it, and this computer's graphics drivers where pacman would pick NVIDIA's" {
  # pacman picks NVIDIA's 32-bit driver unless given one.
  stub pacman 'echo "pacman $*" >>"$CALLS"
    case $1 in
    -Sp) shift 4
      printf "%s\n" "$@"
      [[ " $* " == *" lib32-vulkan-intel "* ]] || echo lib32-nvidia-utils ;;
    -Si) for p in "${@:3}"; do printf "Name : %s\nDownload Size : 1.00 MiB\nInstalled Size : 2.00 MiB\n" "$p"; done ;;
    esac'
  stub hw '[[ $1 == --needed-by ]] || exit 2; grep -q "^lib32-" && printf "%s\n" mesa vulkan-intel lib32-mesa lib32-vulkan-intel'
  NOVA_HW_PACKAGES=$SCRATCH/bin/hw run nova-apps-size steam umu-launcher
  [ "$status" -eq 0 ]
  grep -qx 'pacman -Sp --print-format %n -- steam umu-launcher mesa vulkan-intel lib32-mesa lib32-vulkan-intel' "$CALLS"
  # Six packages of a MiB each, none of them NVIDIA's.
  [ "$output" = "6291456 12582912" ]
  fails grep -q -- '-Si.*nvidia' "$CALLS"
  # An app that needs no driver is sized as it is.
  stub hw 'cat >/dev/null'
  : >"$CALLS"
  NOVA_HW_PACKAGES=$SCRATCH/bin/hw run nova-apps-size gimp
  [ "$(grep -c -- -Sp "$CALLS")" -eq 1 ]
}

@test "size: an extra the release's repositories lack is left out, as nova-apps-apply leaves it out" {
  # pacman -Sp fails whole on one name it does not know.
  stub pacman 'echo "pacman $*" >>"$CALLS"
    case $1 in
    -Sp) shift 4
      [[ " $* " != *" gone-plugin "* ]] || exit 1
      printf "%s\n" "$@" ;;
    -Si) [[ $# -gt 3 || $3 != gone-plugin ]] || exit 1
      for p in "${@:3}"; do printf "Name : %s\nDownload Size : 1.00 MiB\nInstalled Size : 2.00 MiB\n" "$p"; done ;;
    esac'
  stub hw 'cat >/dev/null'
  NOVA_HW_PACKAGES=$SCRATCH/bin/hw run nova-apps-size vlc vlc-plugins-all gone-plugin
  [ "$status" -eq 0 ]
  [ "$output" = "2097152 4194304" ]
  grep -qx 'pacman -Sp --print-format %n -- vlc vlc-plugins-all' "$CALLS"
}

@test "store: the window on an app's page, an appstream:// link's, or a search" {
  stub nova-shell 'echo "nova-shell $*" >>"$CALLS"'
  nova-apps-store appstream://org.gimp.GIMP
  nova-apps-store --search image editor
  nova-apps-store
  [ "$(sed -n 1p "$CALLS")" = 'nova-shell shell summon nova.store {"app":"org.gimp.GIMP"}' ]
  [ "$(sed -n 2p "$CALLS")" = 'nova-shell shell summon nova.store {"search":"image editor"}' ]
  [ "$(sed -n 3p "$CALLS")" = 'nova-shell shell summon nova.store {}' ]
}

# --- the front page's file -----------------------------------------------------------

@test "featured: Popular and the kinds; an app is in one kind, and Popular once" {
  file=$BATS_TEST_DIRNAME/../../../src/apps/data/featured
  run awk '!/^#/ && NF { print $1 }' "$file"
  [ "$status" -eq 0 ]
  keys=$(sort -u <<<"$output" | tr '\n' ' ')
  [ "$keys" = "create develop internet learn media play popular utilities work " ]
  [ "$(awk '$1 == "popular"' "$file" | wc -l)" -ge 10 ]
  run awk '!/^#/ && NF && $1 != "popular" { print $2 }' "$file"
  [ -z "$(sort <<<"$output" | uniq -d)" ]
  run awk '$1 == "popular" { print $2 }' "$file"
  [ -z "$(sort <<<"$output" | uniq -d)" ]
}
