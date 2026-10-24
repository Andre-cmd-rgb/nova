#!/usr/bin/env bats

# Where a release's packages go: tools/release-pin names the folder in the
# nova-packages bucket, and tools/packages-upload puts them there and reads
# them back. The bucket is a directory: aws writes into it, curl serves it.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" BUCKET="$SCRATCH/bucket"
  export R2_ENDPOINT=https://account.r2.example.org R2_BUCKET=nova-packages
  export AWS_ACCESS_KEY_ID=id AWS_SECRET_ACCESS_KEY=secret
  mkdir -p "$SCRATCH/bin" "$SCRATCH/out" "$BUCKET"
  cat >"$SCRATCH/bin/aws" <<'EOF'
#!/bin/bash
echo "aws $* region=$AWS_DEFAULT_REGION checksums=$AWS_REQUEST_CHECKSUM_CALCULATION" >>"$CALLS"
key=${*: -1}
[[ $key == s3://nova-packages/* ]] || exit 1
key=${key#s3://nova-packages/}
mkdir -p "$(dirname "$BUCKET/$key")"
cp "${*: -2:1}" "$BUCKET/$key"
EOF
  cat >"$SCRATCH/bin/curl" <<'EOF'
#!/bin/bash
url=${*: -1}
[[ $url == https://packages.example.org/* ]] && cat "$BUCKET/${url#https://packages.example.org/}"
EOF
  chmod +x "$SCRATCH/bin/aws" "$SCRATCH/bin/curl"
  export PATH="$SCRATCH/bin:$PATH"
  "$REPO_ROOT/tools/release-pin" --version v1.0.0-beta.6 --date 2026/10/23 \
    --packages https://packages.example.org/ --out "$SCRATCH/release.toml" 2>/dev/null
  echo db >"$SCRATCH/out/nova.db"
  echo pkg >"$SCRATCH/out/nova-1.0-1-x86_64.pkg.tar.zst"
}

teardown() { teardown_scratch; }

upload() { "$REPO_ROOT/tools/packages-upload" --release "$SCRATCH/release.toml" "$@"; }

@test "release-pin: the release's packages are in its own folder of the bucket's address" {
  grep -qx 'nova_repo = "https://packages.example.org/v1.0.0-beta.6"' "$SCRATCH/release.toml"
  grep -qx 'version = "1.0.0-beta.6"' "$SCRATCH/release.toml"
  "$REPO_ROOT/tools/release-pin" --version 1.0.0 --date 2026/10/23 --out "$SCRATCH/default.toml" 2>/dev/null
  grep -qx 'nova_repo = "https://nova-packages.piserver.stream/v1.0.0"' "$SCRATCH/default.toml"
  for bad in http://packages.example.org 'https://a b' https://; do
    run "$REPO_ROOT/tools/release-pin" --version 1.0.0 --date 2026/10/23 --packages "$bad" --out "$SCRATCH/bad.toml"
    [ "$status" -ne 0 ]
  done
}

@test "upload: each file in the release's folder, then read back from where pacman reads" {
  run upload "$SCRATCH/out/nova.db" "$SCRATCH/out/nova-1.0-1-x86_64.pkg.tar.zst"
  [ "$status" -eq 0 ]
  [ "$(cat "$BUCKET/v1.0.0-beta.6/nova.db")" = db ]
  [ "$(cat "$BUCKET/v1.0.0-beta.6/nova-1.0-1-x86_64.pkg.tar.zst")" = pkg ]
  grep -q -- "--endpoint-url $R2_ENDPOINT .* region=auto checksums=when_required" "$CALLS"
}

@test "upload: a file the address serves differently fails it" {
  cat >"$SCRATCH/bin/curl" <<'EOF'
#!/bin/bash
echo something else
EOF
  run upload "$SCRATCH/out/nova.db"
  [ "$status" -ne 0 ]
  [[ $output == *"https://packages.example.org/v1.0.0-beta.6/nova.db is not what was uploaded"* ]]
}

@test "upload: a refused upload, or no token, stops before anything is read back" {
  printf '#!/bin/bash\nexit 1\n' >"$SCRATCH/bin/aws"
  run upload "$SCRATCH/out/nova.db"
  [ "$status" -ne 0 ]
  [[ $output == *"could not upload nova.db"* ]]
  unset AWS_SECRET_ACCESS_KEY
  run upload "$SCRATCH/out/nova.db"
  [ "$status" -ne 0 ]
  [[ $output == *"token is not set"* ]]
}
