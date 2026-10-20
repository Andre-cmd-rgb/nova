#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2190 # mkarchiso reads these, and declares file_permissions
#
# The Nova installer stick: a small Arch live system that boots straight into
# nova-install. Do not run mkarchiso on this directory directly: tools/build-iso
# copies it, adds the release's files (release.toml, the package list, the
# hardware profiles, nova-install itself) and a pacman.conf pinned to the
# release's Arch snapshot, then builds the copy.

iso_name="nova"
iso_label="NOVA_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="Nova <https://github.com/Andre-cmd-rgb/nova>"
iso_application="Nova installer"
iso_version="${NOVA_ISO_VERSION:-dev}"
install_dir="nova"
buildmodes=('iso')
# UEFI only: Nova boots with Limine on UEFI, and nova-install refuses BIOS.
bootmodes=('uefi.systemd-boot')
pacman_conf="pacman.conf"
# zstd rather than xz: a slightly bigger image that unpacks several times faster.
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15' '-b' '1M')
file_permissions=(
  ["/root"]="0:0:750"
  ["/usr/local/bin/nova-install"]="0:0:755"
  ["/usr/local/bin/nova-install-start"]="0:0:755"
  ["/usr/share/nova-installer/hardware/nova-hw-detect"]="0:0:755"
)
