# Raspberry Pi 5

How Nova runs on the Raspberry Pi 5, on Arch Linux ARM. The desktop is the
same as on a PC; what differs is everything under it: the firmware boots the
kernel itself, there is no btrfs and so no snapshots, the kernel cannot
suspend, and the screen is HDMI only. Tested on a Pi 5 (4 GB) with a 1024x600
HDMI panel and a 2560x1440 monitor, booting from a card and from a USB stick.

## How Nova wires it

The `nova` package for aarch64 (`NOVA_ARCH=aarch64` in `make install`) leaves
out the x86 boot chain (Limine, snapper, the x86 `nova-boot-check`, recovery)
and puts in `data/raspberry-pi/`. The profile, matched on the devicetree's
model, is `data/hardware/raspberry-pi-5/`.

| | |
|---|---|
| `/usr/lib/nova/bin/nova-boot-check` and its two pacman hooks | a kernel goes onto the boot partition, or not at all (fact 1) |
| `/etc/mkinitcpio.conf.d/10-nova.conf` | the initramfs without `autodetect` (fact 2) |
| `/usr/lib/nova/bin/nova-first-boot`, `nova-first-boot.service`, and a greetd drop-in | the image's setup at the first start (fact 6) |
| `/usr/share/nova/setup.bash` | the questions and system writes it shares with `nova-install` |
| `data/hardware/raspberry-pi-5/packages` | `ddcutil`, for the screen's brightness |
| `data/hardware/raspberry-pi-5/etc/` | `i2c-dev` loaded, and the HDMI DDC lines for whoever sits at the screen (fact 4); copied into `/etc` by `nova-hw-apply` |
| `/usr/share/nova/hardware/ddc-reversed` | screens whose brightness runs backwards (fact 5) |
| `nova-sleep-available` | the menu's Suspend only where logind can sleep (fact 3) |
| `whisper-cpp`, Nova's own build (`packaging/whisper-cpp`) | dictation's speech engine (fact 14) |
| `data/hypr/hardware/raspberry-pi-5.lua` | opaque windows, and a late frame rendered at once (fact 11) |
| `/usr/lib/clock-epoch`, from `tools/build-pi-image` | the clock starts no earlier than the image (fact 12) |
| `/usr/lib/systemd/system-preset/10-nova.preset` | the first start enables no service of its own (fact 13) |

The image itself is `tools/build-pi-image`'s: an MBR card with a 512 MiB FAT
`/boot` and an ext4 root, Arch Linux ARM's `linux-rpi-16k` kernel and
`raspberrypi-bootloader`, and nothing that names one Pi: no machine ID, no SSH
host keys, no user, the root account locked. Its pacman reads `[nova]` and
`[nova-alarm]`, the release's own copy of the Arch Linux ARM packages it was
built from, before Arch Linux ARM's live repositories
([releasing.md](../releasing.md)).

## Facts

**1. The firmware reads the kernel from the FAT partition, whatever is
mounted.** `kernel8.img` and `initramfs-linux.img` live on the partition at
`/boot`. A kernel update while it is not mounted (an fstab typo, a failed
fsck) writes them into the root filesystem's `/boot`, where the firmware never
looks: the Pi then starts the old kernel, whose modules the update has
removed, and comes up without Wi-Fi, USB or a screen. `nova-boot-check pre`
aborts such a transaction; `post` compares the image's `Linux version` banner
with the installed modules; `nova update` and `nova doctor` run `status`.

**2. `autodetect` picks the build machine's drivers.** The image is built in
a container on another arm64 machine, so an initramfs made with `autodetect`
holds that machine's storage drivers, not the Pi's. A Pi's root also moves
between a card, a USB stick and an NVMe drive more than a PC's does. Without
it the initramfs is a few megabytes bigger and boots from any of them.
`sd-vconsole` stays, so a prompt before the root is mounted (an fsck asking)
has the right keyboard.

**3. A Pi cannot suspend.** logind's `CanSleep` answers `na`, and
`systemctl sleep` fails. The menu asks `nova-sleep-available`, which is
logind's own answer, so a Pi shows no Suspend and a PC is unchanged. Hibernate
already had its own check, and Restart to Recovery is the x86 boot menu, which
the Pi does not have.

**4. HDMI brightness needs `i2c-dev` and a rule of Nova's.** The Pi 5's screen
is HDMI only, so its brightness is the screen's own, over DDC/CI (`ddcutil`).
Nothing on Arch Linux ARM loads `i2c-dev`, and `ddcutil`'s udev rule gives the
seat's user only the buses of a PCI graphics card, which a Pi has none of.
`70-nova-hw-ddc.rules` tags the two HDMI lines by their devicetree names,
`107d508200.i2c` and `107d508280.i2c`.

**5. Some screens run their DDC brightness backwards.** The 1024x600 panel
sold for the Pi (EDID `HCH`, `HETECH`) is at its brightest at 0. Its maker and
model are in `ddc-reversed`, and `nova-brightness-display-ddc` reads them from
the screen's EDID in `/sys/class/drm` and flips Nova's numbers for it, so the
keys and the slider go the right way. Another such screen is one more line in
that file, as `ddcutil detect` prints it.

**6. The first start is the installer's questions, on the Pi itself.**
`/etc/machine-id` is `uninitialized` in the image, so systemd treats the first
start as a first boot (`ConditionFirstBoot`), and `nova-first-boot.service`
runs on tty1 before greetd, which `Requires=` it. It grows the root partition
to fill the drive, fills pacman's keyring, and asks the keyboard layout, the
computer's name and time zone, Wi-Fi when there is no cable, and the user, with
`installer/setup.bash`, the code `nova-install` asks with. Then it writes them,
installs the apps over the network, and remakes the initramfs with the chosen
keyboard. A step that fails, or a power cut, starts it over at the first
question (the machine ID is only committed once it succeeds), and its log is
`/var/log/nova-first-boot.log`.

**7. Wi-Fi channels follow the time zone.** The kernel allows only the
channels every country allows until it is told the country. The time zone's
country, from `zone.tab`, is set at once (`iw reg set`, for the network
question) and added to `/boot/cmdline.txt` as `cfg80211.ieee80211_regdom=`
for every later start.

**8. systemd needs `cgroup_enable=memory`.** The firmware's own kernel command
line switches off the memory controller; systemd-oomd and the per-app memory
limits need it, so the image's `cmdline.txt` asks for it. The rest of that line
is the quiet start a PC has (`data/boot/limine/10-nova.conf`).

**9. A Pi updates without a snapshot.** Its root is ext4. `nova update` moves
both `[nova]` and `[nova-alarm]` to the next release, and checks the boot
partition before asking for a restart; going back is `nova update --version
<tag> --allow-downgrade`.

**10. The kernel is `linux-rpi-16k`, the Pi 5's own.** Arch Linux ARM's
`linux-rpi` is built for the Pi 3 and 4 (`bcm2711_defconfig`) and starts on a
Pi 5, but without transparent huge pages, which the GPU driver uses for its
large pages (`v3d: Transparent Hugepage support is recommended for optimal
performance on this platform!` at every start). `linux-rpi-16k` is built from
`bcm2712_defconfig`, as Raspberry Pi OS's Pi 5 kernel is: huge pages, and 16K
memory pages, so fewer misses in the CPU's and the GPU's address caches. Both
install `/boot/kernel8.img`, so a Pi has one or the other.

**11. On a 4K screen the GPU is short of memory bandwidth, not shading.** The
GPU shares the memory with the CPU, and each layer drawn into a 3840x2160 frame
reads and writes 33 MB. Nova's windows are slightly see-through on a PC
(`0.985`); Hyprland draws nothing under an opaque window, but under a
see-through one the wallpaper and every window below it, each frame. The Pi's
profile makes every window opaque (`o.opaque_windows`, in
`data/hypr/windows.lua`). A frame that still misses the refresh would,
double-buffered, wait for the next one and halve the frame rate;
`render:new_render_scheduling` starts the next frame at once in a third buffer,
which needs the GPU's native fences (`EGL_ANDROID_native_fence_sync`, which
Mesa's V3D has). Hyprland renders on the GPU (`V3D 7.1`) and the display
controller reads its frames directly: `vc4` is the one display device, so
aquamarine never copies a frame between GPUs, and the display sits behind an
IOMMU, so 4K frames do not come from the 64 MB CMA pool.

**12. A Pi keeps no time while it is off.** Its clock runs from a battery few
Pis have, so each start begins at systemd's epoch, the newest of systemd's own
build date, `/usr/lib/clock-epoch` and `/var/lib/systemd/timesync/clock`
(systemd(1), "System clock epoch"), until timesyncd reaches a time server. At
the first start that is after the network question, and pacman's keyring is
filled before it: a clock behind the making of a key in it has gpg skip the
key (`new key but contains no user ID - skipped`), and pacman then refuses
every package that key signed. `tools/build-pi-image` stamps
`/usr/lib/clock-epoch` with the image's own time, which is later than any key
the image holds, and a keyring that still refuses one stops the setup and
says the time it saw.

**13. A first boot enables what the presets say.** At a first boot systemd
applies the unit presets to every unit, enabling those a preset names
(systemd(1), "enable-only" at a first boot); a PC never has one, as
`nova-install` writes its machine ID. Arch Linux ships systemd's own
`90-systemd.preset`, which would enable `systemd-networkd` and its
wait-online beside NetworkManager (the wait then fails at every start),
`systemd-homed`, sysext and the systemd-boot updater. `10-nova.preset` comes
first and enables nothing, so a Pi runs what `tools/build-pi-image` enabled.

**14. Dictation's engine is built for the Cortex-A76.** Arch Linux ARM has
neither whisper-cpp nor ggml, its tensor library, so the `[nova]` repository
carries a build of its own, with ggml linked in and the CPU its only backend.
It is built for the Pi 5's CPU, Armv8.2-A with the dot-product and
half-precision instructions, not for the machine CI builds it on, whose newer
instructions the Pi lacks. Parakeet runs on the four cores, slower than on a
laptop, and holds about 750 MB of memory while it transcribes.
