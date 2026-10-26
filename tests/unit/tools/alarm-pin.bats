#!/usr/bin/env bats

# tools/alarm-pin: the Arch Linux ARM packages a release pins for the
# Raspberry Pi, from databases made here. The mirror and the pool are
# directories, which a curl on PATH serves: a HEAD answers 200 for a file the
# pool has, and a download copies the mirror's file.

load ../test_helper

setup() {
  setup_scratch
  test_key
  mkdir -p "$SCRATCH/bin" "$SCRATCH/pool" "$SCRATCH/dbs" "$SCRATCH/repo"
  cat >"$SCRATCH/bin/curl" <<'EOF'
#!/bin/bash
head=0 list=
while (($#)); do
  case $1 in -I) head=1 ;; -K) list=$2; shift ;; esac
  shift
done
while IFS= read -r line; do
  case $line in
    'url = "'*) url=${line#url = \"} url=${url%\"} ;;
    'output = "'*)
      out=${line#output = \"} out=${out%\"}
      if ((head)); then
        [[ -f $SCRATCH/pool/${url#https://pool.example.org/} ]] && echo "200 $url" || echo "404 $url"
      else
        cp -- "$SCRATCH/mirror/${url#https://mirror.example.org/}" "$out" || exit 22
      fi
      ;;
  esac
done <"$list"
EOF
  chmod +x "$SCRATCH/bin/curl"
  export PATH="$SCRATCH/bin:$PATH" NOVA_ALARM_MIRROR=https://mirror.example.org

  # Arch Linux ARM's zlib, whose version has an epoch, and glibc, whose has a
  # +; neither character is kept in the pool's names.
  package core zlib 1:1.3.2-4 zlib-1:1.3.2-4-aarch64.pkg.tar.xz
  package core glibc 2.42+r1-1 glibc-2.42+r1-1-aarch64.pkg.tar.xz
  database core
  for repo in extra alarm aur; do bsdtar -czf "$SCRATCH/dbs/$repo.db" -T /dev/null; done
  # Nova's own, which takes both.
  entry "$SCRATCH/repo/x" nova 1.0-1 nova-1.0-1-aarch64.pkg.tar.zst - "" zlib glibc
  (cd "$SCRATCH/repo/x" && bsdtar -czf ../nova.db -- *)
  echo nova >"$SCRATCH/list"
}

teardown() { teardown_scratch; }

# A package's entry in a database:
# entry <dir> <name> <version> <file> <sha256> <signature> [depends...]
entry() {
  mkdir -p "$1/$2-$3"
  {
    printf '%%FILENAME%%\n%s\n\n%%NAME%%\n%s\n\n%%VERSION%%\n%s\n\n%%ARCH%%\naarch64\n\n' "$4" "$2" "$3"
    printf '%%SHA256SUM%%\n%s\n\n' "$5"
    [[ -z $6 ]] || printf '%%PGPSIG%%\n%s\n\n' "$6"
    if (($# > 6)); then printf '%%DEPENDS%%\n'; printf '%s\n' "${@:7}"; echo; fi
  } >"$1/$2-$3/desc"
}

# An Arch Linux ARM package: its file on the mirror, and its entry, whose
# signature is any bytes here. package <repo> <name> <version> <file> [signature]
package() {
  local path=$SCRATCH/mirror/aarch64/$1/$4
  write_file "$path" "the $2 package"
  entry "$SCRATCH/x/$1" "$2" "$3" "$4" "$(sha256sum <"$path" | cut -d' ' -f1)" \
    "${5-$(printf 'signature of %s' "$2" | base64 -w0)}"
}

database() { (cd "$SCRATCH/x/$1" && bsdtar -czf "$SCRATCH/dbs/$1.db" -- *); }

pin() {
  local key
  key=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" { print $10; exit }')
  "$REPO_ROOT/tools/alarm-pin" --dbs "$SCRATCH/dbs" --repo "$SCRATCH/repo" \
    --pool https://pool.example.org --key "$key" --out "$SCRATCH/out" --new "$SCRATCH/new" "$SCRATCH/list"
}

@test "alarm-pin: each package goes to the pool with its signature, written from its database" {
  run pin
  [ "$status" -eq 0 ]
  [ "$(cat "$SCRATCH/new/zlib-1_1.3.2-4-aarch64.pkg.tar.xz")" = "the zlib package" ]
  [ "$(cat "$SCRATCH/new/glibc-2.42_r1-1-aarch64.pkg.tar.xz")" = "the glibc package" ]
  # pacman fetches a package's .sig as a file, and refuses the package without one.
  [ "$(cat "$SCRATCH/new/zlib-1_1.3.2-4-aarch64.pkg.tar.xz.sig")" = "signature of zlib" ]
  [ "$(cat "$SCRATCH/new/glibc-2.42_r1-1-aarch64.pkg.tar.xz.sig")" = "signature of glibc" ]
  [ "$(find "$SCRATCH/new" -type f | wc -l)" -eq 4 ]
  # nova-alarm.db holds the two, not Nova's own, by the names the pool has,
  # and Nova's key signs it.
  [ "$(bsdtar -tf "$SCRATCH/out/nova-alarm.db" | grep -c '/desc$')" -eq 2 ]
  bsdtar -xOf "$SCRATCH/out/nova-alarm.db" | grep -qx 'glibc-2.42_r1-1-aarch64.pkg.tar.xz'
  gpg --batch --quiet --verify "$SCRATCH/out/nova-alarm.db.sig" "$SCRATCH/out/nova-alarm.db"
}

@test "alarm-pin: what the pool has is not fetched again, and a signature it lacks is written" {
  write_file "$SCRATCH/pool/zlib-1_1.3.2-4-aarch64.pkg.tar.xz" "the zlib package"
  write_file "$SCRATCH/pool/glibc-2.42_r1-1-aarch64.pkg.tar.xz" "the glibc package"
  write_file "$SCRATCH/pool/glibc-2.42_r1-1-aarch64.pkg.tar.xz.sig" "signature of glibc"
  run pin
  [ "$status" -eq 0 ]
  [ "$(ls "$SCRATCH/new")" = "zlib-1_1.3.2-4-aarch64.pkg.tar.xz.sig" ]
}

@test "alarm-pin: a package whose entry has no signature stops it" {
  package core zlib 1:1.3.2-4 zlib-1:1.3.2-4-aarch64.pkg.tar.xz ""
  database core
  run pin
  [ "$status" -ne 0 ]
  [[ $output == *"core.db has no signature for zlib-1:1.3.2-4"* ]]
}

@test "alarm-pin: a file the mirror serves that is not what its database says stops it" {
  echo "something else" >"$SCRATCH/mirror/aarch64/core/glibc-2.42+r1-1-aarch64.pkg.tar.xz"
  run pin
  [ "$status" -ne 0 ]
  [[ $output == *"glibc-2.42+r1-1-aarch64.pkg.tar.xz is not what core.db says it is"* ]]
}
