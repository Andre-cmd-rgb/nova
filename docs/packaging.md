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
| `supernova` | `packaging/supernova`, a pinned commit of [Supernova](https://github.com/Andre-cmd-rgb/supernova) | Nova's own browser; in no Arch repository |
| `cmatrix` | Arch's `cmatrix` packaging, from upstream's current commit | 2.0, the last release, fills a resized window with solid blocks; upstream fixed that in 2020 and has made no release since |
| `hyprland` | Arch's `hyprland` packaging, plus four patches | `xwayland:scale`: X11 apps the same size on every display, which Hyprland does not have yet; X11 games fullscreen at the resolution they set, with a mouse that turns their view; and release binds that fire when the modifier is let go first, which dictation's Super+D needs |

The kernels a system boots:

- `linux-nova` on a CPU with the x86-64-v3 instructions, with `nvidia-open-nova` for an NVIDIA card.
- Arch's own `linux` in its place on an older CPU, with `nvidia-open`.
- `linux-lts`, always, as the fallback entry, with `nvidia-open-lts` when there is an NVIDIA card.

## What `nova` depends on

- Each of `nova`'s dependencies in `packaging/nova/PKGBUILD` says, in a comment, what of Nova's needs it, unless its name says so.
- A package Nova stops needing goes into `src/cli/retired`, with what took its place: `nova update` removes it where Nova alone wanted it (installed as a dependency, needed by nothing else), never one installed by name. udiskie went that way when `nova-sessiond` took over mounting drives.
- Nova's Rust uses libsystemd (D-Bus, the journal) through `nova-sd`, linked as `libsystemd.so.0`: `systemd` is a dependency already.
- `check()` runs `cargo test` and `make test`. `nova-sessiond`'s tests start a private `dbus-daemon` and write journal files with `systemd-journal-remote`; both come with `dbus` and `systemd`, which every Arch build root has.

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

## cmatrix

**Arch's recipe, built from upstream's current commit** (`5c082c6`, 2023-12-09, 56 commits after 2.0), with nothing of Nova's in it.

- **Why Nova's own:** 2.0 never sets a cell's head-of-stream flag. After a resize, the grid is allocated again, and cells the old memory leaves marked as heads draw `addch(-1)`: a character with every attribute on, reverse video among them. A resized window fills with solid blocks, in any terminal, see-through or not.
- Upstream fixed that in December 2020 (`7ab2d95` and `6d62080`, issue #98), and has since made the terminal's own background show through (`use_default_colors`). It has made no release since 2019, so Arch's package still has the bug.
- **Its files are Arch's:** upstream's build drops console fonts into `/usr/share/consolefonts` when the builder has that folder; the recipe puts them where Arch's package does instead.

To retire: once Arch ships a cmatrix with those commits, delete `packaging/cmatrix` and its line in `release.yml`.

## whisper-cpp

**Built from the release tag with the copy of ggml the tag carries**, the CPU its only backend, and no ffmpeg, as dictation records WAV.

- **Why Nova's own:** Arch's `extra/whisper-cpp` links Arch's own `ggml`, which is updated apart from it. ggml 0.29 (2026-11-08) stops whisper.cpp 1.9.5 as it loads the model, rebuilt or not, so the `[nova]` build is the one installed, `[nova]` being first in `pacman.conf`.
- **Every CPU generation:** Nova also runs on CPUs older than x86-64-v3, so ggml's CPU backend is built for every generation (`GGML_CPU_ALL_VARIANTS`) and the best the CPU has is loaded as it starts. Those are shared libraries, kept in `/usr/lib/whisper-cpp` and found there by `RUNPATH`, apart from Arch's ggml.

To update: bump `pkgver` to a newer tag, then the checksum (`makepkg -g`). Arch's version no longer matters.

## supernova

**Supernova's own PKGBUILD (`packaging/arch/PKGBUILD` in its repository), built from the Supernova commit `_commit` pins.**

- **What it is:** Nova's browser, on the castlabs Electron for Content Security that Supernova's `electron.lock` pins (Chromium plus Google's licensed Widevine, so Netflix and Spotify play). `prepare()` stops the build if the PKGBUILD's castlabs version, URL or checksum differ from that `electron.lock`.
- **The default browser, not a dependency:** `nova` does not depend on it; the installer installs it unless Firefox is asked for (Chrome, built online from its AUR recipe, comes beside it), from the stick's offline repository too (`every_package` in `installer/install-machine.bash`), and the skel's `mimeapps.list` names it. It is not in the App Center's catalog.
- **Two changes from Supernova's copy:** the source is the pinned commit of the published repository instead of a local checkout, and `check()`, which runs Supernova's unit tests and starts the browser headless (`tools/smoke.sh`), runs it without Chromium's sandbox where user namespaces are forbidden, as in CI's Docker containers. The job's container has a 1 GB `/dev/shm`, since Docker's 64 MB is too little for Chromium.
- **No setuid helper:** `chrome-sandbox` is not shipped; Chromium's sandbox runs on user namespaces, which Arch's kernels allow.

To update: set `_commit` to a newer commit of Supernova's `main`, carry over any change to its `packaging/arch/PKGBUILD`, and build.

## hyprland

**Arch's Hyprland with four patches.**

- **`xwayland-scale.patch`** adds the option `xwayland:scale`: X11 windows drawn at one scale on every display, 1:1 on a display of that scale and shrunk on one of a lower scale. `nova-hyprland-x11-scale` sets it to the largest display's scale, rounded up ([hardware](hardware.md#a-sharp-display)).
- **`release-bind.patch`** makes a release bind fire when its modifier is let go before its key. Without it, a dictation held on Super+D and ended by letting go of Super first keeps recording until the next press.
- **`xwayland-emulated-modes.patch`** fullscreens an X11 game at the resolution it set through RandR, its exclusive fullscreen mode. XWayland gives a game no real mode: it tells the game the display has the mode, scales a window of that size up to the display, and names the mode in the window's `_XWAYLAND_RANDR_EMU_MONITOR_RECTS` for the window manager to size it by, as GNOME and KDE do. Hyprland did not read it and gave the window the whole display, so the game drew every pixel of it whatever its setting: Minecraft at 1280x720 drew 4800x3000 on the ThinkPad P1's panel (`xwayland:scale` 2), 15.6 times the pixels, each one rendered, copied from the NVIDIA card to the Intel one and shrunk. Measured in a nested Hyprland at the P1's panel and scale on the Intel GPU, an SDL3 game drawing a flat picture made 14 to 18 times the frames with it. A game's in-game mouse is then as fast as at that resolution: XWayland scales the mouse's motion by the mode, as it does on GNOME and KDE.
- **`xwayland-relative-motion.patch`** keeps an X11 game's mouse turning its view. XWayland posts a pointer motion that comes without a relative one (a window placed under the pointer, a warp) on an absolute device of its own, and the X server then switches its core pointer to that device's axes. SDL before 3.4.16 reads those axes once, at the first raw motion: a game whose window opened under a still pointer then takes each motion of the mouse for a position, and its view twitches and comes back. Minecraft 26.3 ships SDL 3.4.14 and would not turn. Hyprland now sends XWayland a zero relative motion with each such motion, so every motion stays on XWayland's relative device. With Minecraft's SDL, a windowed game's grab got -2390 pixels for 300 of mouse motion before, and 300 with it.

- **Why Nova's own:** one X server serves every display, so an X11 app draws at one scale, and Hyprland shows it at each display's own resolution: drawn for a 2x panel, it is twice its size on a 1x monitor. All four are offered to Hyprland (`packaging/hyprland/UPSTREAM.md`); once a Hyprland release has them, this package goes and Arch's comes back.
- **The PKGBUILD is Arch's**, at the packaging commit its header names, with the patches applied in `prepare()`, `hyprland` alone (Arch's `hyprpm` works with it), and no debug package.
- **Its pkgrel is Arch's, a dot, and Nova's revision of the patches:** `0.57.2-1.3`. pacman takes a package from the first repository that has it, and `[nova]` is first, so it is the one installed. Newer than Arch's build of the same pkgrel (`vercmp 0.57.2-1.3 0.57.2-1` is 1), it replaces Arch's on a system that had it as an ordinary update; going back to a release without it, `nova update`'s downgrade (`-Suu`) puts Arch's back.
- **The release workflow** writes Arch's pkgrel from the snapshot (Arch raises it when a library Hyprland links changes its soname, and the build must link the snapshot's), and builds it once per snapshot, 45 CPU-minutes, some 15 to 20 on a hosted runner, beside the other builds. It builds it only while the snapshot's Hyprland is the `pkgver` here: a newer Hyprland in Arch is released as Arch's, unpatched, with a warning on the run, and X11 apps go back to the rule for Arch's Hyprland until the patches are moved onto it.

To move the patches onto a new Hyprland:

1. Take Arch's new `PKGBUILD` (`https://gitlab.archlinux.org/archlinux/packaging/packages/hyprland`) and carry over the three changes above; note its packaging commit in the header. Set `pkgrel=1.1`: the `1` is replaced by Arch's in CI.
2. Unpack the new release's source tarball twice, apply the patches to one copy in the PKGBUILD's order (`patch -Np1 -d hyprland-source -i …/xwayland-scale.patch`, then `release-bind.patch`, `xwayland-emulated-modes.patch` and `xwayland-relative-motion.patch`), and fix what does not apply. `xwayland-emulated-modes.patch` reads the property in the XWM (`src/xwayland/XWM.cpp`, the atom in `XWayland.hpp`, the modes in `XSurface.hpp`), sizes the window in `CX11Backend::configure()`, and adds `tests/desktop/view/X11EmulatedMode.cpp`. `xwayland-relative-motion.patch` sends the zero relative motion in `CSeatManager::sendPointerMotion()` (`src/managers/SeatManager.cpp`), and knows whether the frame had one in `src/protocols/RelativePointer.{cpp,hpp}`. `release-bind.patch` changes `shadowBinds()` and its two release-path callers (`src/keybinds/Manager.{cpp,hpp}`), and adds a test to hyprtester's `keybinds.cpp`. For `xwayland-scale.patch`, the places it changes are those that read `xwayland:force_zero_scaling`, plus the option's definition (`ConfigValues.cpp`), its refresh (`PropRefresher`) and `MonitorPositionController`'s test. A place the new Hyprland reads `force_zero_scaling` that the patch does not know must ask `xwaylandScale()` too: `grep -rn force_zero_scaling src`.
3. Write each patch again from the two copies: the description at its top, then `diff -u` of each changed file, named `a/…` and `b/…`. Update `sha256sums` (`updpkgsums`).
4. Build it, with `-DWITH_TESTS=ON` once to run `hyprland_gtests` and hyprtester's `keybinds.cpp` tests. Check X11 apps on two displays of different scales in a nested Hyprland: their size on each, the pointer, and menus. Run `tools/xwayland-game-check --hyprland <the new build>`: an X11 game's fullscreen modes, and its mouse in the game and in menus. Check Super+D on release with Super let go first.

A new patch on the same Hyprland raises Nova's revision instead (`1.3`).

## nova-keyring

Holds `nova.gpg`, `nova-trusted` and `nova-revoked`, written by `tools/keyring-export`. Its `pkgver` is the date the key set last changed.

Making and replacing the key is in [releasing.md](releasing.md#the-signing-key-once).
