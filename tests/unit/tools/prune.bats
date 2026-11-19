#!/usr/bin/env bats

# tools/packages-prune: what leaves the package bucket when old releases are
# removed, and what stays. The bucket is a directory: the aws stub lists its
# files as objects and deletes the ones it is handed.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" BUCKET="$SCRATCH/bucket"
  export R2_ENDPOINT=https://account.r2.example.org R2_BUCKET=nova-packages
  export AWS_ACCESS_KEY_ID=id AWS_SECRET_ACCESS_KEY=secret
  mkdir -p "$SCRATCH/bin"
  cat >"$SCRATCH/bin/aws" <<'STUB'
#!/bin/bash
echo "aws $*" >>"$CALLS"
case $2 in
  list-objects-v2)
    cd "$BUCKET" && find . -type f -printf '%P\t%s\n' | sort |
      jq -Rn '{Contents: [inputs | split("\t") | {Key: .[0], Size: (.[1] | tonumber)}]}'
    ;;
  delete-objects)
    while (($#)); do [[ $1 == --delete ]] && batch=${2#file://}; shift; done
    if [[ -n ${REFUSE:-} ]]; then
      jq -n --arg key "$REFUSE" '{Errors: [{Key: $key, Code: "AccessDenied"}]}'
      exit 0
    fi
    jq -r '.Objects[].Key' "$batch" | while IFS= read -r key; do rm -f -- "$BUCKET/$key"; done
    echo '{}'
    ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$SCRATCH/bin/aws"
  export PATH="$SCRATCH/bin:$PATH"
  put v1.0.2/nova.db v1.0.2/nova-1.0.2-1-x86_64.pkg.tar.zst v1.0.2/release.toml
  put v1.0.2/aarch64/nova.db v1.0.2/aarch64/alarm/core.db
  put v1.0.1/nova.db v1.0.1/nova-1.0.1-1-x86_64.pkg.tar.zst
  put alarm/aarch64/glibc-2.42-1-aarch64.pkg.tar.xz stray.txt
}

teardown() { teardown_scratch; }

put() { # key...
  local key
  for key; do
    mkdir -p "$BUCKET/$(dirname "$key")"
    echo "$key" >"$BUCKET/$key"
  done
}

prune() { "$REPO_ROOT/tools/packages-prune" "$@"; }

left() { (cd "$BUCKET" && find . -type f -printf '%P\n' | sort | paste -sd' '); }

@test "without --delete it lists what would go, by folder, and removes nothing" {
  run prune --keep v1.0.2
  [ "$status" -eq 0 ]
  [[ $output == *"In the bucket: 9 objects. Kept: v1.0.2."* ]]
  [[ $output =~ v1\.0\.1\ +2\ objects ]]
  # What lies under a kept release's own files is not that release's.
  [[ $output =~ v1\.0\.2/aarch64\ +2\ objects ]]
  [[ $output =~ alarm/aarch64\ +1\ objects ]]
  [[ $output =~ \(no\ folder\)\ +1\ objects ]]
  [[ $output == *"To remove: 6 objects"* ]]
  [[ $output == *"Nothing was removed: run again with --delete."* ]]
  fails grep -q 'delete-objects' "$CALLS"
  [ "$(find "$BUCKET" -type f | wc -l)" -eq 9 ]
}

@test "--delete removes them, and a kept release's own files stay" {
  run prune --keep v1.0.2 --delete
  [ "$status" -eq 0 ]
  [[ $output == *"Removed. In the bucket now: 3 objects."* ]]
  [ "$(left)" = 'v1.0.2/nova-1.0.2-1-x86_64.pkg.tar.zst v1.0.2/nova.db v1.0.2/release.toml' ]
  run prune --keep v1.0.2 --delete
  [ "$status" -eq 0 ]
  [[ $output == *"Nothing to remove."* ]]
}

@test "several releases kept, and more objects than one request takes" {
  local n
  for n in {1..1003}; do echo x >"$BUCKET/v1.0.1/f$n"; done
  run prune --keep v1.0.2 --keep v1.0.3-rc.1 --delete
  [ "$status" -eq 0 ]
  [ "$(grep -c 'delete-objects' "$CALLS")" -eq 2 ]
  [ "$(find "$BUCKET" -type f | wc -l)" -eq 3 ]
}

@test "no release to keep, something that is no tag, no token, or a refusal: nothing is taken for removed" {
  run prune --delete
  [ "$status" -ne 0 ]
  [[ $output == *"name at least one release to keep"* ]]
  run prune --keep 'v1.0.2/../..' --delete
  [ "$status" -ne 0 ]
  run prune --keep main --delete
  [ "$status" -ne 0 ]
  [ ! -e "$CALLS" ]
  AWS_SECRET_ACCESS_KEY='' run prune --keep v1.0.2 --delete
  [ "$status" -ne 0 ]
  [[ $output == *"token is not set"* ]]
  REFUSE=v1.0.1/nova.db run prune --keep v1.0.2 --delete
  [ "$status" -ne 0 ]
  [[ $output == *"not removed: v1.0.1/nova.db"* ]]
}

@test "--older-than removes the releases before it, and keeps it and every newer one" {
  put v1.0.2-rc.4/nova.db v1.0.10/nova.db v1.0.3-beta.2/nova.db v1.0.3-rc.1/nova.db
  run prune --older-than v1.0.2
  [ "$status" -eq 0 ]
  [[ $output == *"Kept: v1.0.2 and every newer release."* ]]
  run prune --older-than v1.0.2 --delete
  [ "$status" -eq 0 ]
  local key
  for key in v1.0.2/nova.db v1.0.2/release.toml v1.0.10/nova.db v1.0.3-beta.2/nova.db v1.0.3-rc.1/nova.db; do
    [ -e "$BUCKET/$key" ]
  done
  # Before it: an older release, its own candidate, and what is no release's.
  for key in v1.0.1/nova.db v1.0.2-rc.4/nova.db v1.0.2/aarch64/nova.db alarm/aarch64/glibc-2.42-1-aarch64.pkg.tar.xz stray.txt; do
    [ ! -e "$BUCKET/$key" ]
  done
}

@test "--older-than a candidate keeps the candidates after it, and not a beta before it" {
  put v1.0.3-beta.2/nova.db v1.0.3-rc.1/nova.db v1.0.3-rc.2/nova.db v1.0.3/nova.db
  run prune --older-than v1.0.3-rc.2 --delete
  [ "$status" -eq 0 ]
  [ -e "$BUCKET/v1.0.3-rc.2/nova.db" ]
  [ -e "$BUCKET/v1.0.3/nova.db" ]
  [ ! -e "$BUCKET/v1.0.3-rc.1/nova.db" ]
  [ ! -e "$BUCKET/v1.0.3-beta.2/nova.db" ]
  [ ! -e "$BUCKET/v1.0.2/nova.db" ]
  run prune --older-than 'v1.0.3/..' --delete
  [ "$status" -ne 0 ]
}
