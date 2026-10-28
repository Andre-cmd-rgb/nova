#!/usr/bin/env bats

# The release gate chooses an actual predecessor, never a draft or a newer
# version, and never turns a failed GitHub request into a successful skip.
load ../test_helper

setup() {
  setup_scratch
  # shellcheck source=tests/install/upgrade-lib
  source "$REPO_ROOT/tests/install/upgrade-lib"
}

teardown() {
  [[ -z ${repo_pid:-} ]] || { kill "$repo_pid" 2>/dev/null || true; wait "$repo_pid" 2>/dev/null || true; }
  teardown_scratch
}

releases() { # tag...; all published, candidates included
  printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(length > 0) | {tag_name: ., draft: false, prerelease: contains("-")})'
}

@test "previous release includes candidates and compares numeric package versions" {
  list=$(releases v1.0.0-beta.8 v1.0.0-beta.10 v1.0.0-beta.9)
  previous=$(previous_release v1.0.0 <<<"$list")
  [ "$(jq -r .tag_name <<<"$previous")" = v1.0.0-beta.10 ]
  [ "$(jq -r .prerelease <<<"$previous")" = true ]
}

@test "previous release excludes this tag, later releases, drafts and malformed tags" {
  list=$(releases v1.1.0 v1.0.0-rc.1 v1.0.0 v0.9.0 v2.0.0 not-a-tag)
  list=$(jq '. + [{tag_name: "v1.0.0-rc.2", draft: true}]' <<<"$list")
  [ "$(previous_release v1.0.0 <<<"$list" | jq -r .tag_name)" = v1.0.0-rc.1 ]
}

@test "previous release sorts a final release after its candidates" {
  list=$(releases v1.0.0-rc.9 v1.0.0 v0.9.9)
  [ "$(previous_release v1.1.0-rc.1 <<<"$list" | jq -r .tag_name)" = v1.0.0 ]
}

@test "no predecessor is a distinct result, including a re-run of the first tag" {
  run previous_release v1.0.0-beta.1 <<<'[]'
  [ "$status" -eq 4 ]
  list=$(releases v1.0.0-beta.1 v1.0.0)
  run previous_release v1.0.0-beta.1 <<<"$list"
  [ "$status" -eq 4 ]
}

@test "invalid JSON, an API error and an invalid target fail rather than skip" {
  run previous_release v1.0.0 <<<'broken JSON'
  [ "$status" -eq 1 ]
  run previous_release v1.0.0 <<<'{"message":"rate limit exceeded"}'
  [ "$status" -eq 1 ]
  run previous_release bad-tag <<<'[]'
  [ "$status" -eq 1 ]
}

@test "published releases reads past a full first page" {
  jq -n '[range(0;100) | {draft:false, tag_name:"v2.0.0"}]' >"$SCRATCH/page1"
  releases v1.0.0-beta.8 >"$SCRATCH/page2"
  curl() {
    case ${*: -1} in
      *'page=1') cat "$SCRATCH/page1" ;;
      *'page=2') cat "$SCRATCH/page2" ;;
      *) return 22 ;;
    esac
  }
  published_releases "$SCRATCH/releases.json"
  [ "$(jq length "$SCRATCH/releases.json")" -eq 101 ]
  [ "$(previous_release v1.0.0 <"$SCRATCH/releases.json" | jq -r .tag_name)" = v1.0.0-beta.8 ]
}

@test "published releases refuses failed requests, non-list answers and truncated pagination" {
  curl() { return 22; }
  run published_releases "$SCRATCH/releases.json"
  [ "$status" -ne 0 ]
  curl() { echo '{"message":"rate limit exceeded"}'; }
  run published_releases "$SCRATCH/releases.json"
  [ "$status" -ne 0 ]
  curl() { jq -n '[range(0;100) | {draft:false, tag_name:"v2.0.0"}]'; }
  run published_releases "$SCRATCH/releases.json"
  [ "$status" -ne 0 ]
  [[ $output == *'refusing to use an incomplete list'* ]]
}

@test "the upgrade runner skips cleanly before asking for KVM when no predecessor exists" {
  mkdir -p "$SCRATCH/bin" "$SCRATCH/repo"
  echo fixture >"$SCRATCH/repo/nova.db"
  printf 'version = "1.0.0-beta.1"\n' >"$SCRATCH/release.toml"
  printf '#!/bin/bash\necho "[]"\n' >"$SCRATCH/bin/curl"
  chmod +x "$SCRATCH/bin/curl"
  run env PATH="$SCRATCH/bin:$PATH" TMPDIR="$SCRATCH" "$REPO_ROOT/tests/install/run" \
    --upgrade --repo "$SCRATCH/repo" --release "$SCRATCH/release.toml"
  [ "$status" -eq 0 ]
  [[ $output == *'::notice::No published Nova release older than v1.0.0-beta.1'* ]]
}

@test "the upgrade runner fails on a GitHub error instead of skipping" {
  mkdir -p "$SCRATCH/bin" "$SCRATCH/repo"
  echo fixture >"$SCRATCH/repo/nova.db"
  printf 'version = "1.0.0"\n' >"$SCRATCH/release.toml"
  printf '#!/bin/bash\nexit 22\n' >"$SCRATCH/bin/curl"
  chmod +x "$SCRATCH/bin/curl"
  run env PATH="$SCRATCH/bin:$PATH" TMPDIR="$SCRATCH" "$REPO_ROOT/tests/install/run" \
    --upgrade --repo "$SCRATCH/repo" --release "$SCRATCH/release.toml"
  [ "$status" -ne 0 ]
  [[ $output == *'could not read the published releases'* ]]
  [[ $output != *'::notice::'* ]]
}

@test "the HTTPS repository needs the test CA and serves only its artifact directory" {
  mkdir "$SCRATCH/repo"
  echo 'the signed database' >"$SCRATCH/repo/nova.db"
  start_upgrade_repo "$SCRATCH" "$SCRATCH/repo"
  port=$(cat "$SCRATCH/repo.port")
  reply=$(curl -fsS --noproxy '*' --cacert "$SCRATCH/ca.crt" \
    --connect-to "10.0.2.2:$port:127.0.0.1:$port" "$upgrade_repo/nova.db")
  [ "$reply" = 'the signed database' ]
  run curl -fsS --noproxy '*' --connect-to "10.0.2.2:$port:127.0.0.1:$port" "$upgrade_repo/nova.db"
  [ "$status" -eq 60 ]
  run curl -fsS --noproxy '*' --cacert "$SCRATCH/ca.crt" \
    --connect-to "10.0.2.2:$port:127.0.0.1:$port" "$upgrade_repo/ca.key"
  [ "$status" -eq 22 ]
}

@test "the guest payload is valid Bash and carries the manifests without interpreting them" {
  here=$REPO_ROOT/tests/install
  printf 'version = "1.0.0-beta.8"\nnova_repo = "https://published.example/v1.0.0-beta.8"\n' >"$SCRATCH/previous.toml"
  printf 'version = "1.0.0"\narch_date = "2026/10/27"\nnova_repo = "https://10.0.2.2:12345"\n' >"$SCRATCH/candidate.toml"
  echo 'a certificate' >"$SCRATCH/ca.crt"
  upgrade_after "$SCRATCH" >"$SCRATCH/after"
  bash -n "$SCRATCH/after"
  grep -Fx 'nova_repo = "https://published.example/v1.0.0-beta.8"' "$SCRATCH/after"
  grep -Fx 'arch_date = "2026/10/27"' "$SCRATCH/after"
  grep -F 'ExecStart=/usr/local/lib/nova-upgrade-probe' "$SCRATCH/after"
}

@test "the guest keeps exactly the pre-update snapshot number reported by the updater" {
  source "$REPO_ROOT/tests/install/upgrade-probe"
  printf '==> Taking the pre-update snapshot\n==> Snapshot 17 taken\n==> Taking the post-update snapshot\n' >"$SCRATCH/update.log"
  [ "$(update_snapshot "$SCRATCH/update.log")" = 17 ]
  echo '==> Snapshot 19 taken' >>"$SCRATCH/update.log"
  run update_snapshot "$SCRATCH/update.log"
  [ "$status" -ne 0 ]
  echo 'an update that never took its snapshot' >"$SCRATCH/update.log"
  run update_snapshot "$SCRATCH/update.log"
  [ "$status" -ne 0 ]
}

@test "the old release uses its fallback guard and the upgraded release must pass check-boot" {
  source "$REPO_ROOT/tests/install/upgrade-probe"
  printf 'version = "1.0.0-beta.8"\narch_date = "2026/10/20"\nnova_repo = "https://published.example/repo"\n' >"$SCRATCH/previous.toml"
  pacman() { echo 'nova 1.0.0beta.8-1'; }
  check() { printf '%s\n' "$*"; }
  run release_checks "$SCRATCH/previous.toml"
  [ "$status" -eq 0 ]
  [[ $output == *'nova-boot-check status'* ]]
  [[ $output != *'nova-update-apply --check-boot'* ]]
  run release_checks "$SCRATCH/previous.toml" update
  [ "$status" -eq 0 ]
  [[ $output == *'nova-update-apply --check-boot'* ]]
}
