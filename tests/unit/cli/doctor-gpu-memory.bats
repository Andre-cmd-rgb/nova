#!/usr/bin/env bats

# nova-doctor-gpu-memory: the graphics memory each process holds, from the DRM
# fdinfo of the descriptors it has open on /dev/dri, each client once
# (by its device and drm-client-id) however many descriptors and processes
# hold it, with its shared part apart. Read from a /proc of the test's own.

load ../test_helper

setup() {
  setup_scratch
  export NOVA_PROC=$SCRATCH/proc
}

teardown() { teardown_scratch; }

TOOL="$REPO_ROOT/src/cli/bin/nova-doctor-gpu-memory"

process() { # pid comm
  mkdir -p "$NOVA_PROC/$1/fd" "$NOVA_PROC/$1/fdinfo"
  echo "$2" >"$NOVA_PROC/$1/comm"
}

# A descriptor on <node> with these drm- lines after the usual three.
descriptor() { # pid fd node line...
  local pid=$1 fd=$2 node=$3
  shift 3
  ln -s "$node" "$NOVA_PROC/$pid/fd/$fd"
  { printf 'pos:\t0\nflags:\t02100002\nmnt_id:\t26\n'; printf '%s\n' "$@"; } >"$NOVA_PROC/$pid/fdinfo/$fd"
}

client() { # pid fd id total shared [pdev]
  descriptor "$1" "$2" /dev/dri/renderD128 $'drm-driver:\ti915' "drm-client-id:	$3" "drm-pdev:	${6:-0000:00:02.0}" \
    "drm-total-system0:	$4" "drm-shared-system0:	$5" "drm-resident-system0:	$4" $'drm-total-stolen-system0:\t0' \
    $'drm-engine-render:\t123456 ns'
}

@test "a client held under four descriptors counts once, and processes go largest first" {
  process 964 Hyprland
  for fd in 43 44 45 46; do client 964 "$fd" 7 '841984 KiB' '479744 KiB'; done
  process 1107 quickshell
  client 1107 34 12 '232060 KiB' '88 MiB'
  client 1107 35 12 '232060 KiB' '88 MiB'
  run "$TOOL"
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "     822.2      468.5  Hyprland (964)" ]
  [ "${lines[2]}" = "     226.6       88.0  quickshell (1107)" ]
  [ "${lines[3]}" = "    1048.9      556.5  all, each client once; not shared: 492.4 MiB" ]
  run "$TOOL" --total
  [ "$output" = "1074044 569856 1074044" ]
}

@test "a client handed to another process counts for the first, and the same id on another card apart" {
  process 100 compositor
  client 100 5 3 '10 MiB' '0'
  process 200 game
  client 200 9 3 '10 MiB' '0'
  client 200 10 3 '1048576' '0' 0000:01:00.0
  run "$TOOL" --total
  [ "$output" = "11264 0 11264" ]
  run "$TOOL"
  [[ $output == *"10.0        0.0  compositor (100)"* ]]
  [[ $output == *"1.0        0.0  game (200)"* ]]
}

@test "the older drm-memory- lines count as the total" {
  process 300 old
  descriptor 300 4 /dev/dri/card0 $'drm-driver:\tamdgpu' $'drm-client-id:\t1' $'drm-pdev:\t0000:03:00.0' $'drm-memory-vram:\t2 MiB' $'drm-memory-gtt:\t1024 KiB'
  run "$TOOL" --total
  [ "$output" = "3072 0 0" ]
}

@test "descriptors on anything but /dev/dri, and DRM files that count nothing, are passed over" {
  process 400 editor
  descriptor 400 3 /home/x/file $'drm-client-id:\t1' $'drm-total-system0:\t5 MiB'
  descriptor 400 4 /dev/dri/renderD128 $'drm-driver:\tnvidia-drm'
  run "$TOOL"
  [ "$output" = "No process holds graphics memory the drivers count." ]
  run "$TOOL" --total
  [ "$output" = "0 0 0" ]
}

@test "anything else is a usage error" {
  run "$TOOL" --json
  [ "$status" -eq 2 ]
}
