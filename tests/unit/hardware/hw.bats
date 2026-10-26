#!/usr/bin/env bats

load ../test_helper

setup() {
  setup_scratch
  export NOVA_HARDWARE="$REPO_ROOT/data/hardware"
  export NOVA_DMI_PATH="$SCRATCH/dmi"
  export NOVA_DEVICETREE_PATH="$SCRATCH/devicetree"
  export NOVA_ROOT="$SCRATCH/root"
  mkdir -p "$NOVA_DMI_PATH" "$NOVA_ROOT"
}

teardown() { teardown_scratch; }

detect="$REPO_ROOT/data/hardware/bin/nova-hw-detect"
apply="$REPO_ROOT/data/hardware/bin/nova-hw-apply"

model() { printf '%s\n' "$1" >"$NOVA_DMI_PATH/product_version"; }

# A board without DMI tables, as the kernel shows its devicetree: no DMI
# directory, and the model NUL-terminated.
board() {
  rm -rf "$NOVA_DMI_PATH"
  mkdir -p "$NOVA_DEVICETREE_PATH"
  printf '%s\0' "$1" >"$NOVA_DEVICETREE_PATH/model"
}

@test "detect: the P1 Gen 4i matches exactly" {
  model "ThinkPad P1 Gen 4i"
  run "$detect"
  [ "$status" -eq 0 ]
  [ "$output" = thinkpad-p1-gen4i ]
}

@test "detect: a Legion 5 matches by prefix" {
  model "Legion 5 15ACH6H"
  run "$detect"
  [ "$output" = legion-5 ]
}

@test "detect: a near miss is not a match" {
  model "ThinkPad P1 Gen 4"
  run "$detect"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "detect: no DMI at all is not knowing, not a machine without a profile" {
  run "$detect"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

@test "detect: a Raspberry Pi 5 is matched by its devicetree model" {
  board "Raspberry Pi 5 Model B Rev 1.0"
  run "$detect"
  [ "$status" -eq 0 ]
  [ "$output" = raspberry-pi-5 ]
}

@test "detect: another Raspberry Pi has no profile" {
  board "Raspberry Pi 4 Model B Rev 1.5"
  run "$detect"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "detect: DMI wins over a devicetree" {
  model "ThinkPad P1 Gen 4i"
  mkdir -p "$NOVA_DEVICETREE_PATH"
  printf 'Raspberry Pi 5 Model B Rev 1.0\0' >"$NOVA_DEVICETREE_PATH/model"
  run "$detect"
  [ "$output" = thinkpad-p1-gen4i ]
}

@test "detect: every profile in the models list exists" {
  while IFS=$'\t' read -r pattern profile; do
    [[ -n $pattern && $pattern != \#* ]] || continue
    [ -d "$NOVA_HARDWARE/$profile" ]
    [ -f "$NOVA_HARDWARE/$profile/packages" ]
  done <"$NOVA_HARDWARE/models"
}

@test "apply: installs the profile and records exactly what it installed" {
  model "ThinkPad P1 Gen 4i"
  run "$apply"
  [ "$status" -eq 0 ]
  [ -f "$NOVA_ROOT/etc/modprobe.d/nova-hw-nvidia-fbdev.conf" ]
  [ -f "$NOVA_ROOT/etc/NetworkManager/conf.d/nova-hw-wifi-powersave.conf" ]
  [ "$(wc -l <"$NOVA_ROOT/var/lib/nova/hardware-files")" -eq "$(find "$NOVA_HARDWARE/thinkpad-p1-gen4i/etc" -type f | wc -l)" ]
}

@test "apply: a Raspberry Pi 5 gets the HDMI brightness files" {
  board "Raspberry Pi 5 Model B Rev 1.0"
  run "$apply"
  [ "$status" -eq 0 ]
  grep -qx i2c-dev "$NOVA_ROOT/etc/modules-load.d/nova-hw-ddc.conf"
  grep -q 'TAG+="uaccess"' "$NOVA_ROOT/etc/udev/rules.d/70-nova-hw-ddc.rules"
}

@test "apply: a file an earlier release shipped and this one does not is removed" {
  model "ThinkPad P1 Gen 4i"
  write_file "$NOVA_ROOT/etc/modprobe.d/nova-hw-old.conf" "options old x=1"
  write_file "$NOVA_ROOT/var/lib/nova/hardware-files" $'modprobe.d/nova-hw-old.conf\n'
  run "$apply"
  [ "$status" -eq 0 ]
  [ ! -e "$NOVA_ROOT/etc/modprobe.d/nova-hw-old.conf" ]
  ! grep -q nova-hw-old "$NOVA_ROOT/var/lib/nova/hardware-files"
}

@test "apply: files Nova never installed are left alone" {
  model "ThinkPad P1 Gen 4i"
  write_file "$NOVA_ROOT/etc/modprobe.d/mine.conf" "options mine x=1"
  run "$apply"
  [ -f "$NOVA_ROOT/etc/modprobe.d/mine.conf" ]
}

@test "apply: a manifest entry cannot reach outside /etc" {
  model "XPS 13"
  write_file "$NOVA_ROOT/precious" x
  write_file "$NOVA_ROOT/var/lib/nova/hardware-files" $'../precious\n/precious\n'
  run "$apply"
  [ "$status" -eq 0 ]
  [ -f "$NOVA_ROOT/precious" ]
}

@test "apply: an unknown machine ends with nothing installed" {
  model "ThinkPad P1 Gen 4i"
  "$apply"
  model "XPS 13"
  run "$apply"
  [ "$status" -eq 0 ]
  [ -z "$(find "$NOVA_ROOT/etc" -type f)" ]
  [ ! -s "$NOVA_ROOT/var/lib/nova/hardware-files" ]
}

@test "apply: a model it cannot read leaves the installed files alone" {
  model "ThinkPad P1 Gen 4i"
  "$apply"
  local before
  before=$(cat "$NOVA_ROOT/var/lib/nova/hardware-files")
  rm "$NOVA_DMI_PATH/product_version"
  run "$apply"
  [ "$status" -eq 0 ]
  [ -f "$NOVA_ROOT/etc/modprobe.d/nova-hw-nvidia-fbdev.conf" ]
  [ "$(cat "$NOVA_ROOT/var/lib/nova/hardware-files")" = "$before" ]
}

@test "apply --remove: takes everything back off" {
  model "ThinkPad P1 Gen 4i"
  "$apply"
  run "$apply" --remove
  [ "$status" -eq 0 ]
  [ -z "$(find "$NOVA_ROOT/etc" -type f)" ]
}

@test "apply: rejects unknown arguments" {
  run "$apply" --bogus
  [ "$status" -eq 2 ]
}

# uwsm sources these with /bin/sh at every login, on every machine: one that
# fails to parse or run costs the login (docs/hardware/thinkpad-p1-gen4i.md,
# fact 3).
@test "session env: every uwsm env.d file is POSIX sh that sources cleanly" {
  local f
  for f in "$NOVA_HARDWARE"/uwsm/*; do
    sh -n "$f"
    if command -v shellcheck >/dev/null; then shellcheck -s sh -S warning "$f"; fi
    run sh -c '. "$1" && echo sourced' sh "$f"
    [ "$status" -eq 0 ]
    [ "$output" = sourced ]
  done
}
