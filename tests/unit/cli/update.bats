#!/usr/bin/env bats

# nova update, end to end with the root step, the system and the app builds
# stubbed: what it does after a release is applied.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" PKGVER="$SCRATCH/pkgver"
  export NOVA_MIRRORLIST="$SCRATCH/nova-mirrorlist" NOVA_REPOFILE="$SCRATCH/nova-repo"
  export NOVA_ALARMFILE="$SCRATCH/nova-alarm" NOVA_ARCH=x86_64
  export NOVA_UPDATE_SYNC_DIR="$SCRATCH/sync"
  export NOVA_UPDATE_APPLY="$SCRATCH/bin/nova-update-apply" NOVA_UPDATE_APPS="$SCRATCH/bin/nova-apps-install"
  mkdir -p "$SCRATCH/bin"
  echo 1.0.0beta.1 >"$PKGVER"
  printf 'version = "1.0.0-beta.2"\narch_date = "2026/10/19"\nnova_repo = "https://example.org/repo"\n' >"$SCRATCH/release.toml"
  stub pacman 'echo "nova $(cat "$PKGVER")-1"'
  stub pacman-conf
  stub pkexec '"$@"'
  stub nova-update-apply 'echo 1.0.0beta.2 >"$PKGVER"'
  stub nova-shell
  stub nova-restart-shell
  stub nova-apps-install 'echo current'
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

@test "no shell running, none started" {
  stub nova-shell 'exit 1'
  run update
  [ "$status" -eq 0 ]
  ! grep -q nova-restart-shell "$CALLS"
}

@test "nova unchanged, the shell is left alone" {
  stub nova-update-apply
  run update
  [ "$status" -eq 0 ]
  ! grep -q nova-restart-shell "$CALLS"
}

@test "a failed update restarts nothing" {
  stub nova-update-apply 'exit 3'
  run update
  [ "$status" -eq 3 ]
  ! grep -q nova-restart-shell "$CALLS"
}

@test "a shell that will not restart is a warning, not a failed update" {
  stub nova-restart-shell 'exit 1'
  run update
  [ "$status" -eq 0 ]
  [[ $output == *"log out and back in"* ]]
}

@test "Chrome and VS Code are updated after the release" {
  run update
  [ "$status" -eq 0 ]
  [ "$(grep -oE '^(nova-update-apply|nova-apps-install)' "$CALLS" | paste -sd' ')" = "nova-update-apply nova-apps-install" ]
  grep -qx 'nova-apps-install --update --noconfirm' "$CALLS"
}

@test "with Nova already current, the apps are still updated" {
  echo 1.0.0beta.2 >"$PKGVER"
  run update
  [ "$status" -eq 0 ]
  fails grep -q nova-update-apply "$CALLS"
  grep -qx 'nova-apps-install --update --noconfirm' "$CALLS"
}

@test "a failed update leaves the apps alone" {
  stub nova-update-apply 'exit 3'
  run update
  [ "$status" -eq 3 ]
  ! grep -q nova-apps-install "$CALLS"
}

@test "apps that will not build are a warning, not a failed update" {
  stub nova-apps-install 'exit 1'
  run update
  [ "$status" -eq 0 ]
  [[ $output == *"nova apps update tries again"* ]]
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

# A release with a Raspberry Pi build, and a Pi on the release before it.
pi_release() {
  export NOVA_ARCH=aarch64
  printf 'alarm_date = "2026/10/20"\nalarm_pool = "https://example.org/alarm/aarch64"\n' >>"$SCRATCH/release.toml"
  printf '# nova-release: v1.0.0-beta.1\n# alarm-date: 2026/10/06\n' >"$NOVA_ALARMFILE"
  printf '# nova-release: v1.0.0-beta.1\n' >"$NOVA_REPOFILE"
}

@test "a Pi moves to the release's Arch Linux ARM set" {
  pi_release
  run update
  [ "$status" -eq 0 ]
  [[ $output == *"Arch Linux ARM 2026/10/06 -> 2026/10/20"* ]]
  grep -q -- '--alarm-date 2026/10/20 --alarm-pool https://example.org/alarm/aarch64 --from v1.0.0-beta.1' "$CALLS"
}

@test "a release without a Raspberry Pi build changes nothing on a Pi" {
  export NOVA_ARCH=aarch64
  run update
  [ "$status" -ne 0 ]
  [[ $output == *"v1.0.0-beta.2 has no Raspberry Pi build; nothing was changed"* ]]
  fails grep -q nova-update-apply "$CALLS"
}

@test "a Pi does not go back to an older Arch Linux ARM set unless asked" {
  pi_release
  printf '# nova-release: v1.0.0-beta.1\n# alarm-date: 2026/10/27\n' >"$NOVA_ALARMFILE"
  run update
  [ "$status" -ne 0 ]
  [[ $output == *"older than what is installed (nova 1.0.0beta.1, Arch Linux ARM 2026/10/27)"* ]]
  fails grep -q nova-update-apply "$CALLS"
}

@test "a PC's update says nothing of Arch Linux ARM" {
  pi_release
  export NOVA_ARCH=x86_64
  run update
  [ "$status" -eq 0 ]
  [[ $output == *"Arch snapshot  unpinned -> 2026/10/19"* ]]
  fails grep -q -- --alarm "$CALLS"
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
  fails grep -q '^nova-update-apply' "$CALLS"
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
