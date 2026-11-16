#!/usr/bin/env bats

# tools/keyring-check: CI fails half a year before the signing key expires,
# and passes again once a trusted successor is in the keyring.

load ../test_helper

setup() {
  setup_scratch
  export GNUPGHOME="$SCRATCH/gnupg" KEYRING="$SCRATCH/keyring"
  mkdir -m 700 "$GNUPGHOME"
  mkdir "$KEYRING"
  : >"$KEYRING/nova.gpg"
  : >"$KEYRING/nova-trusted"
  unset GITHUB_ACTIONS
}

teardown() { teardown_scratch; }

# A key of the test's own, expiring as gpg is told (100d, 3y, never), appended
# to the keyring as a transition release appends one, and trusted unless the
# second argument says otherwise.
keys=0
add_key() { # expiry [untrusted] [gpg option...]
  local expiry=$1 trust=${2:-trusted} fpr
  shift 2 || shift
  keys=$((keys + 1))
  gpg --batch --quiet --passphrase '' "$@" --quick-gen-key "Nova test $keys <test$keys@example.org>" ed25519 sign "$expiry" 2>/dev/null
  fpr=$(gpg --batch --with-colons --list-keys "test$keys@example.org" | awk -F: '$1 == "fpr" { print $10; exit }')
  gpg --batch --armor --export "$fpr" >>"$KEYRING/nova.gpg"
  [[ $trust == untrusted ]] || printf '%s:4:\n' "$fpr" >>"$KEYRING/nova-trusted"
}

check() { run "$REPO_ROOT/tools/keyring-check" --keyring "$KEYRING" "$@"; }

@test "a key with more than half a year to go passes" {
  add_key 2y
  check
  [ "$status" -eq 0 ]
  [[ $output == *"lasts until "* ]]
}

@test "a key within half a year of its end fails, and says where the steps to replace it are" {
  add_key 100d
  check
  [ "$status" -eq 1 ]
  [[ $output == *"expires on "*", in "*" days"* ]]
  [[ $output == *'docs/releasing.md, "Replacing the key"'* ]]
}

@test "a key that has expired fails" {
  add_key 1y trusted --faked-system-time 20200101T000000
  check
  [ "$status" -eq 1 ]
  [[ $output == *"expired on 20"* ]]
}

@test "a key that never expires passes" {
  add_key never
  check
  [ "$status" -eq 0 ]
  [[ $output == *"never expires"* ]]
}

@test "during a transition, the old key near its end beside a trusted new one passes" {
  add_key 100d
  add_key 3y
  check
  [ "$status" -eq 0 ]
}

@test "a new key nova-trusted does not list is no successor" {
  add_key 100d
  add_key 3y untrusted
  check
  [ "$status" -eq 1 ]
}

@test "a trusted key that is not in nova.gpg, or no trusted key at all, fails" {
  add_key 3y untrusted
  check
  [ "$status" -eq 1 ]
  [[ $output == *"lists no key"* ]]
  echo 'E517699D1B31F918EB8C9969640F350B639AD61A:4:' >"$KEYRING/nova-trusted"
  check
  [ "$status" -eq 1 ]
  [[ $output == *"E517699D1B31F918EB8C9969640F350B639AD61A, which nova-trusted lists, is not in nova.gpg"* ]]
}

@test "--days moves the line" {
  add_key 100d
  check --days 30
  [ "$status" -eq 0 ]
  check --days 365
  [ "$status" -eq 1 ]
}

@test "under GitHub Actions the failure is an error annotation too" {
  add_key 100d
  GITHUB_ACTIONS=true check
  [ "$status" -eq 1 ]
  [[ $output == *"::error::Nova's signing key runs out"* ]]
}
