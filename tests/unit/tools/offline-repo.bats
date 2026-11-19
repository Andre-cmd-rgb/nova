#!/usr/bin/env bats

# tools/offline-repo: the packages the ISO carries, so that a stick installs
# without a network. Sourced, it only defines its functions; nothing here
# reaches a network or a real pacman cache.

load ../test_helper

setup() {
  setup_scratch
  # shellcheck source=/dev/null
  source "$REPO_ROOT/tools/offline-repo"
  mkdir -p "$SCRATCH/repo" "$SCRATCH/pkg"
  URLS=$SCRATCH/urls
  pacman-conf() { echo "$SCRATCH/pkg"; }
}

teardown() { teardown_scratch; }

# A curl that keeps its config and writes each file it is asked for.
serving_curl() {
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
}

@test "packages: names a stick's FAT can hold, each with its signature" {
  printf 'https://archive.archlinux.org/repos/2026/10/01/extra/os/x86_64/ffmpeg-2:7.1-1-x86_64.pkg.tar.zst\t100\n' >"$URLS"
  printf 'https://nova-packages.piserver.stream/v1.0.0/nova-1.0.0-1-any.pkg.tar.zst\t50\n' >>"$URLS"
  printf 'https://example.org/repo/libc%%2B%%2B-1-1-x86_64.pkg.tar.zst\t10\n' >>"$URLS"
  curl() { cp -- "${@: -1}" "$SCRATCH/curl.config"; }
  download_packages "$URLS" /stick/repo
  grep -qx 'output = "/stick/repo/ffmpeg-2_7.1-1-x86_64.pkg.tar.zst"' "$SCRATCH/curl.config"
  grep -qx 'output = "/stick/repo/ffmpeg-2_7.1-1-x86_64.pkg.tar.zst.sig"' "$SCRATCH/curl.config"
  grep -qx 'url = "https://archive.archlinux.org/repos/2026/10/01/extra/os/x86_64/ffmpeg-2:7.1-1-x86_64.pkg.tar.zst.sig"' "$SCRATCH/curl.config"
  grep -qx 'output = "/stick/repo/nova-1.0.0-1-any.pkg.tar.zst"' "$SCRATCH/curl.config"
  grep -qx 'output = "/stick/repo/libc++-1-1-x86_64.pkg.tar.zst"' "$SCRATCH/curl.config"
}

@test "packages: a name that decodes to a path is refused, and nothing is fetched" {
  printf 'https://example.org/repo/..%%2F..%%2Fetc%%2Fcron.d%%2Fx.pkg.tar.zst\t10\n' >"$URLS"
  curl() { touch "$SCRATCH/curl.ran"; }
  run download_packages "$URLS" /stick/repo
  [ "$status" -ne 0 ]
  [[ $output == *refusing* ]]
  [ ! -e "$SCRATCH/curl.ran" ]
}

@test "packages: a cache entry is taken only with the same name, size and a signature" {
  printf 'https://example.org/a-1-1-any.pkg.tar.zst\t4\n' >"$URLS"
  serving_curl
  printf data >"$SCRATCH/pkg/a-1-1-any.pkg.tar.zst"
  printf signed >"$SCRATCH/pkg/a-1-1-any.pkg.tar.zst.sig"
  download_packages "$URLS" "$SCRATCH/repo"
  [ ! -e "$SCRATCH/curl.config" ]
  [ "$(cat "$SCRATCH/repo/a-1-1-any.pkg.tar.zst.sig")" = signed ]
  printf wrong-size >"$SCRATCH/pkg/a-1-1-any.pkg.tar.zst"
  download_packages "$URLS" "$SCRATCH/repo"
  [ -e "$SCRATCH/curl.config" ]
  rm "$SCRATCH/curl.config" "$SCRATCH/pkg/a-1-1-any.pkg.tar.zst.sig"
  printf data >"$SCRATCH/pkg/a-1-1-any.pkg.tar.zst"
  download_packages "$URLS" "$SCRATCH/repo"
  [ -e "$SCRATCH/curl.config" ]
}

@test "offline_conf: the release's own snapshot, and its repository or the copy given" {
  printf 'version = "1.0.0"\narch_date = "2026/10/01"\nnova_repo = "https://nova-packages.piserver.stream/v1.0.0"\n' >"$SCRATCH/release.toml"
  run offline_conf "$SCRATCH/release.toml"
  [ "$status" -eq 0 ]
  [[ $output == *'Server = https://archive.archlinux.org/repos/2026/10/01/$repo/os/$arch'* ]]
  [[ $output == *'Server = https://nova-packages.piserver.stream/v1.0.0'* ]]
  run offline_conf "$SCRATCH/release.toml" "$SCRATCH/repo"
  [[ $output == *"Server = file://$SCRATCH/repo"* ]]
  [[ $output != *piserver* ]]
  printf 'arch_date = "yesterday"\n' >"$SCRATCH/bad.toml"
  run offline_conf "$SCRATCH/bad.toml"
  [ "$status" -ne 0 ]
}

@test "resolve_packages: two that conflict are resolved one at a time, and each package is listed once" {
  package_urls() {
    shift 2
    (($# == 1)) || return 1
    printf 'https://example.org/%s-1-1-any.pkg.tar.zst\t1\nhttps://example.org/shared-1-1-any.pkg.tar.zst\t1\n' "$1"
  }
  run resolve_packages conf db nvidia-open nvidia-open-nova
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "$(grep -c shared <<<"$output")" -eq 1 ]
  package_urls() { return 1; }
  run resolve_packages conf db missing
  [ "$status" -ne 0 ]
}

@test "make_offline_repo: the database under both names pacman reads, and no link a stick's FAT cannot hold" {
  mkdir -p "$SCRATCH/bin"
  cat >"$SCRATCH/bin/repo-add" <<'STUB'
#!/bin/sh
printf database >"$2"
ln -s "${2##*/}" "${2%.tar.gz}"
STUB
  chmod +x "$SCRATCH/bin/repo-add"
  PATH="$SCRATCH/bin:$PATH"
  printf data >"$SCRATCH/repo/a-1-1-any.pkg.tar.zst"
  make_offline_repo "$SCRATCH/repo"
  [ "$(cat "$SCRATCH/repo/nova-offline.db")" = database ]
  [ "$(cat "$SCRATCH/repo/nova-offline.db.tar.gz")" = database ]
  [ -z "$(find "$SCRATCH/repo" -type l)" ]
}

@test "the command: a release file, a package list and one folder, or it says how" {
  run "$REPO_ROOT/tools/offline-repo" --release "$SCRATCH/none.toml" --packages "$SCRATCH/none.txt" "$SCRATCH/out"
  [ "$status" -ne 0 ]
  [[ $output == *usage* ]]
  printf 'arch_date = "2026/10/01"\n' >"$SCRATCH/release.toml"
  echo nova >"$SCRATCH/packages.txt"
  run "$REPO_ROOT/tools/offline-repo" --release "$SCRATCH/release.toml" --packages "$SCRATCH/packages.txt" --nova "$SCRATCH/empty" "$SCRATCH/out"
  [ "$status" -ne 0 ]
  [[ $output == *"no [nova] repository"* ]]
  [ ! -e "$SCRATCH/out" ]
}
