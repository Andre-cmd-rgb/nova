#!/usr/bin/env bats

# 10-nova.preset, at a Pi's first boot: what systemd presets there, with its
# own 90-systemd.preset beside Nova's, leaves what the image enabled as it is
# and enables nothing more.

load ../test_helper

setup() {
  setup_scratch
  root=$SCRATCH/root
  mkdir -p "$root/usr/lib/systemd/system" "$root/usr/lib/systemd/system-preset" "$root/etc/systemd/system"
  for unit in greetd NetworkManager systemd-networkd systemd-homed; do
    printf '[Service]\nExecStart=/bin/true\n[Install]\nWantedBy=multi-user.target\n' \
      >"$root/usr/lib/systemd/system/$unit.service"
  done
  printf 'enable systemd-networkd.service\nenable systemd-homed.service\n' \
    >"$root/usr/lib/systemd/system-preset/90-systemd.preset"
  echo 'disable *' >"$root/usr/lib/systemd/system-preset/99-default.preset"
  cp "$REPO_ROOT/data/raspberry-pi/systemd/10-nova.preset" "$root/usr/lib/systemd/system-preset/"
  # What tools/build-pi-image enables.
  systemctl --root="$root" enable --quiet greetd.service NetworkManager.service
}

teardown() { teardown_scratch; }

@test "a first boot's presets enable nothing, and keep what the image enabled" {
  # The mode systemd presets in at a first boot.
  systemctl --root="$root" preset-all --preset-mode=enable-only
  [ "$(systemctl --root="$root" is-enabled greetd.service)" = enabled ]
  [ "$(systemctl --root="$root" is-enabled NetworkManager.service)" = enabled ]
  [ "$(systemctl --root="$root" is-enabled systemd-networkd.service)" = disabled ]
  [ "$(systemctl --root="$root" is-enabled systemd-homed.service)" = disabled ]
}

@test "without it, systemd's own list would turn on systemd-networkd beside NetworkManager" {
  rm "$root/usr/lib/systemd/system-preset/10-nova.preset"
  systemctl --root="$root" preset-all --preset-mode=enable-only
  [ "$(systemctl --root="$root" is-enabled systemd-networkd.service)" = enabled ]
}
