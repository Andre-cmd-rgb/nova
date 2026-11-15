#!/usr/bin/env bats

# tools/arch-packages: which of Arch's packages are fetched ahead of the
# install tests, and how they are named for pacman's cache. pacman is a stub
# that knows a snapshot of five packages; curl writes what it is asked for.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls"
  mkdir -p "$SCRATCH/bin" "$SCRATCH/cache"
  printf 'version = "1.0.3"\narch_date = "2026/11/11"\nnova_repo = "https://packages.example.org/v1.0.3"\n' >"$SCRATCH/release.toml"
  printf '%s\n' base efibootmgr hyprland nvidia-utils zsh >"$SCRATCH/snapshot"
  cat >"$SCRATCH/bin/pacman" <<'STUB'
#!/bin/bash
echo "pacman $*" >>"$CALLS"
conf='' names=()
while (($#)); do
  case $1 in
    --config) conf=$2; shift ;;
    -Sy) cat "$conf" >"$SCRATCH/conf"; exit 0 ;;
    -Slq) cat "$SCRATCH/snapshot"; exit 0 ;;
    --print-format) shift; shift; names=("$@"); break ;;
  esac
  shift
done
for name in "${names[@]}"; do
  [[ $name != "${UNRESOLVED:-}" ]] || exit 1
  ((${#names[@]} == 1)) || [[ $name != "${ALONE:-}" ]] || exit 1
done
for name in "${names[@]}"; do
  version=1
  [[ $name != hyprland ]] || version=1:0.56.2
  printf 'https://archive.archlinux.org/x/%s-%s-1-x86_64.pkg.tar.zst\t10\n' "$name" "$version"
done
STUB
  cat >"$SCRATCH/bin/curl" <<'STUB'
#!/bin/bash
while (($#)); do [[ $1 == --config ]] && config=$2; shift; done
while read -r key _ value; do
  value=${value//\"/}
  case $key in url) url=$value ;; output) echo "from $url" >"$value" ;; esac
done <"$config"
STUB
  printf '#!/bin/bash\n[[ $1 != -- ]] || shift\nexec "$@"\n' >"$SCRATCH/bin/fakeroot"
  printf '#!/bin/bash\necho "%s"\n' "$SCRATCH/cache" >"$SCRATCH/bin/pacman-conf"
  chmod +x "$SCRATCH"/bin/*
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

packages() { "$REPO_ROOT/tools/arch-packages" --release "$SCRATCH/release.toml" "$@"; }

@test "--list: what an install and Nova's own packages ask for, of the snapshot's alone" {
  run packages --list
  [ "$status" -eq 0 ]
  # base is the installer's, hyprland nova's, efibootmgr the boot tool's, and
  # nvidia-utils the NVIDIA modules', which name it with a version.
  [ "$(cut -f1 <<<"$output" | sed 's|.*/||; s/-1.*//' | paste -sd' ')" = 'base efibootmgr hyprland nvidia-utils' ]
  [[ $output == *$'\t10'* ]]
  grep -q 'Server = https://archive.archlinux.org/repos/2026/11/11/\$repo/os/\$arch' "$SCRATCH/conf"
  # Nova's own are in no Arch repository, and are never asked of one.
  fails grep -E -- '-Sp .* (nova|nova-keyring|linux-nova|limine-entry-tool)( |$)' "$CALLS"
}

@test "--list: a package pacman refuses beside the others is resolved alone, one it cannot resolve is left out" {
  ALONE=nvidia-utils UNRESOLVED=efibootmgr run packages --list
  [ "$status" -eq 0 ]
  [ "$(cut -f1 <<<"$output" | sed 's|.*/||; s/-1.*//' | paste -sd' ')" = 'base hyprland nvidia-utils' ]
}

@test "the packages and their signatures, named as pacman's cache names them" {
  run packages "$SCRATCH/out"
  [ "$status" -eq 0 ]
  [[ $output == *"4 packages in $SCRATCH/out"* ]]
  [ "$(cat "$SCRATCH/out/base-1-1-x86_64.pkg.tar.zst")" = 'from https://archive.archlinux.org/x/base-1-1-x86_64.pkg.tar.zst' ]
  [ -s "$SCRATCH/out/base-1-1-x86_64.pkg.tar.zst.sig" ]
  # An epoch keeps its colon: nova usb looks for the file by pacman's name.
  [ -s "$SCRATCH/out/hyprland-1:0.56.2-1-x86_64.pkg.tar.zst" ]
  [ -s "$SCRATCH/out/hyprland-1:0.56.2-1-x86_64.pkg.tar.zst.sig" ]
  [ "$(find "$SCRATCH/out" -type f | wc -l)" -eq 8 ]
}

@test "a release with no snapshot, or a snapshot that does not answer, fetches nothing" {
  echo 'version = "1.0.3"' >"$SCRATCH/release.toml"
  run packages "$SCRATCH/out"
  [ "$status" -ne 0 ]
  [[ $output == *"has no arch_date"* ]]
  [ ! -e "$CALLS" ]
  printf 'arch_date = "2026/11/11"\n' >"$SCRATCH/release.toml"
  printf '#!/bin/bash\nexit 1\n' >"$SCRATCH/bin/pacman"
  run packages "$SCRATCH/out"
  [ "$status" -ne 0 ]
  [[ $output == *"the snapshot of 2026/11/11 did not answer"* ]]
  [ ! -e "$SCRATCH/out" ]
}
