#!/usr/bin/env bats

load ../test_helper

setup() {
  setup_scratch
  export NOVA_HARDWARE="$REPO_ROOT/data/hardware"
  export NOVA_DMI_PATH="$SCRATCH/dmi"
  export NOVA_ROOT="$SCRATCH/root"
  mkdir -p "$NOVA_DMI_PATH" "$NOVA_ROOT"
}

teardown() { teardown_scratch; }

detect="$REPO_ROOT/data/hardware/bin/nova-hw-detect"
apply="$REPO_ROOT/data/hardware/bin/nova-hw-apply"

model() { printf '%s\n' "$1" >"$NOVA_DMI_PATH/product_version"; }

@test "detect: the P1 Gen 4i matches exactly" {
  model "ThinkPad P1 Gen 4i"
  run "$detect"
  [ "$status" -eq 0 ]
  [ "$output" = thinkpad-p1-gen4i ]
}

@test "detect: a Legion 5, whose placeholder profile is gone, is a computer without one" {
  model "Legion 5 15ACH6H"
  run "$detect"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
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

@test "detect: every profile in the models list exists" {
  local columns profile
  while IFS=$'\t' read -r -a columns; do
    ((${#columns[@]} >= 2)) && [[ ${columns[0]} != \#* ]] || continue
    profile=${columns[-1]}
    [ -d "$NOVA_HARDWARE/$profile" ]
    [ -f "$NOVA_HARDWARE/$profile/packages" ]
  done <"$NOVA_HARDWARE/models"
}

# A models list of the test's own, beside Nova's profiles, and a computer's
# DMI fields, each field=value.
models() { # line...
  mkdir -p "$SCRATCH/hardware"
  printf '%s\n' "$@" >"$SCRATCH/hardware/models"
  export NOVA_HARDWARE=$SCRATCH/hardware
}

computer() { # field=value...
  local pair
  rm -rf "$NOVA_DMI_PATH"
  mkdir -p "$NOVA_DMI_PATH"
  for pair in "$@"; do printf '%s \n' "${pair#*=}" >"$NOVA_DMI_PATH/${pair%%=*}"; done
}

# The profile Hyprland's loader (data/hypr/hardware.lua) picks for the same
# list and fields: each profile's module prints its name.
hypr_profile() {
  local line profile
  mkdir -p "$SCRATCH/nova/default/hypr/hardware"
  ln -sfn "$NOVA_HARDWARE" "$SCRATCH/nova/hardware"
  while IFS= read -r line; do
    profile=${line##*$'\t'}
    printf 'print("%s")\n' "$profile" >"$SCRATCH/nova/default/hypr/hardware/$profile.lua"
  done < <(grep -v '^#' "$NOVA_HARDWARE/models")
  DMI=$NOVA_DMI_PATH HYPR=$REPO_ROOT/data/hypr NOVA_PATH=$SCRATCH/nova HOME=$SCRATCH lua -e '
    local dmi, open = os.getenv("DMI"), io.open
    io.open = function(path, mode) return open((path:gsub("^/sys/class/dmi/id", dmi)), mode) end
    dofile(os.getenv("HYPR") .. "/lib.lua")
    dofile(os.getenv("HYPR") .. "/hardware.lua")' </dev/null
}

# Both readers pick the same profile, this one, or none (-).
picks() { # profile|-
  local detected
  detected=$("$detect") || detected=-
  [ "$detected" = "$1" ]
  [ "$(hypr_profile)" = "${1#-}" ]
}

@test "models: a line can name the field it matches, with the maker's beside it" {
  models 'ThinkPad P1 Gen 4i	thinkpad-p1-gen4i' \
    'sys_vendor=Framework	product_name=Laptop 13 (AMD Ryzen 7040Series)	framework-13-amd' \
    'product_name=XPS 13 93*	xps-13' \
    'board_vendor=ASUSTeK COMPUTER INC.	board_name=ROG STRIX B650E-F GAMING WIFI	strix-b650e'
  computer sys_vendor=Framework "product_name=Laptop 13 (AMD Ryzen 7040Series)" product_version=A6
  picks framework-13-amd
  computer sys_vendor=Other "product_name=Laptop 13 (AMD Ryzen 7040Series)"
  picks -
  computer "sys_vendor=Dell Inc." "product_name=XPS 13 9340"
  picks xps-13
  computer "board_vendor=ASUSTeK COMPUTER INC." "board_name=ROG STRIX B650E-F GAMING WIFI" "product_name=System Product Name"
  picks strix-b650e
  # A bare pattern is product_version's, as it always was.
  computer sys_vendor=LENOVO product_name=20Y3S0CU00 "product_version=ThinkPad P1 Gen 4i"
  picks thinkpad-p1-gen4i
  computer sys_vendor=LENOVO "product_name=ThinkPad P1 Gen 4i"
  picks -
}

@test "models: only * is special, a field it does not know or the computer lacks matches nothing" {
  models 'product_name=Odd [model]?	odd' 'serial=1234	serial' 'board_name=*	any-board'
  computer "product_name=Odd [model]?"
  picks odd
  computer "product_name=Odd m?"
  picks -
  computer "product_version=serial=1234"
  picks serial
  computer product_name=Something
  picks -
  computer product_name=Something board_name=B650
  picks any-board
}

@test "detect: a computer with a name but no product_version is still known, and none at all is not knowing" {
  models 'product_name=Laptop 13*	framework-13'
  computer "product_name=Laptop 13 (Intel Core Ultra 1)"
  run "$detect"
  [ "$status" -eq 0 ]
  [ "$output" = framework-13 ]
  computer
  run "$detect"
  [ "$status" -eq 2 ]
}

@test "apply: installs the profile and records exactly what it installed" {
  model "ThinkPad P1 Gen 4i"
  run "$apply"
  [ "$status" -eq 0 ]
  [ -f "$NOVA_ROOT/etc/modprobe.d/nova-hw-nvidia-fbdev.conf" ]
  [ -f "$NOVA_ROOT/etc/NetworkManager/conf.d/nova-hw-wifi-powersave.conf" ]
  [ "$(wc -l <"$NOVA_ROOT/var/lib/nova/hardware-files")" -eq "$(find "$NOVA_HARDWARE/thinkpad-p1-gen4i/etc" -type f | wc -l)" ]
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

@test "apply: a portable Nova takes no model's files, and drops any it had" {
  model "ThinkPad P1 Gen 4i"
  "$apply"
  [ -n "$(find "$NOVA_ROOT/etc" -type f)" ]
  write_file "$NOVA_ROOT/etc/nova/portable" "# portable"
  run "$apply"
  [ "$status" -eq 0 ]
  [ -z "$(find "$NOVA_ROOT/etc" -type f ! -path '*/etc/nova/portable')" ]
  [ ! -s "$NOVA_ROOT/var/lib/nova/hardware-files" ]
}

@test "a portable Nova started on a P1 runs none of the P1's power services" {
  local unit
  for unit in nova-power.service nova-power-gpu.service nova-power-gpu.timer nova-powerd.service nova-undervolt.service; do
    grep -qx 'ConditionPathExists=!/etc/nova/portable' "$REPO_ROOT/src/power/systemd/$unit"
  done
}

@test "the P1's GPU retry timer is enabled by nothing: nova-power starts it when there is something to retry" {
  fails grep -q '^\[Install\]' "$REPO_ROOT/src/power/systemd/nova-power-gpu.timer"
  fails grep -q 'OnUnitActiveSec\|OnBootSec' "$REPO_ROOT/src/power/systemd/nova-power-gpu.timer"
  fails grep -q 'nova-power-gpu.timer' "$REPO_ROOT/src/power/install.mk"
  grep -q 'systemctl restart --no-block nova-power-gpu.timer' "$REPO_ROOT/src/power/bin/nova-power"
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

# nova-hw-model: the name, from the field its maker keeps it in.
hw_model="$REPO_ROOT/data/hardware/bin/nova-hw-model"

dmi() { # field value...
  while (($# >= 2)); do
    printf '%s\n' "$2" >"$NOVA_DMI_PATH/$1"
    shift 2
  done
}

@test "model: a Lenovo's name is its product_version, not the type number" {
  dmi sys_vendor LENOVO product_name 20Y4S0ER00 product_version "ThinkPad P1 Gen 4i" board_name 20Y4S0ER00
  run "$hw_model"
  [ "$status" -eq 0 ]
  [ "$output" = "ThinkPad P1 Gen 4i" ]
}

@test "model: every other maker's is its product_name, whatever revision product_version holds" {
  dmi sys_vendor Framework product_name "Laptop 13 (AMD Ryzen 7040Series)" product_version A6 board_name FRANMDCP06
  run "$hw_model"
  [ "$output" = "Laptop 13 (AMD Ryzen 7040Series)" ]
  dmi sys_vendor "ASUSTeK COMPUTER INC." product_name "ROG Zephyrus G14 GA401QM" product_version 1.0
  run "$hw_model"
  [ "$output" = "ROG Zephyrus G14 GA401QM" ]
  dmi sys_vendor "Dell Inc." product_name "XPS 13 9310 " product_version ""
  run "$hw_model"
  [ "$output" = "XPS 13 9310" ]
}

@test "model: a PC built from parts is named by its mainboard" {
  dmi sys_vendor "To Be Filled By O.E.M." product_name "To Be Filled By O.E.M." product_version "To Be Filled By O.E.M." \
    board_name "B550 AORUS ELITE"
  run "$hw_model"
  [ "$output" = "B550 AORUS ELITE" ]
  dmi sys_vendor ASUS product_name "System Product Name" product_version "System Version" board_name "ROG STRIX B550-F GAMING"
  run "$hw_model"
  [ "$output" = "ROG STRIX B550-F GAMING" ]
  dmi sys_vendor "Micro-Star" product_name "Default string" product_version "Default string" board_name "MAG B650 TOMAHAWK"
  run "$hw_model"
  [ "$output" = "MAG B650 TOMAHAWK" ]
}

@test "model: a Lenovo with nothing in product_version falls back to its product_name" {
  dmi sys_vendor LENOVO product_name "Legion 5 15ACH6H" product_version None
  run "$hw_model"
  [ "$output" = "Legion 5 15ACH6H" ]
}

@test "model: no field that names the computer, no name, and exit 1" {
  run "$hw_model"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  dmi sys_vendor QEMU product_name "Not Specified" product_version "N/A" board_name "Default string"
  run "$hw_model"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# The profile's boot files (modprobe.d, the kernel's command line) are read
# when the boot entries are built, which this does not do: an update that
# changes one says when it takes effect, and one that changes none says
# nothing.
@test "apply: an update that changes a boot file says when it takes effect, and only then" {
  model "ThinkPad P1 Gen 4i"
  # The first install: its boot entries are built after this, nothing to say.
  run "$apply"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # The same files again: nothing changed.
  run "$apply"
  [ -z "$output" ]
  # An update that brings a file to blacklist a module.
  rm "$NOVA_ROOT/etc/modprobe.d/nova-hw-xe.conf"
  run "$apply"
  [ "$status" -eq 0 ]
  [ "$output" = "nova-hw-apply: /etc/modprobe.d/nova-hw-xe.conf changed; it takes effect once the boot entries are built again: at the next kernel update, or now with sudo limine-update." ]
  # A file the boot does not read changes quietly.
  echo changed >"$NOVA_ROOT/etc/NetworkManager/conf.d/nova-hw-wifi-powersave.conf"
  run "$apply"
  [ -z "$output" ]
  [ "$(cat "$NOVA_ROOT/etc/NetworkManager/conf.d/nova-hw-wifi-powersave.conf")" = "$(cat "$NOVA_HARDWARE/thinkpad-p1-gen4i/etc/NetworkManager/conf.d/nova-hw-wifi-powersave.conf")" ]
}

# A model's document says how Nova wires it: each file its profile copies
# into /etc is named there, by its path under /etc.
@test "every file a profile puts in /etc is named in its model's document" {
  local missing=() model file
  for model in "$NOVA_HARDWARE"/*/etc; do
    model=${model%/etc}
    model=${model##*/}
    [ -f "$REPO_ROOT/docs/hardware/$model.md" ]
    while IFS= read -r file; do
      grep -qF -- "\`$file\`" "$REPO_ROOT/docs/hardware/$model.md" || missing+=("$model: $file")
    done < <(cd "$NOVA_HARDWARE/$model/etc" && find . -type f | sed 's|^\./||')
  done
  [ "${#missing[@]}" -eq 0 ] || { printf 'not named: %s\n' "${missing[@]}"; false; }
}
