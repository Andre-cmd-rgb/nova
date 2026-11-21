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

@test "the release before is probed with its own probe, as its tag has it" {
  curl() {
    printf '%s\n' "$*" >"$SCRATCH/asked"
    local out=''
    while (($#)); do [[ $1 != -o ]] || out=$2; shift; done
    printf '#!/bin/bash\nprobe() {\n  probe_failures=0\n}\n' >"$out"
  }
  release_probe v1.0.0-rc.12 "$SCRATCH/probe"
  grep -q '^probe() {' "$SCRATCH/probe"
  grep -qF 'contents/tests/install/probe?ref=v1.0.0-rc.12' "$SCRATCH/asked"
  grep -qF 'application/vnd.github.raw' "$SCRATCH/asked"
  # Only a tag's name reaches the address.
  run release_probe 'v1.0.0-rc.12&ref=main' "$SCRATCH/probe"
  [ "$status" -ne 0 ]
  run release_probe main "$SCRATCH/probe"
  [ "$status" -ne 0 ]
}

@test "a previous probe that failed to come, is no probe, or would end the stick's heredoc is refused" {
  curl() { return 22; }
  run release_probe v1.0.0-rc.12 "$SCRATCH/probe"
  [ "$status" -ne 0 ]
  curl() { local out; while (($#)); do [[ $1 != -o ]] || out=$2; shift; done; echo '{"message":"Not Found"}' >"$out"; }
  run release_probe v1.0.0-rc.12 "$SCRATCH/probe"
  [ "$status" -ne 0 ]
  curl() { local out; while (($#)); do [[ $1 != -o ]] || out=$2; shift; done; printf 'probe() {\n:\n}\nPROBE\n' >"$out"; }
  run release_probe v1.0.0-rc.12 "$SCRATCH/probe"
  [ "$status" -ne 0 ]
}

@test "the upgrade's boots source the probe of the release they run" {
  mkdir -p "$SCRATCH/work"
  printf 'version = "1"\n' >"$SCRATCH/work/previous.toml"
  cp "$SCRATCH/work/previous.toml" "$SCRATCH/work/candidate.toml"
  echo ca >"$SCRATCH/work/ca.crt"
  printf 'probe() {\n  echo old\n}\n' >"$SCRATCH/work/previous-probe"
  upgrade_after "$SCRATCH/work" >"$SCRATCH/after"
  grep -qx "install -Dm755 /dev/stdin /usr/local/lib/nova-test-probe-previous <<'PROBE'" "$SCRATCH/after"
  grep -qx '  echo old' "$SCRATCH/after"
  # The upgraded boot takes the candidate's, every other the one before's.
  local main
  main=$(sed -n '/^main() {/,/^}/p' "$REPO_ROOT/tests/install/upgrade-probe")
  grep -qE 'if \[\[ \$stage == upgraded \]\]; then' <<<"$main"
  [ "$(grep -c 'source /usr/local/lib/nova-test-probe' <<<"$main")" -eq 2 ]
  grep -q 'source /usr/local/lib/nova-test-probe-previous' <<<"$main"
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

@test "a client that connects and says nothing holds up no other" {
  mkdir "$SCRATCH/repo"
  echo 'the signed database' >"$SCRATCH/repo/nova.db"
  start_upgrade_repo "$SCRATCH" "$SCRATCH/repo"
  port=$(cat "$SCRATCH/repo.port")
  exec {stall}<>"/dev/tcp/127.0.0.1/$port"
  reply=$(curl -fsS --max-time 10 --noproxy '*' --cacert "$SCRATCH/ca.crt" \
    --connect-to "10.0.2.2:$port:127.0.0.1:$port" "$upgrade_repo/nova.db")
  exec {stall}>&-
  [ "$reply" = 'the signed database' ]
}

@test "the guest payload is valid Bash and carries the manifests without interpreting them" {
  here=$REPO_ROOT/tests/install
  printf 'version = "1.0.0-beta.8"\nnova_repo = "https://published.example/v1.0.0-beta.8"\n' >"$SCRATCH/previous.toml"
  printf 'version = "1.0.0"\narch_date = "2026/10/27"\nnova_repo = "https://10.0.2.2:12345"\n' >"$SCRATCH/candidate.toml"
  echo 'a certificate' >"$SCRATCH/ca.crt"
  cp "$here/probe" "$SCRATCH/previous-probe"
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

@test "an update that fails is tried again, three times at most, and its log is the last try's" {
  source "$REPO_ROOT/tests/install/upgrade-probe"
  sleep() { :; }
  # Each try takes its snapshot; the third succeeds.
  nova() {
    echo try >>"$SCRATCH/tries"
    local n
    n=$(wc -l <"$SCRATCH/tries")
    echo "==> Snapshot $((16 + n)) taken"
    ((n == 3))
  }
  update_tries "$SCRATCH/update.log" --release-file candidate.toml --yes
  [ "$(update_snapshot "$SCRATCH/update.log")" = 19 ]
  rm "$SCRATCH/tries"
  nova() { echo try >>"$SCRATCH/tries"; return 1; }
  run update_tries "$SCRATCH/update.log" --yes
  [ "$status" -eq 1 ]
  [ "$(wc -l <"$SCRATCH/tries")" -eq 3 ]
  [[ $output == *'nova update failed (try 3 of 3)'* ]]
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

@test "the snapshot from before the update is found in the boot menu by the command line that boots it" {
  source "$REPO_ROOT/tests/install/upgrade-probe"
  # limine.conf as limine-entry-tool and limine-snapper-sync write it: the
  # snapshots' entries are titled by their date alone, and only their command
  # line has the number.
  cat >"$SCRATCH/limine.conf" <<'CONF'
timeout: 1
default_entry: 2

/+Nova
comment: machine-id=0123456789abcdef0123456789abcdef
  //linux-nova
  protocol: efi
  path: boot():/EFI/Linux/nova_linux-nova.efi
  cmdline: quiet root=PARTUUID=1234 rootflags=subvol=@ rw rootfstype=btrfs
  comment: a snapshot named here is no entry: subvol=/@snapshots/18/snapshot
  //linux-lts
  protocol: efi
  path: boot():/EFI/Linux/nova_linux-lts.efi
  //Snapshots
  comment: 2/3 snapshots
     ///2026-11-16 08:00:01
     comment: nova update v1.0.0-rc.1 -> v1.0.0-rc.2
          ////linux-nova
          protocol: efi
          path: boot():/0123456789abcdef0123456789abcdef/limine_history/nova_linux-nova.efi_sha256_abcd
          cmdline: quiet root=PARTUUID=1234 rootflags=subvol=/@snapshots/17/snapshot rw rootfstype=btrfs
     ///2026-11-15 08:00:01
          ////linux-nova
          protocol: efi
          path: boot():/0123456789abcdef0123456789abcdef/limine_history/nova_linux-nova.efi_sha256_ef01
          kernel_cmdline: root=PARTUUID=1234 rootflags=subvol=/@snapshots/117/snapshot,compress=zstd rw
CONF
  snapshot_entry 17 "$SCRATCH/limine.conf"
  snapshot_entry 117 "$SCRATCH/limine.conf"
  run snapshot_entry 7 "$SCRATCH/limine.conf"
  [ "$status" -eq 1 ]
  # What the menu has instead, for the log.
  [ "$output" = "under Snapshots: subvol=/@snapshots/17/snapshot subvol=/@snapshots/117/snapshot" ]
  fails snapshot_entry 1 "$SCRATCH/limine.conf"
  fails snapshot_entry 18 "$SCRATCH/limine.conf"
  fails snapshot_entry '' "$SCRATCH/limine.conf"
  fails snapshot_entry 17 "$SCRATCH/missing.conf"
  # The same entry outside the Snapshots menu is no snapshot's.
  sed -i 's|^  //Snapshots$|  //Older|' "$SCRATCH/limine.conf"
  run snapshot_entry 17 "$SCRATCH/limine.conf"
  [ "$status" -eq 1 ]
  [ "$output" = "no Snapshots entry" ]
}

@test "a computer moved from the release before keeps its browser: Supernova is checked on a fresh install alone" {
  # The candidate's probe, on the boot after the upgrade, is told so.
  local main
  main=$(sed -n '/^main() {/,/^}/p' "$REPO_ROOT/tests/install/upgrade-probe")
  sed -n '/if \[\[ \$stage == upgraded \]\]; then/,/else/p' <<<"$main" | grep -qx '    probe_upgraded=1'
  run bash -c 'source "$1"; fresh_install' _ "$REPO_ROOT/tests/install/probe"
  [ "$status" -eq 0 ]
  run bash -c 'source "$1"; probe_upgraded=1; fresh_install' _ "$REPO_ROOT/tests/install/probe"
  [ "$status" -eq 1 ]
  # Supernova's check is one of a fresh install's.
  sed -n '/^  if fresh_install; then$/,/^  fi$/p' "$REPO_ROOT/tests/install/probe" | grep -q 'Supernova is installed and the default browser'
  [ "$(grep -c 'Supernova is installed' "$REPO_ROOT/tests/install/probe")" -eq 1 ]
}
