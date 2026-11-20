#!/usr/bin/env bats

# nova-printer-setup, the "Find Driver" button of nova-sessiond's printer
# notices: system-config-printer's dialogs over D-Bus. busctl is a stub that
# logs each argument on a line of its own and answers NewPrinterDialog.

load ../test_helper

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls"
  mkdir -p "$SCRATCH/bin"
  busctl_answers 's "/org/fedoraproject/Config/Printing/NewPrinterDialog/3"'
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

busctl_answers() { # what NewPrinterDialog answers
  cat >"$SCRATCH/bin/busctl" <<EOF
#!/bin/bash
printf '%s\n' busctl "\$@" -- >>"\$CALLS"
[[ " \$* " != *" NewPrinterDialog "* ]] || echo '$1'
EOF
  chmod +x "$SCRATCH/bin/busctl"
}

helper="$REPO_ROOT/src/cli/bin/nova-printer-setup"
dialog=/org/fedoraproject/Config/Printing/NewPrinterDialog/3

@test "device: Print Settings' new printer at the device, its words each one argument" {
  run "$helper" device 'usb://Acme/Z?serial=1' "MFG:Acme;MDL:Z 'x' \"y\";DES:;CMD:;"
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "$(printf '%s\n' \
    busctl --user -- call org.fedoraproject.Config.Printing /org/fedoraproject/Config/Printing \
    org.fedoraproject.Config.Printing NewPrinterDialog -- \
    busctl --user --timeout=120 -- call org.fedoraproject.Config.Printing "$dialog" \
    org.fedoraproject.Config.Printing.NewPrinterDialog NewPrinterFromDevice uss 0 \
    'usb://Acme/Z?serial=1' "MFG:Acme;MDL:Z 'x' \"y\";DES:;CMD:;" --)" ]
}

@test "driver: the choice of another driver for a queue" {
  run "$helper" driver Office 'MFG:HP;MDL:LaserJet 1022;DES:;CMD:;'
  [ "$status" -eq 0 ]
  [ "$(tail -n 4 "$CALLS" | head -n 3 | paste -sd' ')" = "0 Office MFG:HP;MDL:LaserJet 1022;DES:;CMD:;" ]
  grep -qx ChangePPD "$CALLS"
}

@test "a dialog Print Settings did not open is said, and nothing more is asked" {
  busctl_answers 's "/somewhere/else"'
  run "$helper" device usb://x 'MFG:;'
  [ "$status" -eq 1 ]
  [ "$output" = "nova-printer-setup: Print Settings did not open its dialog" ]
  [ "$(grep -c '^busctl$' "$CALLS")" = 1 ]
}

@test "anything else is a usage error" {
  run "$helper" remove Office x
  [ "$status" -eq 2 ]
  run "$helper" device usb://x
  [ "$status" -eq 2 ]
  [ ! -e "$CALLS" ]
}
