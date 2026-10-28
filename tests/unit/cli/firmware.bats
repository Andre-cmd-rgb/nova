#!/usr/bin/env bats
load ../test_helper

setup() {
  setup_scratch
  export XDG_RUNTIME_DIR="$SCRATCH/run" PATH="$SCRATCH/bin:$PATH" FW_LOG="$SCRATCH/fw-log"
  mkdir -p "$SCRATCH/bin" "$XDG_RUNTIME_DIR"
  job="$REPO_ROOT/src/cli/bin/nova-firmware-job"
  cat >"$SCRATCH/bin/fwupdmgr" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$FW_LOG"
case $1 in
  refresh) exit "${REFRESH_STATUS:-0}" ;;
  get-updates)
    echo '{"Devices":[{"DeviceId":"abc123","Name":"System Firmware","Version":"1.0","Releases":[{"Version":"2.0","Summary":"Security fixes"}]}]}' \
      | jq --argjson flags "${CHECK_FLAGS:-0}" '.Devices[0].Flags = $flags'
    exit "${CHECK_STATUS:-0}" ;;
  get-devices)
    if [[ ${MULTI:-0} == 1 ]]; then
      if [[ -e $XDG_RUNTIME_DIR/fw-running ]]; then
        echo '{"Devices":[{"DeviceId":"abc123","Version":"2.0","Status":1},{"DeviceId":"def456","Version":"1.0","Status":3,"Percentage":25}]}'
      else
        echo '{"Devices":[{"DeviceId":"abc123","Version":"2.0","Status":1},{"DeviceId":"def456","Version":"2.0","Status":1}]}'
      fi
      exit
    fi
    flags=${DEVICE_FLAGS:-'["needs-reboot"]'}
    jq -cn --argjson flags "$flags" --argjson state "${UPDATE_STATE:-0}" \
      '{Devices: [{DeviceId: "abc123", Flags: $flags, UpdateState: $state}]}'
    exit "${DEVICE_STATUS:-0}" ;;

  --assume-yes)
    touch "$XDG_RUNTIME_DIR/fw-running"
    printf 'Writing: 25%%\r'
    for ((n=0; n<40; n++)); do
      if jq -e 'any(.devices[]; .progress == 25)' "$XDG_RUNTIME_DIR/nova/firmware.json" >/dev/null; then
        touch "$XDG_RUNTIME_DIR/progress-observed"
        break
      fi
      sleep 0.025
    done
    rm -f "$XDG_RUNTIME_DIR/fw-running"
    printf 'Writing: 100%%\n'
    exit "${INSTALL_STATUS:-0}" ;;
esac
STUB
  cat >"$SCRATCH/bin/systemd-run" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >"$XDG_RUNTIME_DIR/service-args"
STUB
  printf '#!/bin/bash\necho inactive\n' >"$SCRATCH/bin/systemctl"
  chmod +x "$SCRATCH/bin/"*
}
teardown() { teardown_scratch; }

@test "firmware check lists device versions and survives an offline refresh" {
  REFRESH_STATUS=1 run "$job" run check
  [ "$status" -eq 0 ]
  jq -e '.devices[0].current == "1.0" and .devices[0].version == "2.0" and .checked and (.running | not) and (.error | contains("saved"))' "$XDG_RUNTIME_DIR/nova/firmware.json"
  [ "$(head -1 "$FW_LOG")" = refresh ]
}

@test "firmware exit two means no updates and a failed check is visible" {
  CHECK_STATUS=2 run "$job" run check
  [ "$status" -eq 0 ]
  jq -e '.devices == [] and .checked and (.running | not)' "$XDG_RUNTIME_DIR/nova/firmware.json"
  CHECK_STATUS=1 run "$job" run check
  [ "$status" -eq 1 ]
  jq -e '.running | not' "$XDG_RUNTIME_DIR/nova/firmware.json"
}

@test "firmware installation records progress, success and reboot" {
  "$job" run check
  run "$job" run install abc123
  [ "$status" -eq 0 ]
  [ -e "$XDG_RUNTIME_DIR/progress-observed" ]
  jq -e '.devices[0].progress == 100 and .devices[0].status == "installed" and .reboot and (.running | not)' "$XDG_RUNTIME_DIR/nova/firmware.json"
  [[ $(cat "$FW_LOG") == *'--assume-yes --no-reboot-check --no-unreported-check update abc123'* ]]
}

@test "firmware failures persist and unknown devices never reach the daemon" {
  "$job" run check
  run "$job" run install --help
  [ "$status" -ne 0 ]
  [[ $(cat "$FW_LOG") != *update\ --help* ]]
  INSTALL_STATUS=1 run "$job" run install abc123
  [ "$status" -eq 1 ]
  jq -e '.devices[0].status == "failed" and (.running | not) and (.error | contains("Writing"))' "$XDG_RUNTIME_DIR/nova/firmware.json"
}

@test "firmware launch belongs to a collected user service" {
  run "$job" install abc123
  [ "$status" -eq 0 ]
  [ "$(head -1 "$XDG_RUNTIME_DIR/service-args")" = --user ]
  [[ $(cat "$XDG_RUNTIME_DIR/service-args") == *--unit=nova-firmware-update*--collect*run*install*abc123* ]]
  [ ! -e "$FW_LOG" ]
}

@test "firmware reopening reports an interrupted job" {
  "$job" run check
  jq '.running = true' "$XDG_RUNTIME_DIR/nova/firmware.json" >"$SCRATCH/state"
  mv "$SCRATCH/state" "$XDG_RUNTIME_DIR/nova/firmware.json"
  run "$job" status
  [ "$status" -eq 0 ]
  jq -e '(.running | not) and (.error | contains("stopped"))' <<<"$output"
  [ "$(find "$XDG_RUNTIME_DIR/nova" -name 'firmware.??????' | wc -l)" -eq 0 ]
}

@test "firmware pending state requires a reboot while successful state alone does not" {
  "$job" run check
  DEVICE_FLAGS='[]' UPDATE_STATE=2 run "$job" run install abc123
  [ "$status" -eq 0 ]
  jq -e '.reboot | not' "$XDG_RUNTIME_DIR/nova/firmware.json"
  "$job" run check
  DEVICE_FLAGS='[]' UPDATE_STATE=1 run "$job" run install abc123
  [ "$status" -eq 0 ]
  jq -e '.reboot' "$XDG_RUNTIME_DIR/nova/firmware.json"
}

@test "firmware keeps the device reboot flag if it disappears after flashing" {
  CHECK_FLAGS=256 "$job" run check
  DEVICE_STATUS=1 run "$job" run install abc123
  [ "$status" -eq 0 ]
  jq -e '.reboot' "$XDG_RUNTIME_DIR/nova/firmware.json"
}

@test "a second firmware worker cannot change an active job" {
  mkdir -p "$XDG_RUNTIME_DIR/nova"
  exec 9>"$XDG_RUNTIME_DIR/nova/firmware.lock"
  flock -x 9
  run "$job" run check
  [ "$status" -eq 1 ]
  [ ! -e "$FW_LOG" ]
  exec 9>&-
}

@test "Install All uses one authorizing client and follows each device by ID" {
  "$job" run check
  jq '.devices += [{id:"def456", name:"Reader", current:"1.0", version:"2.0", summary:"Fix", status:"available", progress:0, needsReboot:false}]' \
    "$XDG_RUNTIME_DIR/nova/firmware.json" >"$SCRATCH/state"
  mv "$SCRATCH/state" "$XDG_RUNTIME_DIR/nova/firmware.json"
  MULTI=1 run "$job" run install abc123 def456
  [ "$status" -eq 0 ]
  [ -e "$XDG_RUNTIME_DIR/progress-observed" ]
  [ "$(grep -c '^--assume-yes' "$FW_LOG")" -eq 1 ]
  [[ $(cat "$FW_LOG") == *'update abc123 def456'* ]]
  jq -e 'all(.devices[]; .status == "installed" and .progress == 100)' "$XDG_RUNTIME_DIR/nova/firmware.json"
}
