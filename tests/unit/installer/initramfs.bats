#!/usr/bin/env bats

load ../test_helper

HOOK="$REPO_ROOT/data/boot/mkinitcpio/install/nova-blacklist"

setup() { setup_scratch; }
teardown() { teardown_scratch; }

# What `modprobe -c` prints, in short: nvidia-utils' blacklist among the rest.
modprobe_says() {
  mkdir -p "$SCRATCH/bin"
  { printf '#!/bin/sh\ncat <<"CONF"\n'; printf '%s\n' "$@"; printf 'CONF\n'; } >"$SCRATCH/bin/modprobe"
  chmod +x "$SCRATCH/bin/modprobe"
  PATH="$SCRATCH/bin:$PATH"
}

found() { printf '%s\n' "${!_autodetect_cache[@]}" | sort | tr '\n' ' '; }

@test "nova-blacklist: what modprobe blacklists leaves what autodetect found" {
  modprobe_says 'blacklist nouveau' 'blacklist nova-core' 'options nvidia NVreg_DynamicPowerManagement=0x02' \
    'alias pci:v000010DEd*sv*sd*bc03sc*i* nouveau' 'softdep nouveau pre: mxm_wmi'
  declare -A _autodetect_cache=([nouveau]=1 [nova_core]=1 [i915]=1 [btrfs]=1 [nvidia]=1)
  # shellcheck source=/dev/null
  source "$HOOK"
  build
  [ "$(found)" = "btrfs i915 nvidia " ]
}

@test "nova-blacklist: nothing blacklisted, nothing taken out" {
  modprobe_says 'options i915 enable_guc=3'
  declare -A _autodetect_cache=([nouveau]=1 [i915]=1)
  # shellcheck source=/dev/null
  source "$HOOK"
  build
  [ "$(found)" = "i915 nouveau " ]
}

@test "nova-blacklist: an image built without autodetect is left as it is" {
  mkdir -p "$SCRATCH/bin"
  printf '#!/bin/sh\necho asked >>"%s"\n' "$SCRATCH/asked" >"$SCRATCH/bin/modprobe"
  chmod +x "$SCRATCH/bin/modprobe"
  PATH="$SCRATCH/bin:$PATH"
  declare -A _autodetect_cache=()
  # shellcheck source=/dev/null
  source "$HOOK"
  build
  [ ! -e "$SCRATCH/asked" ]
}

@test "10-nova.conf: nova-blacklist runs right after autodetect, before the hooks that add modules" {
  run bash -c '. "$1"; echo "${HOOKS[*]}"' _ "$REPO_ROOT/data/boot/mkinitcpio/10-nova.conf"
  [[ $output == "base systemd autodetect nova-blacklist "* ]]
}

@test "install: the hook lands where mkinitcpio looks for it" {
  grep -q 'mkinitcpio/install/nova-blacklist $(DESTDIR)$(PREFIX)/lib/initcpio/install/nova-blacklist' "$REPO_ROOT/data/boot/install.mk"
}
