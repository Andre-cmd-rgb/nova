#!/usr/bin/env bats

load ../test_helper

setup() {
  setup_scratch
  # shellcheck source=/dev/null
  source "$REPO_ROOT/data/boot/bin/nova-boot-check"
  ESP="$SCRATCH/boot"
  CONF="$SCRATCH/conf"
  mkdir -p "$ESP" "$CONF"
  LIMINE_CONF_FILES=("$CONF/10-nova.conf" "$CONF/default-limine")
  printf '%s\n' 'ESP_PATH="/boot"' 'MKINITCPIO_FALLBACK=linux-nova' >"$CONF/10-nova.conf"
  export NOVA_BOOT_ESP="$ESP"
}

teardown() { teardown_scratch; }

# A complete ESP: default loader, fallback image and its limine.conf entry.
make_complete_esp() {
  write_file "$ESP/EFI/BOOT/BOOTX64.EFI" x
  write_file "$ESP/EFI/Linux/nova_linux-nova-fallback.efi" x
  write_file "$ESP/limine.conf" $'timeout: 1\n/+Nova\n  //linux-nova\n    protocol: efi\n  //linux-nova-fallback\n    protocol: efi\n'
}

@test "limine_setting: the last assignment wins and quotes are stripped" {
  printf '%s\n' 'FOO="one"' "FOO='two'" >"$CONF/a"
  printf '%s\n' 'FOO=three' >"$CONF/b"
  [ "$(limine_setting FOO none "$CONF/a" "$CONF/b")" = three ]
  [ "$(limine_setting FOO none "$CONF/a")" = two ]
}

@test "limine_setting: unset keys fall back to the default and commented keys are ignored" {
  printf '%s\n' '#FOO=bad' >"$CONF/a"
  [ "$(limine_setting FOO dflt "$CONF/a" "$CONF/missing")" = dflt ]
}

@test "limine_setting: a trailing comment is dropped" {
  printf '%s\n' 'FOO=bar # comment' >"$CONF/a"
  [ "$(limine_setting FOO none "$CONF/a")" = bar ]
}

@test "boot_missing: a complete ESP reports nothing" {
  make_complete_esp
  [ -z "$(boot_missing "$ESP" linux-nova)" ]
}

@test "boot_missing: an empty ESP reports the loader, the image and the entry" {
  run boot_missing "$ESP" linux-nova
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ ${lines[0]} == *BOOTX64.EFI* ]]
  [[ ${lines[1]} == *"fallback image"* ]]
  [[ ${lines[2]} == *"fallback entry"* ]]
}

@test "boot_missing: a fallback image without its limine.conf entry is reported" {
  make_complete_esp
  write_file "$ESP/limine.conf" $'/+Nova\n  //linux-nova\n    protocol: efi\n'
  run boot_missing "$ESP" linux-nova
  [ "${#lines[@]}" -eq 1 ]
  [[ ${lines[0]} == *"entry in"* ]]
}

@test "boot_missing: other fallback image and entry spellings are accepted" {
  make_complete_esp
  mv "$ESP/EFI/Linux/nova_linux-nova-fallback.efi" "$ESP/EFI/Linux/0123abcd_linux-nova_fallback.efi"
  write_file "$ESP/limine.conf" $'/+Nova\n  //linux-nova\n  //+linux-nova (fallback)\n'
  [ -z "$(boot_missing "$ESP" linux-nova)" ]
}

@test "boot_missing: another kernel's fallback does not count" {
  make_complete_esp
  mv "$ESP/EFI/Linux/nova_linux-nova-fallback.efi" "$ESP/EFI/Linux/nova_linux-lts-fallback.efi"
  write_file "$ESP/limine.conf" $'/+Nova\n  //linux-lts-fallback\n'
  run boot_missing "$ESP" linux-nova
  [ "${#lines[@]}" -eq 2 ]
}

@test "boot_missing: a zero-byte loader counts as missing" {
  make_complete_esp
  : >"$ESP/EFI/BOOT/BOOTX64.EFI"
  run boot_missing "$ESP" linux-nova
  [ "${#lines[@]}" -eq 1 ]
  [[ ${lines[0]} == *BOOTX64.EFI* ]]
}

@test "pre: passes on a fresh ESP with no Limine setup yet" {
  run run_check pre
  [ "$status" -eq 0 ]
}

@test "pre: passes when the fallback is complete" {
  make_complete_esp
  run run_check pre
  [ "$status" -eq 0 ]
}

@test "pre: refuses when Limine is set up but the fallback is gone" {
  make_complete_esp
  rm "$ESP/EFI/Linux/nova_linux-nova-fallback.efi"
  run run_check pre
  [ "$status" -eq 1 ]
  [[ $output == *"Refusing to change kernels"* ]]
}

@test "pre: NOVA_BOOT_CHECK=skip bypasses the refusal" {
  make_complete_esp
  rm "$ESP/EFI/BOOT/BOOTX64.EFI"
  NOVA_BOOT_CHECK=skip run run_check pre
  [ "$status" -eq 0 ]
}

@test "post: fails loudly on a fresh ESP because the install left no fallback" {
  run run_check post
  [ "$status" -eq 1 ]
  [[ $output == *"limine-update"* ]]
}

@test "post: NOVA_BOOT_CHECK=skip bypasses it too (the installer, before Limine is in)" {
  NOVA_BOOT_CHECK=skip run run_check post
  [ "$status" -eq 0 ]
  [[ $output == *skipped* ]]
}

@test "status: NOVA_BOOT_CHECK=skip does not hide what is missing" {
  NOVA_BOOT_CHECK=skip run run_check status
  [ "$status" -eq 1 ]
}

@test "no check is required when MKINITCPIO_FALLBACK is not a single kernel" {
  printf '%s\n' 'MKINITCPIO_FALLBACK=no' >"$CONF/10-nova.conf"
  run run_check post
  [ "$status" -eq 0 ]
}

@test "the CLI rejects an unknown mode" {
  run "$REPO_ROOT/data/boot/bin/nova-boot-check" bogus
  [ "$status" -eq 2 ]
}
