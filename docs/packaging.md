# Packaging

This page covers the packages Nova builds, why each is Nova's to build, and how each is kept up to date.

Every package Nova publishes has its PKGBUILD under `packaging/`.

- CI builds them (`.github/workflows/release.yml`) against the Arch Linux Archive snapshot a release pins.
- Nothing is built on a laptop, except to test a PKGBUILD.

| Package | Built from | Why Nova builds it |
|---|---|---|
| `nova` | this repository, `make install` | everything Nova is |
| `nova-keyring` | `packaging/nova-keyring` | the key the `[nova]` repository is signed with, small enough for the installer ISO |
| `linux-nova`, `linux-nova-headers` | Arch's `linux` packaging plus BORE | the kernel Nova boots on x86-64-v3 CPUs |
| `nvidia-open-nova` | Arch's `nvidia-open` packaging | NVIDIA's open modules prebuilt for `linux-nova`, so no DKMS on the laptop |
| `limine-entry-tool`, `limine-snapper-sync` | the AUR recipes, pinned | the boot-entry and snapshot-menu tools, which are AUR-only |
| `whisper-cpp` | `packaging/whisper-cpp`, its release tag | dictation's speech engine, with its own copy of ggml: Arch's links Arch's ggml, which breaks it as it moves on |
| `hyprland` | Arch's `hyprland` packaging, plus two patches | `xwayland:scale`: X11 apps the same size on every display, which Hyprland does not have yet; and release binds that fire when the modifier is let go first, which dictation's Super+D needs |

The kernels a system boots:

- `linux-nova` on a CPU with the x86-64-v3 instructions, with `nvidia-open-nova` for an NVIDIA card.
- Arch's own `linux` in its place on an older CPU, with `nvidia-open`.
- `linux-lts`, always, as the fallback entry, with `nvidia-open-lts` when there is an NVIDIA card.

## Building one locally

To check a PKGBUILD change, build in a container or a spare machine, never on a machine whose state matters:

```sh
cd packaging/<name> && makepkg --syncdeps --cleanbuild
```

- `nova` builds the committed `HEAD` of this checkout, not uncommitted changes.
- `NOVA_SOURCE='git+https://…#tag=v…'` builds a tag instead.
- CI's containers are prepared by `tools/ci-setup` and build through `tools/build-package`.

## linux-nova

The PKGBUILD is Arch's `linux` with these changes, and its header comment says which Arch packaging commit it follows:

- the BORE scheduler patch, pinned to a commit and a checksum;
- `nova-config.sh`, the complete list of config differences from Arch's `config.x86_64` (the BORE scheduler, `HZ_1000`, …). It runs `apply` before `make olddefconfig` and `check` after, so a Kconfig change that drops one of them fails the build;
- `KCFLAGS=-march=x86-64-v3`;
- the `pkgbase` `linux-nova`, and no documentation package.

### Updating the kernel

1. Take the new version's `PKGBUILD` and `config.x86_64` from Arch's packaging (`https://gitlab.archlinux.org/archlinux/packaging/packages/linux`) and carry over the changes above. Note the new packaging commit in the header.
2. Check that the pinned BORE patch still applies. BORE names its patches after the first kernel of a series (`linux7.2-rc1`), so a point release keeps the same patch, and a new series needs the matching one, pinned to a commit.
3. Update `b2sums` (`updpkgsums`) and build. `nova-config.sh check` fails the build if a delta did not survive.

A changed `packaging/linux-nova` means the next release rebuilds the kernel instead of reusing the cached one.

## nvidia-open-nova

**Its `pkgver` joins two versions**, NVIDIA's and the `linux-nova` build the modules are for: `615.78.08_7.2.11.arch1_1`.

- NVIDIA's must equal `extra/nvidia-utils` in the release's Arch snapshot, because userspace and modules have to match exactly.
- The release workflow writes both from the snapshot and the kernel it built, so a new driver in Arch, or a new kernel, needs nothing by hand.
- The committed value is only the last one released.

## limine-entry-tool and limine-snapper-sync

**Rebuilt from their AUR recipes, with the source pinned to a commit**, not a tag (tags can move).

- `limine-entry-tool` follows the AUR's `limine-mkinitcpio-hook`, the entry tool with its mkinitcpio half: `limine-update`, the pacman hook that rebuilds the UKIs and boot entries whenever a kernel changes, and the `sd-btrfs-overlayfs` initramfs hook a snapshot boots with.
- Their gradle builds download dependencies, so they need network access at build time.

To update: take the new AUR PKGBUILD, compare it with ours, pin the commit behind the new tag, and update the checksums.

## whisper-cpp

**Built from the release tag with the copy of ggml the tag carries**, the CPU its only backend, and no ffmpeg, as dictation records WAV.

- **Why Nova's own:** Arch's `extra/whisper-cpp` links Arch's own `ggml`, which is updated apart from it. ggml 0.29 (2026-11-08) stops whisper.cpp 1.9.5 as it loads the model, rebuilt or not, so the `[nova]` build is the one installed, `[nova]` being first in `pacman.conf`.
- **Every CPU generation:** Nova also runs on CPUs older than x86-64-v3, so ggml's CPU backend is built for every generation (`GGML_CPU_ALL_VARIANTS`) and the best the CPU has is loaded as it starts. Those are shared libraries, kept in `/usr/lib/whisper-cpp` and found there by `RUNPATH`, apart from Arch's ggml.

To update: bump `pkgver` to a newer tag, then the checksum (`makepkg -g`). Arch's version no longer matters.

## hyprland

**Arch's Hyprland with two patches.**

- **`xwayland-scale.patch`** adds the option `xwayland:scale`: X11 windows drawn at one scale on every display, 1:1 on a display of that scale and shrunk on one of a lower scale. `nova-hyprland-x11-scale` sets it to the largest display's scale, rounded up ([hardware](hardware.md#a-sharp-display)).
- **`release-bind.patch`** makes a release bind fire when its modifier is let go before its key. Without it, a dictation held on Super+D and ended by letting go of Super first keeps recording until the next press.

- **Why Nova's own:** one X server serves every display, so an X11 app draws at one scale, and Hyprland shows it at each display's own resolution: drawn for a 2x panel, it is twice its size on a 1x monitor. Both patches are offered to Hyprland (`packaging/hyprland/UPSTREAM.md`); once a Hyprland release has them, this package goes and Arch's comes back.
- **The PKGBUILD is Arch's**, at the packaging commit its header names, with the patches applied in `prepare()`, `hyprland` alone (Arch's `hyprpm` works with it), and no debug package.
- **Its pkgrel is Arch's, a dot, and Nova's revision of the patches:** `0.57.2-1.2`. pacman takes a package from the first repository that has it, and `[nova]` is first, so it is the one installed. Newer than Arch's build of the same pkgrel (`vercmp 0.57.2-1.2 0.57.2-1` is 1), it replaces Arch's on a system that had it as an ordinary update; going back to a release without it, `nova update`'s downgrade (`-Suu`) puts Arch's back.
- **The release workflow** writes Arch's pkgrel from the snapshot (Arch raises it when a library Hyprland links changes its soname, and the build must link the snapshot's), and builds it once per snapshot, 45 CPU-minutes, some 15 to 20 on a hosted runner, beside the other builds. It builds it only while the snapshot's Hyprland is the `pkgver` here: a newer Hyprland in Arch is released as Arch's, unpatched, with a warning on the run, and X11 apps go back to the rule for Arch's Hyprland until the patches are moved onto it.

To move the patches onto a new Hyprland:

1. Take Arch's new `PKGBUILD` (`https://gitlab.archlinux.org/archlinux/packaging/packages/hyprland`) and carry over the three changes above; note its packaging commit in the header. Set `pkgrel=1.1`: the `1` is replaced by Arch's in CI.
2. Unpack the new release's source tarball twice, apply the patches to one copy in the PKGBUILD's order (`patch -Np1 -d hyprland-source -i …/xwayland-scale.patch`, then `release-bind.patch`), and fix what does not apply. `release-bind.patch` changes `shadowBinds()` and its two release-path callers (`src/keybinds/Manager.{cpp,hpp}`), and adds a test to hyprtester's `keybinds.cpp`. For `xwayland-scale.patch`, the places it changes are those that read `xwayland:force_zero_scaling`, plus the option's definition (`ConfigValues.cpp`), its refresh (`PropRefresher`) and `MonitorPositionController`'s test. A place the new Hyprland reads `force_zero_scaling` that the patch does not know must ask `xwaylandScale()` too: `grep -rn force_zero_scaling src`.
3. Write each patch again from the two copies: the description at its top, then `diff -u` of each changed file, named `a/…` and `b/…`. Update `sha256sums` (`updpkgsums`).
4. Build it, with `-DWITH_TESTS=ON` once to run `hyprland_gtests` and hyprtester's `keybinds.cpp` tests. Check X11 apps on two displays of different scales in a nested Hyprland: their size on each, the pointer, and menus. Check Super+D on release with Super let go first.

A new patch on the same Hyprland raises Nova's revision instead (`1.2`).

## nova-keyring

Holds `nova.gpg`, `nova-trusted` and `nova-revoked`, written by `tools/keyring-export`. Its `pkgver` is the date the key set last changed.

Making and replacing the key is in [releasing.md](releasing.md#the-signing-key-once).
