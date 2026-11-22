#!/usr/bin/env bats

# nova update, end to end with the root step, the system and the app builds
# stubbed: what it does after a release is applied.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" PKGVER="$SCRATCH/pkgver"
  export NOVA_MIRRORLIST="$SCRATCH/nova-mirrorlist" NOVA_REPOFILE="$SCRATCH/nova-repo"
  export NOVA_UPDATE_SYNC_DIR="$SCRATCH/sync"
  export NOVA_UPDATE_APPLY="$SCRATCH/bin/nova-update-apply" NOVA_UPDATE_APPS="$SCRATCH/bin/nova-apps-install"
  mkdir -p "$SCRATCH/bin"
  echo 1.0.0beta.1 >"$PKGVER"
  printf 'version = "1.0.0-beta.2"\narch_date = "2026/10/19"\nnova_repo = "https://example.org/repo"\n' >"$SCRATCH/release.toml"
  stub pacman 'echo "nova $(cat "$PKGVER")-1"'
  stub pacman-conf
  stub pkexec '"$@"'
  # --repairs reads what $SCRATCH/repairs says a repair would do: nothing,
  # unless a test writes it.
  stub nova-update-apply '[[ $1 != --repairs ]] || { cat "$SCRATCH/repairs" 2>/dev/null; exit 0; }; echo 1.0.0beta.2 >"$PKGVER"'
  stub nova-shell
  stub nova-restart-shell
  # Never the session's own services: the real one would stop and start
  # this computer's.
  stub nova-session-settle
  stub nova-apps-install 'echo current'
  # What it would say goes to $CALLS, never to this computer's notifications.
  stub nova-notification-send
  # No update is running, whatever else is: the real pgrep would find another
  # test's nova-update-apply, or this computer's own.
  stub pgrep 'exit 1'
  # No Flathub apps, unless a test lists some in $SCRATCH/flatpak-user or
  # -system: flatpak is never this computer's, which would update its apps.
  export NOVA_UPDATE_FLATPAK="$SCRATCH/bin/flatpak"
  printf '#!/bin/bash\nif [[ $1 == list ]]; then cat "$SCRATCH/flatpak-${2#--}" 2>/dev/null; exit 0; fi\necho "flatpak $*" >>"$CALLS"\nexit "$(cat "$SCRATCH/flatpak-status" 2>/dev/null || echo 0)"\n' \
    >"$SCRATCH/bin/flatpak"
  chmod +x "$SCRATCH/bin/flatpak"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

stub() { # name [body]: logs "name args" to $CALLS, then runs body
  printf '#!/bin/bash\necho "%s $*" >>"$CALLS"\n%s\n' "$1" "${2:-exit 0}" >"$SCRATCH/bin/$1"
  chmod +x "$SCRATCH/bin/$1"
}

update() { "$REPO_ROOT/src/cli/bin/nova-update" --release-file "$SCRATCH/release.toml" --yes; }

@test "a running shell is restarted on the new release" {
  run update
  [ "$status" -eq 0 ]
  grep -q '^nova-update-apply --tag v1.0.0-beta.2' "$CALLS"
  grep -qx 'nova-restart-shell ' "$CALLS"
  [[ $output == *"Restarting the shell"* ]]
}

@test "the session's services move onto the new release before the shell restarts, and its restarts after" {
  run update
  [ "$status" -eq 0 ]
  [ "$(grep -oE '^(nova-session-settle [a-z]+|nova-restart-shell)' "$CALLS" | paste -sd,)" = "nova-session-settle services,nova-restart-shell,nova-session-settle restart" ]
}

@test "no shell running, none started; the session's services move, and restart, all the same" {
  stub nova-shell 'exit 1'
  run update
  [ "$status" -eq 0 ]
  ! grep -q nova-restart-shell "$CALLS"
  [ "$(grep -oE '^nova-session-settle [a-z]+' "$CALLS" | paste -sd,)" = "nova-session-settle services,nova-session-settle restart" ]
}

@test "nova unchanged, the shell and the session's services are left alone" {
  stub nova-update-apply
  run update
  [ "$status" -eq 0 ]
  ! grep -q nova-restart-shell "$CALLS"
  ! grep -q nova-session-settle "$CALLS"
}

@test "services that could not move are a warning, not a failed update" {
  stub nova-session-settle 'exit 1'
  run update
  [ "$status" -eq 0 ]
  [[ $output == *"the session's services follow the new release at the next login"* ]]
  grep -qx 'nova-restart-shell ' "$CALLS"
}

@test "a failed update restarts nothing" {
  stub nova-update-apply 'exit 3'
  run update
  [ "$status" -eq 3 ]
  ! grep -q nova-restart-shell "$CALLS"
}

@test "a screen locked meanwhile: the shell restarts once it is unlocked, and the session's restarts with it" {
  # Refused under the lock once, then done, in the unit the update leaves;
  # systemd-run runs that unit's command here and now.
  stub nova-restart-shell '[[ -e $SCRATCH/unlocked ]] || { touch "$SCRATCH/unlocked"; exit 75; }'
  stub systemctl 'exit 3'
  stub systemd-run 'shift 4; "$@"'
  run update
  [ "$status" -eq 0 ]
  grep -q '^systemd-run --user --collect --quiet --unit=nova-shell-restart-pending bash -c ' "$CALLS"
  [[ $output == *"restarts on the new release once it is unlocked"* ]]
  [[ $output != *"log out and back in"* ]]
  [ "$(grep -oE '^(nova-session-settle restart|nova-restart-shell|systemd-run)' "$CALLS" | paste -sd,)" = "nova-restart-shell,systemd-run,nova-restart-shell,nova-session-settle restart" ]
}

@test "a shell that will not restart is a warning, not a failed update; the session's restarts wait for the login too" {
  stub nova-restart-shell 'exit 1'
  run update
  [ "$status" -eq 0 ]
  [[ $output == *"log out and back in"* ]]
  fails grep -q '^nova-session-settle restart' "$CALLS"
}

@test "Chrome and VS Code are updated after the release" {
  run update
  [ "$status" -eq 0 ]
  [ "$(grep -oE '^(nova-update-apply|nova-apps-install)' "$CALLS" | paste -sd' ')" = "nova-update-apply nova-apps-install" ]
  grep -qE '^nova-apps-install --update --result [^ ]+ --noconfirm$' "$CALLS"
}

@test "with Nova already current, the apps are still updated" {
  echo 1.0.0beta.2 >"$PKGVER"
  run update
  [ "$status" -eq 0 ]
  # Asked only what a repair would do, which is nothing: no root step.
  [ "$(grep '^nova-update-apply' "$CALLS")" = "nova-update-apply --repairs" ]
  fails grep -q '^pkexec' "$CALLS"
  grep -qE '^nova-apps-install --update --result [^ ]+ --noconfirm$' "$CALLS"
}

@test "with Nova already current, the repairs nova doctor points at are made, with one authentication" {
  echo 1.0.0beta.2 >"$PKGVER"
  printf '%s\n' "Installing this computer's graphics drivers: lib32-vulkan-intel" >"$SCRATCH/repairs"
  run update
  [ "$status" -eq 0 ]
  [[ $output == *"Nova is already on v1.0.0-beta.2."* ]]
  [[ $output == *"This computer needs a repair, which needs no new release:
  Installing this computer's graphics drivers: lib32-vulkan-intel"* ]]
  [ "$(grep -c '^pkexec' "$CALLS")" -eq 1 ]
  grep -qx 'pkexec .*/nova-update-apply --repair --noconfirm' "$CALLS"
  # The apps after it, as ever.
  grep -qE '^nova-apps-install --update --result [^ ]+ --noconfirm$' "$CALLS"
  # Asked first, without --yes; a no leaves it.
  : >"$CALLS"
  run bash -c 'echo n | "$1" --release-file "$2"' _ "$REPO_ROOT/src/cli/bin/nova-update" "$SCRATCH/release.toml"
  [ "$status" -eq 0 ]
  [[ $output == *"Left as it is"* ]]
  fails grep -q '^pkexec' "$CALLS"
  # A dry run says it, and does nothing.
  run "$REPO_ROOT/src/cli/bin/nova-update" --release-file "$SCRATCH/release.toml" --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"lib32-vulkan-intel"* && $output == *"Dry run: nothing changed."* ]]
  fails grep -q '^pkexec' "$CALLS"
}

@test "a failed update leaves the apps alone" {
  stub nova-update-apply 'exit 3'
  run update
  [ "$status" -eq 3 ]
  ! grep -q nova-apps-install "$CALLS"
}

@test "an app that will not build: Nova updated, the app named, and the run ends with problems" {
  stub nova-apps-install '[[ $2 != --result ]] || echo "failed google-chrome" >>"$3"; exit 1'
  run update
  [ "$status" -eq 4 ]
  grep -q '^nova-update-apply --tag v1.0.0-beta.2' "$CALLS"
  [[ $output == *"nova update: Chrome could not be updated; nova apps update tries again"* ]]
  # Nothing to say which: either.
  stub nova-apps-install 'exit 1'
  run update
  [ "$status" -eq 4 ]
  [[ $output == *"Chrome or VS Code could not be updated; nova apps update tries again"* ]]
}

@test "run as root, the apps behind are named and left for nova apps update, which is no problem" {
  export NOVA_UPDATE_EUID=0
  stub nova-apps-install '[[ $1 == --check ]] && echo "apps google-chrome visual-studio-code-bin"'
  run update
  [ "$status" -eq 0 ]
  grep -q '^nova-update-apply --tag v1.0.0-beta.2' "$CALLS"
  fails grep -q -- '--update' <(grep '^nova-apps-install' "$CALLS")
  [[ $output == *"Chrome and VS Code can be updated with nova apps update, run as yourself."* ]]
  # None behind, or the AUR out of reach: nothing said.
  stub nova-apps-install 'echo current'
  run update
  [ "$status" -eq 0 ]
  [[ $output != *"nova apps update"* ]]
  stub nova-apps-install 'exit 1'
  run update
  [ "$status" -eq 0 ]
}

@test "Flathub's apps are updated after Chrome and VS Code, where there are any" {
  echo app/org.gimp.GIMP/x86_64/stable >"$SCRATCH/flatpak-user"
  run update
  [ "$status" -eq 0 ]
  [[ $output == *"Updating the apps from Flathub."* ]]
  [ "$(grep -oE '^(nova-update-apply|nova-apps-install|flatpak update)' "$CALLS" | paste -sd' ')" = "nova-update-apply nova-apps-install flatpak update" ]
  grep -qx 'flatpak update --user -y --noninteractive' "$CALLS"
  fails grep -q -- '--system' "$CALLS"
}

@test "with no Flathub apps, flatpak updates nothing" {
  run update
  [ "$status" -eq 0 ]
  [[ $output != *"Flathub"* ]]
  fails grep -q '^flatpak' "$CALLS"
}

@test "Flathub's apps that will not update: Nova updated, and the run ends with problems" {
  echo app/org.gimp.GIMP/x86_64/stable >"$SCRATCH/flatpak-system"
  echo 1 >"$SCRATCH/flatpak-status"
  run update
  [ "$status" -eq 4 ]
  grep -qx 'flatpak update --system -y --noninteractive' "$CALLS"
  [[ $output == *"nova update: Flathub's apps could not be updated; nova apps update tries again"* ]]
  stub nova-apps-install '[[ $2 != --result ]] || echo "failed google-chrome" >>"$3"; exit 1'
  run update
  [[ $output == *"nova update: Chrome and Flathub's apps could not be updated; nova apps update tries again"* ]]
}

@test "nova apps update: Chrome and VS Code, then Flathub's apps" {
  echo app/org.gimp.GIMP/x86_64/stable >"$SCRATCH/flatpak-user"
  run "$REPO_ROOT/src/cli/bin/nova-apps-update" --noconfirm
  [ "$status" -eq 0 ]
  [ "$(grep -oE '^(nova-apps-install|flatpak update)' "$CALLS" | paste -sd' ')" = "nova-apps-install flatpak update" ]
  grep -qx 'nova-apps-install --update --noconfirm' "$CALLS"
}

@test "an app held for a recipe that changed waits, and is no problem" {
  stub nova-apps-install '[[ $2 != --result ]] || echo "held visual-studio-code-bin" >>"$3"; exit 1'
  run update
  [ "$status" -eq 0 ]
  [[ $output != *"could not be updated"* ]]
}

@test "the check names the apps that are behind when Nova is current" {
  echo 1.0.0beta.2 >"$PKGVER"
  stub nova-apps-install 'echo "apps google-chrome"'
  export NOVA_UPDATE_CACHE="$SCRATCH/cache" NOVA_UPDATE_API=http://127.0.0.1:9
  echo "$(date +%s) v1.0.0-beta.2" >"$NOVA_UPDATE_CACHE"
  run "$REPO_ROOT/src/cli/bin/nova-update" --check
  [ "$status" -eq 0 ]
  [ "$output" = "apps google-chrome" ]
  echo 1.0.0beta.1 >"$PKGVER"
  run "$REPO_ROOT/src/cli/bin/nova-update" --check
  [ "$output" = "available 1.0.0-beta.2" ]
}

@test "the check says an update that did not finish, unless a newer release is out" {
  echo 1.0.0beta.2 >"$PKGVER"
  export NOVA_UPDATE_CACHE="$SCRATCH/cache" NOVA_UPDATE_API=http://127.0.0.1:9
  echo "$(date +%s) v1.0.0-beta.2" >"$NOVA_UPDATE_CACHE"
  printf '# Managed by nova update; the next update rewrites this file.\n# nova-release: v1.0.0-beta.2\n' >"$NOVA_REPOFILE"
  touch "$NOVA_REPOFILE.nova-prev"
  run "$REPO_ROOT/src/cli/bin/nova-update" --check
  [ "$status" -eq 0 ]
  [ "$output" = "unfinished 1.0.0-beta.2" ]
  # While it runs, it is not unfinished.
  stub pgrep
  run "$REPO_ROOT/src/cli/bin/nova-update" --check
  [ "$output" = "current" ]
  echo "$(date +%s) v1.0.0-beta.3" >"$NOVA_UPDATE_CACHE"
  run "$REPO_ROOT/src/cli/bin/nova-update" --check
  [ "$output" = "available 1.0.0-beta.3" ]
}

@test "the check says a repair that is due when nothing else waits, and asks no authentication for it" {
  echo 1.0.0beta.2 >"$PKGVER"
  export NOVA_UPDATE_CACHE="$SCRATCH/cache" NOVA_UPDATE_API=http://127.0.0.1:9 NOVA_UPDATE_NOTIFIED="$SCRATCH/state/notified"
  echo "$(date +%s) v1.0.0-beta.2" >"$NOVA_UPDATE_CACHE"
  printf '%s\n' "Installing this computer's graphics drivers: lib32-vulkan-intel" >"$SCRATCH/repairs"
  run "$REPO_ROOT/src/cli/bin/nova-update" --check
  [ "$status" -eq 0 ]
  [ "$output" = repair ]
  [ "$(grep '^nova-update-apply' "$CALLS")" = "nova-update-apply --repairs" ]
  fails grep -q '^pkexec' "$CALLS"
  # The badge's check passes it on, and says it in no notification.
  run "$REPO_ROOT/src/cli/bin/nova-update-check" --notify
  [ "$output" = repair ]
  fails grep -q '^nova-notification-send' "$CALLS"
  # Apps behind come first, and a release before them: the update that
  # brings them makes the repair too.
  stub nova-apps-install 'echo "apps google-chrome"'
  run "$REPO_ROOT/src/cli/bin/nova-update" --check
  [ "$output" = "apps google-chrome" ]
  echo 1.0.0beta.1 >"$PKGVER"
  run "$REPO_ROOT/src/cli/bin/nova-update" --check
  [ "$output" = "available 1.0.0-beta.2" ]
  # Nothing to repair, or a helper that cannot say: current.
  echo 1.0.0beta.2 >"$PKGVER"
  stub nova-apps-install 'echo current'
  rm "$SCRATCH/repairs"
  run "$REPO_ROOT/src/cli/bin/nova-update" --check
  [ "$output" = current ]
  printf '%s\n' "Installing game controllers' rules: steam-devices" >"$SCRATCH/repairs"
  stub nova-update-apply 'exit 1'
  run "$REPO_ROOT/src/cli/bin/nova-update" --check
  [ "$output" = current ]
}

@test "the badge's check says an update once, and again only after Nova was current" {
  export NOVA_UPDATE_CACHE="$SCRATCH/cache" NOVA_UPDATE_API=http://127.0.0.1:9 NOVA_UPDATE_NOTIFIED="$SCRATCH/state/notified"
  stub nova-notification-send
  echo "$(date +%s) v1.0.0-beta.2" >"$NOVA_UPDATE_CACHE"
  run "$REPO_ROOT/src/cli/bin/nova-update-check" --notify
  [ "$status" -eq 0 ]
  [ "$output" = "available 1.0.0-beta.2" ]
  grep -qx 'nova-notification-send -g 󰚰 Nova 1.0.0-beta.2 is available Settings → Updates installs it. --exec nova-shell shell summon nova.settings {"page":"updates"}' "$CALLS"
  run "$REPO_ROOT/src/cli/bin/nova-update-check" --notify
  [ "$output" = "available 1.0.0-beta.2" ]
  [ "$(grep -c '^nova-notification-send' "$CALLS")" -eq 1 ]
  # Current, then the apps behind: neither is a notification. The badge and
  # Settings say the apps.
  echo 1.0.0beta.2 >"$PKGVER"
  run "$REPO_ROOT/src/cli/bin/nova-update-check" --notify
  [ "$output" = current ]
  [ "$(grep -c '^nova-notification-send' "$CALLS")" -eq 1 ]
  stub nova-apps-install 'echo "apps google-chrome visual-studio-code-bin"'
  run "$REPO_ROOT/src/cli/bin/nova-update-check" --notify
  [ "$output" = "apps google-chrome visual-studio-code-bin" ]
  [ "$(grep -c '^nova-notification-send' "$CALLS")" -eq 1 ]
  # A release out after that is said again: Nova was current in between.
  echo 1.0.0beta.1 >"$PKGVER"
  run "$REPO_ROOT/src/cli/bin/nova-update-check" --notify
  [ "$output" = "available 1.0.0-beta.2" ]
  [ "$(grep -c '^nova-notification-send' "$CALLS")" -eq 2 ]
  # Without --notify, as Settings asks, nothing is said.
  rm -f "$NOVA_UPDATE_NOTIFIED"
  run "$REPO_ROOT/src/cli/bin/nova-update-check"
  [ "$output" = "available 1.0.0-beta.2" ]
  [ "$(grep -c '^nova-notification-send' "$CALLS")" -eq 2 ]
}

@test "the badge's check tries again an update it could not say" {
  export NOVA_UPDATE_CACHE="$SCRATCH/cache" NOVA_UPDATE_API=http://127.0.0.1:9 NOVA_UPDATE_NOTIFIED="$SCRATCH/state/notified"
  echo "$(date +%s) v1.0.0-beta.2" >"$NOVA_UPDATE_CACHE"
  stub nova-notification-send 'exit 1'
  run "$REPO_ROOT/src/cli/bin/nova-update-check" --notify
  [ "$status" -eq 0 ]
  [ "$output" = "available 1.0.0-beta.2" ]
  stub nova-notification-send
  run "$REPO_ROOT/src/cli/bin/nova-update-check" --notify
  [ "$(grep -c '^nova-notification-send' "$CALLS")" -eq 2 ]
  [ "$(cat "$NOVA_UPDATE_NOTIFIED")" = "available 1.0.0-beta.2" ]
}

@test "the badge's check, offline, says nothing and keeps what it said" {
  export NOVA_UPDATE_CACHE="$SCRATCH/cache" NOVA_UPDATE_API=http://127.0.0.1:9 NOVA_UPDATE_NOTIFIED="$SCRATCH/state/notified"
  mkdir -p "$SCRATCH/state"
  echo "available 1.0.0-beta.2" >"$NOVA_UPDATE_NOTIFIED"
  stub nova-notification-send
  stub curl 'exit 7'
  run "$REPO_ROOT/src/cli/bin/nova-update-check" --notify
  [ "$status" -ne 0 ]
  [ -z "$output" ] || [[ $output != available* && $output != current ]]
  fails grep -q '^nova-notification-send' "$CALLS"
  [ "$(cat "$NOVA_UPDATE_NOTIFIED")" = "available 1.0.0-beta.2" ]
}

@test "following candidates: switched on and off, and the check then offers them" {
  export NOVA_UPDATE_CANDIDATES="$SCRATCH/config/update-candidates" NOVA_UPDATE_CACHE="$SCRATCH/cache"
  echo 1.0.0 >"$PKGVER"
  # GitHub: v1.0.0 is the latest release, v1.1.0-rc.1 the newest of all.
  stub curl 'while (($#)); do [[ $1 == -o ]] && out=$2; url=$1; shift; done
    case $url in
      */releases/latest) echo "{\"tag_name\":\"v1.0.0\"}" >"$out" ;;
      *"/releases?"*) echo "[{\"tag_name\":\"v1.1.0-rc.1\",\"draft\":false},{\"tag_name\":\"v1.0.0\",\"draft\":false}]" >"$out" ;;
    esac
    printf 200'
  check() { "$REPO_ROOT/src/cli/bin/nova-update" --check; }
  candidates() { "$REPO_ROOT/src/cli/bin/nova-update" --candidates "$@"; }

  [ "$(candidates)" = off ]
  [ "$(check)" = current ]
  candidates on
  [ "$(candidates)" = on ]
  [ "$(check)" = "available 1.1.0-rc.1" ]
  candidates off
  [ "$(check)" = current ]
  run candidates maybe
  [ "$status" -ne 0 ]
}

@test "candidates: the newest release by version, whatever order GitHub lists them in" {
  export NOVA_UPDATE_CANDIDATES="$SCRATCH/config/update-candidates" NOVA_UPDATE_CACHE="$SCRATCH/cache"
  echo 1.1.0rc.2 >"$PKGVER"
  # A final shares its candidate's commit, so GitHub can list a later
  # candidate above it.
  stub curl 'while (($#)); do [[ $1 == -o ]] && out=$2; url=$1; shift; done
    case $url in
      *"/releases?"*) echo "[{\"tag_name\":\"v1.1.0-rc.3\",\"draft\":false},{\"tag_name\":\"v1.2.0-rc.1\",\"draft\":true},{\"tag_name\":\"v1.1.0\",\"draft\":false},{\"tag_name\":\"v1.1.0-rc.2\",\"draft\":false}]" >"$out" ;;
    esac
    printf 200'
  run "$REPO_ROOT/src/cli/bin/nova-update" --check
  [ "$status" -eq 0 ]
  [ "$output" = "available 1.1.0" ]
}

@test "a draft of the release's own tag, listed above it, is not the release" {
  export NOVA_UPDATE_CANDIDATES="$SCRATCH/config/update-candidates" NOVA_UPDATE_CACHE="$SCRATCH/cache"
  echo 1.1.0rc.2 >"$PKGVER"
  # A token that may write the repository is shown drafts too. The draft has
  # no files yet; the published release has them.
  cat >"$SCRATCH/list.json" <<'JSON'
[{"tag_name":"v1.1.0","draft":true,"assets":[]},
 {"tag_name":"v1.1.0","draft":false,"assets":[{"name":"release.toml","browser_download_url":"https://dl.example.org/release.toml"},{"name":"release.toml.sig","browser_download_url":"https://dl.example.org/release.toml.sig"}]}]
JSON
  stub curl 'while (($#)); do [[ $1 == -o ]] && out=$2; url=$1; shift; done
    echo "$url" >>"$SCRATCH/fetched"
    case $url in
      *"/releases?"*) cp "$SCRATCH/list.json" "$out" ;;
    esac
    printf 200'
  run "$REPO_ROOT/src/cli/bin/nova-update" --yes
  # The published release's files are the ones asked for.
  grep -qx 'https://dl.example.org/release.toml' "$SCRATCH/fetched"
}

# GitHub, listing the releases <tag>... in that order (a tag with a * is
# flagged a pre-release), its latest the first final among them.
github_lists() { # tag...
  local tag list='' latest=''
  for tag in "$@"; do
    list+="${list:+,}{\"tag_name\":\"v${tag%\*}\",\"draft\":false,\"prerelease\":$([[ $tag == *\* ]] && echo true || echo false)}"
    [[ -n $latest || $tag == *[-*]* ]] || latest="{\"tag_name\":\"v$tag\"}"
  done
  echo "[$list]" >"$SCRATCH/list.json"
  if [[ -n $latest ]]; then echo "$latest" >"$SCRATCH/latest.json"; else rm -f "$SCRATCH/latest.json"; fi
  stub curl 'while (($#)); do [[ $1 == -o ]] && out=$2; url=$1; shift; done
    case $url in
      */releases/latest) [[ -e $SCRATCH/latest.json ]] || { printf 404; exit 0; }; cp "$SCRATCH/latest.json" "$out" ;;
      *"/releases?"*) cp "$SCRATCH/list.json" "$out" ;;
    esac
    printf 200'
  rm -f "$NOVA_UPDATE_CACHE"
}

@test "a system installed from a candidate goes to the next final release, and leaves candidates there" {
  export NOVA_UPDATE_CANDIDATES="$SCRATCH/config/update-candidates" NOVA_UPDATE_CACHE="$SCRATCH/cache"
  check() { "$REPO_ROOT/src/cli/bin/nova-update" --check; }
  echo 1.0.0rc.15 >"$PKGVER"
  # A final newer than it is out, and a newer candidate after it: the final.
  github_lists 1.0.1-rc.1 1.0.0 1.0.0-rc.15
  [ "$(check)" = "available 1.0.0" ]
  # In any order GitHub lists them, and past a final flagged a pre-release.
  github_lists 1.0.0-rc.15 1.0.1-rc.1 1.0.1\* 1.0.0
  [ "$(check)" = "available 1.0.0" ]
  # No final newer than it yet: the next candidate.
  github_lists 1.0.0-rc.16 1.0.0-rc.15
  [ "$(check)" = "available 1.0.0-rc.16" ]
  github_lists 1.0.0-rc.16 1.0.0-rc.15 0.9.0
  [ "$(check)" = "available 1.0.0-rc.16" ]
  # On that final, a candidate after it is not followed.
  echo 1.0.0 >"$PKGVER"
  github_lists 1.0.1-rc.1 1.0.0
  [ "$(check)" = current ]
  # Unless candidates are switched on, where it is.
  "$REPO_ROOT/src/cli/bin/nova-update" --candidates on
  github_lists 1.0.1-rc.1 1.0.0
  [ "$(check)" = "available 1.0.1-rc.1" ]
  # And on, a candidate installed follows the newest of all.
  echo 1.0.0rc.15 >"$PKGVER"
  github_lists 1.0.1-rc.1 1.0.0 1.0.0-rc.15
  [ "$(check)" = "available 1.0.1-rc.1" ]
}

# GitHub with release v1.0.0-beta.2, whose assets are the files in $SCRATCH/served.
serve_release() { # asset...
  mkdir -p "$SCRATCH/served"
  local assets='' name
  for name in "$@"; do
    assets+="${assets:+,}{\"name\":\"$name\",\"browser_download_url\":\"https://dl.example.org/$name\"}"
  done
  stub curl "while ((\$#)); do [[ \$1 == -o ]] && out=\$2; url=\$1; shift; done
    case \$url in
      */releases/tags/v1.0.0-beta.2) echo '{\"tag_name\":\"v1.0.0-beta.2\",\"assets\":[$assets]}' >\"\$out\" ;;
      https://dl.example.org/*) cp \"$SCRATCH/served/\${url##*/}\" \"\$out\" ;;
    esac
    printf 200"
}

@test "a release's release.toml is taken only signed by Nova's key" {
  test_key
  export NOVA_UPDATE_KEY=$TEST_KEY
  serve_release release.toml release.toml.sig
  cp "$SCRATCH/release.toml" "$SCRATCH/served/"
  test_sign "$SCRATCH/served/release.toml"
  run "$REPO_ROOT/src/cli/bin/nova-update" --version v1.0.0-beta.2 --yes
  [ "$status" -eq 0 ]
  grep -q '^nova-update-apply --tag v1.0.0-beta.2' "$CALLS"
}

@test "a release.toml changed after it was signed changes nothing" {
  test_key
  export NOVA_UPDATE_KEY=$TEST_KEY
  serve_release release.toml release.toml.sig
  cp "$SCRATCH/release.toml" "$SCRATCH/served/"
  test_sign "$SCRATCH/served/release.toml"
  sed -i 's|example.org/repo|example.net/repo|' "$SCRATCH/served/release.toml"
  run "$REPO_ROOT/src/cli/bin/nova-update" --version v1.0.0-beta.2 --yes
  [ "$status" -ne 0 ]
  [[ $output == *"not signed by Nova's key"* ]]
  ! grep -q '^nova-update-apply' "$CALLS"
}

@test "a release.toml signed by another key, or not at all, changes nothing" {
  test_key
  serve_release release.toml release.toml.sig
  cp "$SCRATCH/release.toml" "$SCRATCH/served/"
  test_sign "$SCRATCH/served/release.toml"
  # Nova's key is some other one.
  export NOVA_UPDATE_KEY=$SCRATCH/other-key.asc
  GNUPGHOME=$SCRATCH/gnupg-other
  mkdir -m 700 "$GNUPGHOME"
  gpg --batch --quiet --passphrase '' --quick-gen-key 'Other <other@example.org>' ed25519 sign never 2>/dev/null
  gpg --batch --armor --export >"$NOVA_UPDATE_KEY"
  gpgconf --kill all
  run "$REPO_ROOT/src/cli/bin/nova-update" --version v1.0.0-beta.2 --yes
  [ "$status" -ne 0 ]
  [[ $output == *"not signed by Nova's key"* ]]

  serve_release release.toml
  run "$REPO_ROOT/src/cli/bin/nova-update" --version v1.0.0-beta.2 --yes
  [ "$status" -ne 0 ]
  [[ $output == *"has no release.toml.sig"* ]]
  ! grep -q '^nova-update-apply' "$CALLS"
}

@test "a used-up rate limit says so" {
  export NOVA_UPDATE_CACHE="$SCRATCH/cache"
  stub curl 'while (($#)); do [[ $1 == -o ]] && out=$2; shift; done; echo "{}" >"$out"; printf 403'
  run "$REPO_ROOT/src/cli/bin/nova-update" --check
  [ "$status" -ne 0 ]
  [[ $output == *"rate limit"* ]]
}

# A system on the release before, pinned to the Arch snapshot of <date>.
pinned() { # date
  printf '# nova-release: v1.0.0-beta.1\n# arch-date: %s\n' "$1" >"$NOVA_MIRRORLIST"
  printf '# nova-release: v1.0.0-beta.1\n' >"$NOVA_REPOFILE"
}

@test "an update moves to the release's Arch snapshot" {
  pinned 2026/10/06
  run update
  [ "$status" -eq 0 ]
  [[ $output == *"Arch snapshot  2026/10/06 -> 2026/10/19"* ]]
  grep -q -- '--arch-date 2026/10/19 --nova-repo https://example.org/repo --from v1.0.0-beta.1' "$CALLS"
}

@test "an update does not go back to an older Arch snapshot unless asked" {
  pinned 2026/10/27
  run update
  [ "$status" -ne 0 ]
  [[ $output == *"older than what is installed (nova 1.0.0beta.1, Arch snapshot 2026/10/27)"* ]]
  fails grep -q nova-update-apply "$CALLS"
}

@test "going back to a release whose packages are gone says so, and changes nothing" {
  pinned 2026/10/27
  stub curl 'printf 404'
  run "$REPO_ROOT/src/cli/bin/nova-update" --release-file "$SCRATCH/release.toml" --yes --allow-downgrade
  [ "$status" -ne 0 ]
  [[ $output == *"v1.0.0-beta.2's packages are no longer kept"* ]]
  [[ $output == *"nova recovery"* ]]
  fails grep -q nova-update-apply "$CALLS"
  grep -q '^curl .*https://example.org/repo/nova.db' "$CALLS"
  # Still there, or a bucket that cannot be asked: pacman has the last word.
  for answer in 200 ''; do
    stub curl "printf '$answer'"
    run "$REPO_ROOT/src/cli/bin/nova-update" --release-file "$SCRATCH/release.toml" --yes --allow-downgrade
    [ "$status" -eq 0 ]
    grep -q -- '^nova-update-apply .*--allow-downgrade' "$CALLS"
    : >"$CALLS"
  done
}

@test "a system pinned to no snapshot yet moves to the release's" {
  run update
  [ "$status" -eq 0 ]
  [[ $output == *"Arch snapshot  unpinned -> 2026/10/19"* ]]
}

@test "stable machines reject candidate tags and pre-release flags from latest" {
  echo 1.0.0 >"$PKGVER"
  export NOVA_UPDATE_CACHE="$SCRATCH/cache" NOVA_UPDATE_CANDIDATES="$SCRATCH/candidates"
  stub curl 'while (($#)); do [[ $1 == -o ]] && out=$2; shift; done
    cp "$SCRATCH/latest.json" "$out"
    printf 200'
  for release in '{"tag_name":"v1.1.0-rc.1","prerelease":false}' '{"tag_name":"v1.1.0","prerelease":true}'; do
    echo "$release" >"$SCRATCH/latest.json"
    run "$REPO_ROOT/src/cli/bin/nova-update" --check
    [ "$status" -eq 0 ]
    [ "$output" = current ]
    [ ! -e "$NOVA_UPDATE_CACHE" ]
    run "$REPO_ROOT/src/cli/bin/nova-update" --yes
    [ "$status" -eq 0 ]
    [[ $output == *"No final Nova release is published yet"* ]]
  done
  # Nothing applied: the check asks only what a repair would do.
  [ -z "$(grep '^nova-update-apply' "$CALLS" | grep -vx 'nova-update-apply --repairs')" ]
  # The check offers a repair with no release to move to, so the run makes it,
  # and nothing else.
  printf '%s\n' "Installing this computer's graphics drivers: lib32-vulkan-intel" >"$SCRATCH/repairs"
  run "$REPO_ROOT/src/cli/bin/nova-update" --check
  [ "$output" = repair ]
  : >"$CALLS"
  run "$REPO_ROOT/src/cli/bin/nova-update" --yes
  [ "$status" -eq 0 ]
  [[ $output == *"This computer needs a repair"* ]]
  [ "$(grep -c '^pkexec' "$CALLS")" -eq 1 ]
  grep -qx 'pkexec .*/nova-update-apply --repair --noconfirm' "$CALLS"
}

@test "an interrupted update retries even when its nova package is already installed" {
  echo 1.0.0beta.2 >"$PKGVER"
  printf '# nova-release: v1.0.0-beta.2\n' >"$NOVA_REPOFILE"
  printf 'old repo' >"$NOVA_REPOFILE.nova-prev"
  run update
  [ "$status" -eq 0 ]
  [[ $output == *"an earlier update did not finish"* ]]
  [[ $output == *"nova update --version v1.0.0-beta.2 --yes"* ]]
  grep -q '^nova-update-apply --tag v1.0.0-beta.2' "$CALLS"
}

@test "the latest-release shortcut also waits for unfinished boot checks" {
  echo 1.0.0beta.2 >"$PKGVER"
  mkdir -p "$NOVA_UPDATE_SYNC_DIR.nova-prev"
  serve_release release.toml release.toml.sig
  cp "$SCRATCH/release.toml" "$SCRATCH/served/release.toml"
  touch "$SCRATCH/served/release.toml.sig"
  stub gpg 'cat'
  stub gpgv
  export NOVA_UPDATE_KEY="$SCRATCH/key"
  touch "$NOVA_UPDATE_KEY"
  # The candidate list and its assets are the same release already installed.
  cat >"$SCRATCH/list.json" <<'JSON'
[{"tag_name":"v1.0.0-beta.2","draft":false,"assets":[{"name":"release.toml","browser_download_url":"https://dl.example.org/release.toml"},{"name":"release.toml.sig","browser_download_url":"https://dl.example.org/release.toml.sig"}]}]
JSON
  stub curl 'while (($#)); do [[ $1 == -o ]] && out=$2; url=$1; shift; done
    case $url in
      *"/releases?"*) cp "$SCRATCH/list.json" "$out" ;;
      https://dl.example.org/*) cp "$SCRATCH/served/${url##*/}" "$out" ;;
    esac
    printf 200'
  run "$REPO_ROOT/src/cli/bin/nova-update" --yes
  [ "$status" -eq 0 ]
  [[ $output != *"Nova is up to date"* ]]
  grep -q '^nova-update-apply --tag v1.0.0-beta.2' "$CALLS"
}

@test "--check-boot runs the root half's boot check and nothing else" {
  stub nova-update-apply 'exit 3'
  run "$REPO_ROOT/src/cli/bin/nova-update" --check-boot
  [ "$status" -eq 3 ]
  [ "$(cat "$CALLS")" = "pkexec $NOVA_UPDATE_APPLY --check-boot
nova-update-apply --check-boot" ]
}

# --- Settings: nova update --status, with no terminal ---------------------------

# The apps' builds: Chrome built into the folder it is given, and recorded.
build_chrome() {
  stub nova-apps-install 'case $1 in
    --build) printf "built google-chrome %s %s\n" "$(printf a%.0s {1..40})" "$2/google-chrome-141.0-1-x86_64.pkg.tar.zst" >>"$2/result" ;;
  esac'
}

settings_update() { # extra arguments
  "$REPO_ROOT/src/cli/bin/nova-update" --release-file "$SCRATCH/release.toml" --status "$SCRATCH/run/status.json" "$@"
}

field() { jq -c ".$1" "$SCRATCH/run/status.json"; }

@test "Settings: one authentication installs the release with the apps built for it" {
  export XDG_CACHE_HOME=$SCRATCH/cache
  build_chrome
  stub pacman 'case $2 in google-chrome) echo "google-chrome 141.0-1" ;; *) echo "nova $(cat "$PKGVER")-1" ;; esac'
  stub nova-update-apply 'echo 1.0.0beta.2 >"$PKGVER"
    echo "==> pacman -Su --noconfirm"
    echo "The running kernel was replaced: restart to finish the update."
    echo "Nova is now on v1.0.0-beta.2."'
  stub nova-notification-send
  run settings_update
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(field state)" = '"done"' ]
  [ "$(field progress)" = 100 ]
  [ "$(field version)" = '"1.0.0-beta.2"' ]
  [ "$(field restart)" = true ]
  [ "$(field apps)" = '["google-chrome"]' ]
  # Built first, then one root step for both, then remembered.
  [ "$(grep -oE '^(nova-apps-install --[a-z]+|pkexec)' "$CALLS" | paste -sd' ')" = \
    "nova-apps-install --build pkexec nova-apps-install --record" ]
  grep -qE "^pkexec $NOVA_UPDATE_APPLY --tag v1.0.0-beta.2 .*--noconfirm --package $XDG_CACHE_HOME/nova/update-build\.[^/]+/google-chrome-141.0-1-x86_64.pkg.tar.zst\$" "$CALLS"
  grep -qx 'nova-apps-install --build .* --update' "$CALLS"
  grep -qx "nova-apps-install --record google-chrome $(printf a%.0s {1..40})" "$CALLS"
  grep -q '^nova-notification-send .*Restart to finish the update Nova 1.0.0-beta.2 is installed.' "$CALLS"
  # The shell last, after Settings has the result, and the session's
  # restarts with it.
  [ "$(tail -n 2 "$CALLS" | paste -sd,)" = 'nova-restart-shell ,nova-session-settle restart' ]
  grep -q 'Nova is now on v1.0.0-beta.2.' "$SCRATCH/run/status.log"
  [ -z "$(ls "$XDG_CACHE_HOME/nova")" ]
}

@test "Settings: a dismissed authentication changes nothing and says so" {
  export XDG_CACHE_HOME=$SCRATCH/cache
  build_chrome
  stub pkexec 'exit 126'
  run settings_update
  [ "$(field state)" = '"cancelled"' ]
  [ "$(field apps)" = '[]' ]
  fails grep -q -- '--record' "$CALLS"
  fails grep -q nova-restart-shell "$CALLS"
}

@test "Settings: a root step that fails says why" {
  stub nova-update-apply 'echo "nova update: pacman failed; check its output above." >&2; exit 1'
  stub nova-notification-send
  run settings_update
  [ "$(field state)" = '"failed"' ]
  [ "$(field error)" = '"pacman failed; check its output above."' ]
  grep -q '^nova-notification-send .*The update did not finish Pacman failed; check its output above.' "$CALLS"
}

@test "Settings: what stops it before the root step says why, also with the window closed" {
  printf 'version = "1.0.0-beta.2"\narch_date = "yesterday"\n' >"$SCRATCH/release.toml"
  stub nova-notification-send
  run settings_update
  [ "$status" -ne 0 ]
  [ "$(field state)" = '"failed"' ]
  [[ $(field error) == *"bad arch_date"* ]]
  fails grep -q pkexec "$CALLS"
  [ "$(grep -c '^nova-notification-send .*The update did not finish Release.toml has a bad arch_date' "$CALLS")" -eq 1 ]
}

@test "Settings: building one reviewed app, the other still waits for its review" {
  mkdir -p "$SCRATCH/run"
  echo '{"state":"done","held":["google-chrome","visual-studio-code-bin"]}' >"$SCRATCH/run/status.json"
  build_chrome
  stub pacman 'case $2 in google-chrome) echo "google-chrome 141.0-1" ;; *) echo "nova $(cat "$PKGVER")-1" ;; esac'
  run settings_update --apps-only --only google-chrome --approve "google-chrome=$(printf b%.0s {1..40})"
  [ "$(field state)" = '"done"' ]
  [ "$(field apps)" = '["google-chrome"]' ]
  [ "$(field held)" = '["visual-studio-code-bin"]' ]
}

@test "Settings: an app whose recipe changed waits, says nothing, and nothing else is asked" {
  echo 1.0.0beta.2 >"$PKGVER"
  stub nova-apps-install 'case $1 in --build) echo "held visual-studio-code-bin" >>"$2/result" ;; esac'
  stub nova-notification-send
  run settings_update
  [ "$(field state)" = '"done"' ]
  [ "$(field held)" = '["visual-studio-code-bin"]' ]
  fails grep -q pkexec "$CALLS"
  fails grep -q nova-notification-send "$CALLS"
}

@test "Settings: Nova already current, with nothing else to do, says nothing" {
  echo 1.0.0beta.2 >"$PKGVER"
  stub nova-notification-send
  run settings_update
  [ "$(field state)" = '"done"' ]
  fails grep -q pkexec "$CALLS"
  fails grep -q nova-notification-send "$CALLS"
}

@test "Settings: with Nova current, a repair goes in the one root step with the apps" {
  echo 1.0.0beta.2 >"$PKGVER"
  printf '%s\n' "Removing NVIDIA drivers this computer cannot use: nvidia-utils" >"$SCRATCH/repairs"
  export XDG_CACHE_HOME=$SCRATCH/cache
  build_chrome
  stub pacman 'case $2 in google-chrome) echo "google-chrome 141.0-1" ;; *) echo "nova $(cat "$PKGVER")-1" ;; esac'
  stub nova-notification-send
  run settings_update
  [ "$(field state)" = '"done"' ]
  [ "$(grep -c '^pkexec' "$CALLS")" -eq 1 ]
  grep -qE '^pkexec .*/nova-update-apply --repair --noconfirm --package [^ ]+/google-chrome-141.0-1-x86_64.pkg.tar.zst$' "$CALLS"
}

@test "Settings: with Nova current, an app updated is in the state, and not a notification" {
  echo 1.0.0beta.2 >"$PKGVER"
  build_chrome
  stub pacman 'case $2 in google-chrome) echo "google-chrome 141.0-1" ;; *) echo "nova $(cat "$PKGVER")-1" ;; esac'
  stub nova-notification-send
  run settings_update
  [ "$(field state)" = '"done"' ]
  [ "$(field apps)" = '["google-chrome"]' ]
  fails grep -q '^nova-notification-send' "$CALLS"
}

@test "Settings: Flathub's apps updated last, and named when they could not be" {
  echo app/org.gimp.GIMP/x86_64/stable >"$SCRATCH/flatpak-user"
  run settings_update
  [ "$(field state)" = '"done"' ]
  grep -qx 'flatpak update --user -y --noninteractive' "$CALLS"
  echo 1 >"$SCRATCH/flatpak-status"
  run settings_update
  [ "$(field state)" = '"problems"' ]
  [ "$(field failed)" = '["flathub"]' ]
}

@test "Settings: the session's services move right after the root step, before the apps and Flathub, and once" {
  export XDG_CACHE_HOME=$SCRATCH/cache
  build_chrome
  stub pacman 'case $2 in google-chrome) echo "google-chrome 141.0-1" ;; *) echo "nova $(cat "$PKGVER")-1" ;; esac'
  echo app/org.gimp.GIMP/x86_64/stable >"$SCRATCH/flatpak-user"
  run settings_update
  [ "$(field state)" = '"done"' ]
  [ "$(grep -oE '^(pkexec|nova-session-settle [a-z]+|nova-apps-install --record|flatpak update|nova-restart-shell)' "$CALLS" | paste -sd,)" = \
    "pkexec,nova-session-settle services,nova-apps-install --record,flatpak update,nova-restart-shell,nova-session-settle restart" ]
}

@test "Settings: a release that went in moves the session's services even when the rest failed" {
  stub nova-update-apply 'echo 1.0.0beta.2 >"$PKGVER"; exit 3'
  stub nova-notification-send
  run settings_update
  [ "$(field state)" = '"failed"' ]
  [ "$(grep -c '^nova-session-settle services' "$CALLS")" = 1 ]
}

@test "Settings: nothing installed, the session's services are left alone" {
  stub pkexec 'exit 126'
  run settings_update
  [ "$(field state)" = '"cancelled"' ]
  fails grep -q nova-session-settle "$CALLS"
}

@test "Settings: Nova installed with no restart to wait for says nothing" {
  stub nova-notification-send
  run settings_update
  [ "$(field state)" = '"done"' ]
  [ "$(field version)" = '"1.0.0-beta.2"' ]
  [ "$(field restart)" = false ]
  fails grep -q nova-notification-send "$CALLS"
}

@test "Settings: a reviewed app alone, approved for its commit" {
  build_chrome
  stub pacman 'case $2 in google-chrome) echo "google-chrome 141.0-1" ;; *) echo "nova $(cat "$PKGVER")-1" ;; esac'
  run settings_update --apps-only --only google-chrome --approve "google-chrome=$(printf b%.0s {1..40})"
  [ "$(field state)" = '"done"' ]
  grep -qx "nova-apps-install --build .* --update --only google-chrome --approve google-chrome=$(printf b%.0s {1..40})" "$CALLS"
  grep -qE "^pkexec $NOVA_UPDATE_APPLY --packages-only --package [^ ]+/google-chrome-141.0-1-x86_64.pkg.tar.zst\$" "$CALLS"
  fails grep -q -- '--tag' "$CALLS"
}

@test "Settings: an app that did not go in is not remembered as built, and the run has problems" {
  build_chrome
  stub nova-update-apply 'echo 1.0.0beta.2 >"$PKGVER"; exit 4'
  run settings_update
  [ "$status" -eq 4 ]
  [ "$(field state)" = '"problems"' ]
  [ "$(field failed)" = '["google-chrome"]' ]
  [ "$(field progress)" = 100 ]
  fails grep -q -- '--record' "$CALLS"
  grep -qx "nova-notification-send -u normal -g 󰚰 Chrome could not be updated Settings → Updates tries again. --exec nova-shell shell summon nova.settings {\"page\":\"updates\"}" "$CALLS"
}

@test "Settings: an app that did not build, beside a release that waits for a restart, says both" {
  stub nova-apps-install 'case $1 in --build) echo "failed visual-studio-code-bin" >>"$2/result" ;; esac'
  stub nova-update-apply 'echo 1.0.0beta.2 >"$PKGVER"
    echo "The running kernel was replaced: restart to finish the update."'
  run settings_update
  [ "$status" -eq 4 ]
  [ "$(field state)" = '"problems"' ]
  [ "$(field restart)" = true ]
  grep -q '^nova-notification-send -u normal -g 󰚰 VS Code could not be updated Nova 1.0.0-beta.2 is installed: restart to finish it. Settings → Updates tries VS Code again.' "$CALLS"
  # Nova itself is in: the shell moves onto it all the same.
  [ "$(tail -n 2 "$CALLS" | paste -sd,)" = 'nova-restart-shell ,nova-session-settle restart' ]
}

@test "Settings: a run that ends ends as nova update would in a terminal" {
  run settings_update
  [ "$status" -eq 0 ]
  echo 1.0.0beta.1 >"$PKGVER"
  stub nova-update-apply 'exit 3'
  run settings_update
  [ "$status" -eq 3 ]
  stub pkexec 'exit 126'
  run settings_update
  [ "$status" -eq 2 ]
}

@test "Settings: the root step speaks English, as how far it is reads its lines" {
  # pacman's lines are translated; the progress reads the English ones.
  stub pkexec 'echo "LC_ALL=$LC_ALL" >"$SCRATCH/locale"; "$@"'
  LANG=it_IT.UTF-8 LANGUAGE=it run settings_update
  [ "$status" -eq 0 ]
  [ "$(cat "$SCRATCH/locale")" = "LC_ALL=C.UTF-8" ]
}

@test "Settings: how far it is follows the steps and pacman's packages" {
  STATUS=$SCRATCH/status.json
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/cli/bin/nova-update"
  status_write() { echo "$st_progress $st_text" >>"$SCRATCH/progress"; }
  release_flags=(--tag v1.0.0)
  track >/dev/null <<'OUT'
==> Taking the pre-update snapshot
==> Updating the keyrings
==> pacman -Su --noconfirm
Packages (4) a-1-1  b-1-1  c-1-1  d-1-1
 a-1-1-x86_64 downloading...
 b-1-1-x86_64 downloading...
:: Processing package changes...
upgrading a...
upgrading b...
installing c...
removing d...
:: Running post-transaction hooks...
(1/2) Arming ConditionNeedsUpdate...
(2/2) Building the boot images...
==> Installing google-chrome
Packages (1) google-chrome-141.0-1
installing google-chrome...
==> Checking the boot entries
The NVIDIA driver was updated: restart to finish the update.
OUT
  [ "$(cut -d' ' -f1 "$SCRATCH/progress" | paste -sd' ')" = "1 3 5 13 22 50 61 71 82 82 87 92 93 97" ]
  grep -qx '50 Installing' "$SCRATCH/progress"
  grep -qx '87 Finishing' "$SCRATCH/progress"
  [ "$st_restart" = 1 ]
}

@test "Settings: building says which app, not what makepkg is at" {
  STATUS=$SCRATCH/status.json
  # shellcheck source=/dev/null
  source "$REPO_ROOT/src/cli/bin/nova-update"
  status_write() { echo "$st_progress $st_text" >>"$SCRATCH/progress"; }
  export XDG_CACHE_HOME=$SCRATCH/cache
  stub nova-apps-install 'echo "==> google-chrome"; echo "==> Making package: google-chrome 141.0-1" >&2
    echo "==> Retrieving sources..." >&2; echo "==> visual-studio-code-bin"'
  APPS=$SCRATCH/bin/nova-apps-install
  local -a packages=() built=()
  build_apps >/dev/null
  [ "$(cat "$SCRATCH/progress")" = "-1 Building Chrome
-1 Building VS Code" ]
}

@test "nova-update-run starts it as a user service of its own, one at a time" {
  export XDG_RUNTIME_DIR=$SCRATCH/xdg
  stub systemctl 'exit 3'
  stub systemd-run
  run "$REPO_ROOT/src/cli/bin/nova-update-run" --apps-install
  [ "$status" -eq 0 ]
  grep -qx "systemd-run --user --quiet --collect --unit=nova-update --service-type=exec --setenv=PATH=$PATH -- $REPO_ROOT/src/cli/bin/nova-update --status $XDG_RUNTIME_DIR/nova/update/status.json --apps-install" "$CALLS"
  : >"$CALLS"
  stub systemctl
  run "$REPO_ROOT/src/cli/bin/nova-update-run"
  [ "$status" -eq 0 ]
  fails grep -q systemd-run "$CALLS"
}
