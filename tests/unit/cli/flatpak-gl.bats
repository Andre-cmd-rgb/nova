#!/usr/bin/env bats
# nova-flatpak-gl: Flatpak's NVIDIA graphics runtime kept in step with the
# installed driver, with flatpak and pacman stubbed and the loaded module's
# version in a file of the test's own.

load ../test_helper

GL="$REPO_ROOT/src/cli/bin/nova-flatpak-gl"

setup() {
  setup_scratch
  export CALLS="$SCRATCH/calls" NOVA_NVIDIA_VERSION_FILE="$SCRATCH/nvidia-version" NOVA_FLATPAK="$SCRATCH/bin/flatpak"
  # The login check remembers what Flathub lacked in the home's state folder.
  export HOME="$SCRATCH/home"
  MISSING="$HOME/.local/state/nova/flatpak-gl-missing"
  mkdir -p "$SCRATCH/bin"
  : >"$CALLS"
  # pacman: nvidia-utils at $NVIDIA_UTILS, if set.
  cat >"$SCRATCH/bin/pacman" <<'STUB'
#!/bin/bash
[[ $1 == -Q && $2 == nvidia-utils && -n ${NVIDIA_UTILS:-} ]] || exit 1
echo "nvidia-utils $NVIDIA_UTILS"
STUB
  # flatpak: each installation's runtimes in $SCRATCH/runtimes-<scope>, one
  # "id origin" a line; anything else is logged.
  cat >"$SCRATCH/bin/flatpak" <<'STUB'
#!/bin/bash
if [[ $1 == list ]]; then
  scope=${2#--}
  if [[ $* == *origin* ]]; then cat "$SCRATCH/runtimes-$scope" 2>/dev/null; else awk '{ print $1 }' "$SCRATCH/runtimes-$scope" 2>/dev/null; fi
  exit 0
fi
echo "FLATPAK_GL_DRIVERS=$FLATPAK_GL_DRIVERS flatpak $*" >>"$CALLS"
[[ ! -e $SCRATCH/flatpak-says ]] || cat "$SCRATCH/flatpak-says" >&2
exit "$(cat "$SCRATCH/flatpak-status" 2>/dev/null || echo 0)"
STUB
  chmod +x "$SCRATCH/bin/pacman" "$SCRATCH/bin/flatpak"
  export PATH="$SCRATCH/bin:$PATH"
}

teardown() { teardown_scratch; }

@test "drivers: the installed driver's and the loaded one's until a restart, then Mesa's and the host's" {
  echo 620.70.06 >"$NOVA_NVIDIA_VERSION_FILE"
  NVIDIA_UTILS=620.73.04-1 run "$GL" drivers
  [ "$output" = nvidia-620-70-06:nvidia-620-73-04:default:host ]
  # After the restart, one.
  echo 620.73.04 >"$NOVA_NVIDIA_VERSION_FILE"
  NVIDIA_UTILS=1:620.73.04-2 run "$GL" drivers
  [ "$output" = nvidia-620-73-04:default:host ]
}

@test "drivers: the card off the bus, no module loaded: the installed driver's still" {
  NVIDIA_UTILS=620.73.04-1 run "$GL" drivers
  [ "$output" = nvidia-620-73-04:default:host ]
}

@test "drivers: no NVIDIA driver at all is flatpak's own list" {
  run "$GL" drivers
  [ "$output" = default:host ]
}

@test "run: the command with the list in its environment" {
  NVIDIA_UTILS=620.73.04-1 run "$GL" run sh -c 'echo "$FLATPAK_GL_DRIVERS"'
  [ "$output" = nvidia-620-73-04:default:host ]
}

@test "check: an installation running GL apps without the installed driver's extension, as the P1's after its restart" {
  echo 620.73.04 >"$NOVA_NVIDIA_VERSION_FILE"
  printf '%s\n' 'org.freedesktop.Platform.GL.default flathub' 'org.freedesktop.Platform.GL.nvidia-620-70-06 flathub' >"$SCRATCH/runtimes-user"
  printf '%s\n' 'org.freedesktop.Platform.GL.default flathub' 'org.freedesktop.Platform.GL.nvidia-620-73-04 flathub' >"$SCRATCH/runtimes-system"
  NVIDIA_UTILS=620.73.04-1 run "$GL" check
  [ "$status" -eq 1 ]
  [ "$output" = "the user Flatpak installation lacks org.freedesktop.Platform.GL.nvidia-620-73-04 for NVIDIA's driver" ]
}

@test "check: all there, no GL apps, or no NVIDIA driver is nothing to say" {
  printf '%s\n' 'org.freedesktop.Platform.GL.default flathub' 'org.freedesktop.Platform.GL.nvidia-620-73-04 flathub' >"$SCRATCH/runtimes-user"
  NVIDIA_UTILS=620.73.04-1 run "$GL" check
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf 'org.gnome.Platform flathub\n' >"$SCRATCH/runtimes-user"
  NVIDIA_UTILS=620.73.04-1 run "$GL" check
  [ "$status" -eq 0 ]
  printf 'org.freedesktop.Platform.GL.default flathub\n' >"$SCRATCH/runtimes-user"
  run "$GL" check
  [ "$status" -eq 0 ]
}

@test "sync: the missing extensions from the remote the others came from, 32-bit where there are 32-bit ones" {
  printf '%s\n' 'org.freedesktop.Platform.GL.default flathub-beta' 'org.freedesktop.Platform.GL32.default flathub-beta' >"$SCRATCH/runtimes-user"
  printf '%s\n' 'org.freedesktop.Platform.GL.default flathub' 'org.freedesktop.Platform.GL.nvidia-620-73-04 flathub' >"$SCRATCH/runtimes-system"
  NVIDIA_UTILS=620.73.04-1 run "$GL" sync
  [ "$status" -eq 0 ]
  [ "$(cat "$CALLS")" = "FLATPAK_GL_DRIVERS=nvidia-620-73-04:default:host flatpak install --user -y --noninteractive flathub-beta org.freedesktop.Platform.GL.nvidia-620-73-04 org.freedesktop.Platform.GL32.nvidia-620-73-04" ]
}

@test "sync --quiet: offline, it says nothing and does not fail; with nothing missing, flatpak is not asked" {
  printf 'org.freedesktop.Platform.GL.default flathub\n' >"$SCRATCH/runtimes-user"
  echo 1 >"$SCRATCH/flatpak-status"
  NVIDIA_UTILS=620.73.04-1 run "$GL" sync --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  NVIDIA_UTILS=620.73.04-1 run "$GL" sync
  [ "$status" -eq 1 ]
  : >"$CALLS"
  printf 'org.freedesktop.Platform.GL.nvidia-620-73-04 flathub\n' >>"$SCRATCH/runtimes-user"
  NVIDIA_UTILS=620.73.04-1 run "$GL" sync --quiet
  [ ! -s "$CALLS" ]
}

@test "a version that is not one is no extension's name" {
  echo '620.73.04; rm -rf /' >"$NOVA_NVIDIA_VERSION_FILE"
  NVIDIA_UTILS='../../x-1' run "$GL" drivers
  [ "$output" = default:host ]
  run "$GL" drivers --bogus
  [ "$status" -eq 2 ]
}

@test "nova update and the App Center run flatpak with the list, and the login check is on" {
  grep -q 'FLATPAK_GL_DRIVERS=$drivers "$FLATPAK" update' "$REPO_ROOT/src/cli/bin/nova-update"
  grep -q 'FLATPAK_GL_DRIVERS=$drivers "$FLATPAK" uninstall .* --unused' "$REPO_ROOT/src/cli/bin/nova-update"
  [ "$(grep -c '^  gl_drivers$\|^      gl_drivers$' "$REPO_ROOT/src/apps/bin/nova-apps-job")" -eq 2 ]
  grep -q 'graphical-session.target.wants/nova-flatpak-gl.service' "$REPO_ROOT/data/systemd/install.mk"
}

# What flatpak says when the remote has no such ref, and when it cannot reach it.
lacks() { echo 1 >"$SCRATCH/flatpak-status"; echo "error: Nothing matches $1 in remote flathub" >"$SCRATCH/flatpak-says"; }
offline() { echo 1 >"$SCRATCH/flatpak-status"; echo "error: Unable to load summary from remote flathub: Could not resolve hostname" >"$SCRATCH/flatpak-says"; }

@test "sync --quiet: an extension Flathub lacks is asked for again a day later, then twice as long each time, a week at most" {
  printf 'org.freedesktop.Platform.GL.default flathub\n' >"$SCRATCH/runtimes-user"
  lacks org.freedesktop.Platform.GL.nvidia-620-73-04
  NVIDIA_UTILS=620.73.04-1 run "$GL" sync --quiet
  [ "$status" -eq 0 ]
  [ "$(grep -c 'flatpak install' "$CALLS")" -eq 1 ]
  read -r scope ref misses next <"$MISSING"
  [ "$scope $ref $misses" = "user org.freedesktop.Platform.GL.nvidia-620-73-04 1" ]
  ((next > $(date +%s) + 86000 && next <= $(date +%s) + 86400))
  # The next login, the same day: Flathub is not asked.
  NVIDIA_UTILS=620.73.04-1 run "$GL" sync --quiet
  [ "$(grep -c 'flatpak install' "$CALLS")" -eq 1 ]
  # A day on, it is, and still missing waits two days, then four, then seven.
  local wait
  for wait in 2 4 7 7; do
    sed -i "s/ [0-9]*\$/ 1/" "$MISSING"
    NVIDIA_UTILS=620.73.04-1 run "$GL" sync --quiet
    read -r scope ref misses next <"$MISSING"
    ((next > $(date +%s) + wait * 86400 - 400 && next <= $(date +%s) + wait * 86400))
  done
  [ "$(grep -c 'flatpak install' "$CALLS")" -eq 5 ]
}

@test "sync --quiet: without a network nothing is remembered, and the next login tries again" {
  printf 'org.freedesktop.Platform.GL.default flathub\n' >"$SCRATCH/runtimes-user"
  offline
  NVIDIA_UTILS=620.73.04-1 run "$GL" sync --quiet
  [ "$status" -eq 0 ]
  [ ! -s "$MISSING" ]
  NVIDIA_UTILS=620.73.04-1 run "$GL" sync --quiet
  [ "$(grep -c 'flatpak install' "$CALLS")" -eq 2 ]
}

@test "sync: a new driver's extension is asked for at once, and sync without --quiet always asks" {
  printf 'org.freedesktop.Platform.GL.default flathub\n' >"$SCRATCH/runtimes-user"
  lacks org.freedesktop.Platform.GL.nvidia-620-73-04
  NVIDIA_UTILS=620.73.04-1 run "$GL" sync --quiet
  # By hand (nova doctor's advice), whatever the login check remembers.
  NVIDIA_UTILS=620.73.04-1 run "$GL" sync
  [ "$status" -eq 1 ]
  [ "$(grep -c 'flatpak install' "$CALLS")" -eq 2 ]
  # The next driver: other refs, asked for at the next login.
  rm "$SCRATCH/flatpak-status" "$SCRATCH/flatpak-says"
  NVIDIA_UTILS=625.10.01-1 run "$GL" sync --quiet
  [ "$(grep -c 'flatpak install.*nvidia-625-10-01' "$CALLS")" -eq 1 ]
  # Once it is in, what was remembered of the old one goes.
  [ ! -s "$MISSING" ]
}
