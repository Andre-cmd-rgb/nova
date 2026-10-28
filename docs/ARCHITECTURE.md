# Nova architecture

Nova is a small Arch Linux desktop: Hyprland, a Quickshell shell, one `nova` command,
and a power governor. It ships as **one package, `nova`**, installed into a plain Arch
system. This document is the contract every component follows; read it before adding
code.

## Components and where they install

| Source | Installs to | What it is |
|---|---|---|
| `src/shell/` | `/usr/share/nova/shell/` | The Quickshell shell: bar, lock, menu, notifications, OSD, panels, Settings |
| `src/cli/nova` | `/usr/bin/nova` | Dispatcher: `nova <group> <verb> [args]` |
| `src/cli/bin/` | `/usr/lib/nova/bin/nova-<group>-<verb>` | Helper commands (bash), one per file |
| `src/power/` | `/usr/lib/nova/bin/nova-power`, `/usr/lib/nova/nova-powerd`, `nova-undervolt`, system units, udev rules, sleep hooks | Nova's power governor: the policy (bash) and the governor (Rust), tuned for and so far started only on the ThinkPad P1 Gen 4i; the CPU undervolt (Rust), for any Intel laptop whose firmware allows one |
| `src/theme/` | `/usr/lib/nova/bin/nova-theme` | Theme engine (Rust): palettes, templates, theme and background switching, pickers |
| `theme/` | `/usr/share/nova/{themes,templates,wordmark}/` | Palettes, the per-app templates, the wordmark background template |
| `data/hypr/` | `/usr/share/nova/default/hypr/` | Hyprland defaults (Lua), loaded by the user's `~/.config/hypr/hyprland.lua` |
| `data/session/` | `/usr/lib/systemd/user/`, `/etc/pam.d/`, `/etc/sudoers.d/`, `/usr/share/uwsm/env.d/`, `/usr/share/nova/{session,greeter}/` | greetd (a config template the installer renders), the greeter, PAM, uwsm env, session guard, keyring |
| `data/boot/` | `/etc/mkinitcpio.conf.d/`, `/etc/limine-entry-tool.d/`, `/usr/share/snapper/config-templates/`, pacman hooks | Boot chain drop-ins and the boot-entry guards (x86 only) |
| `data/raspberry-pi/` | `/usr/lib/nova/bin/`, `/etc/mkinitcpio.conf.d/`, pacman hooks, `nova-first-boot.service`; `image/` only into the image | The Raspberry Pi 5's own pieces (aarch64 only): the boot partition's guard, its initramfs, the first-boot setup, and what `tools/build-pi-image` puts in its image |
| `data/systemd/` | `/usr/lib/systemd/user/`, `/usr/lib/systemd/{logind,sleep}.conf.d/` | Session user units; logind and sleep policy |
| `data/audio/` | `/usr/share/nova/default/audio/` | Speaker tunings, matched to the machine by `nova-audio-tuning` |
| `data/battery/` | `/usr/lib/nova/bin/`, `/usr/lib/nova/`, a udev rule, a system unit, a polkit action, a UPower drop-in | The charge limit, and what UPower does at the battery's end |
| `data/browser/` | `/usr/lib/nova/`, Chrome's and Chromium's managed policies, a system path unit | Chrome's toolbar in the theme's color |
| `data/defaults/` | `/usr/share/nova/default/` | The defaults the shell reads (`shell.json`, `menu.jsonc`, the launcher's hidden entries), which `~/.config/nova` overrides |
| `data/skel/` | `/usr/share/nova/skel/` | A new account's starting files (`useradd -k`) |
| `data/caffeine/`, `data/screensaver/` | `/usr/lib/nova/bin/`, `/usr/lib/nova/`, `/usr/share/nova/screensaver/`, a polkit action | Caffeine (the screen stays on, a closed lid only darkens it) and the screensaver |
| `data/hardware/` | `/usr/share/nova/hardware/`, `/usr/share/uwsm/env.d/`, `/etc` via `nova-hw-apply` | Per-model **data**: the DMI model list, drop-ins, packages, the session environment |
| `installer/` | ISO only, except `nova-usb` in `/usr/lib/nova/bin/`, and on a Pi `setup.bash` | archiso profile, installer, USB creator; `setup.bash`, the questions and the account every Nova setup shares |
| `packaging/` | – | PKGBUILDs: `nova`, `linux-nova`, `nvidia-open-nova`, AUR rebuilds |

Every component has an `install.mk` that the top-level `Makefile` includes, and
`make DESTDIR=… install` is the only way files reach a system. The `nova` PKGBUILD calls
exactly that, so pacman owns every file. `NOVA_ARCH` (makepkg's `CARCH`) picks the
architecture's components: x86_64 gets the boot chain, aarch64 the Raspberry Pi's.

## Names, paths, environment

- **Command:** `nova`. Helpers are `nova-<group>-<verb>` in `/usr/lib/nova/bin`, which
  the session puts on `PATH`. `nova <group> <verb>` runs `nova-<group>-<verb>` when it
  exists, else `nova-<group>` with the verb as its first argument, so
  `nova theme set white` runs `nova-theme set white`.
- **Help:** each helper declares one-line metadata in its header comments, which
  `nova help` reads:
  ```bash
  # nova:summary=Apply a theme
  # nova:args=<theme>
  ```
  Helpers marked `# nova:hidden=true` are internal.
- **Environment:** `NOVA_PATH=/usr/share/nova`. Code must never hard-code
  `/usr/share/nova` where `$NOVA_PATH` is available. That way tests can point it at
  the source tree.
- **Locations:**

  | Kind | Location |
  |---|---|
  | User config | `~/.config/nova/` (`shell.json`, `menu.jsonc`, `themes/`, `templates/`, `backgrounds/`, `hooks/`); a plugin's own settings in `~/.config/nova-<plugin>/` (`nova-batterylife`, `nova-screentime`, `nova-mobile-data`) |
  | User state | `~/.local/state/nova/` (`current/`, `rendered/`, `backgrounds/`, `power-profile/`, `aur/`, `monitors.json`: the displays as Settings keeps them); a plugin's history in `~/.local/state/nova-<plugin>/` |
  | User data | `~/.local/share/nova-dictation/` (the speech model, downloaded at dictation's first use) |
  | System config | `/etc/nova/power.conf` on a P1 Gen 4i (optional tunables); `/etc` drop-ins from the hardware profile, listed in `/var/lib/nova/hardware-files` |
  | System state | `/var/lib/nova/` (`greeter/`, the theme mirror owned by the user the installer created; `hardware-files`) |
  | Runtime | `$XDG_RUNTIME_DIR/nova/` (`unlocked-once`, locks, sockets, `dictation/`'s recordings until they are read, a display change not kept yet) |

- **Identifiers:** shell plugin ids are `nova.<name>`; every plugin ships in the
  `nova` package and the shell loads no other (`plugins/index.json`, written at
  build time by `tools/plugin-index`, lists them). Layer-shell namespaces are
  `nova-<name>`. PAM services are `nova-lock-password`, `nova-lock-fingerprint`,
  `nova-greeter` and `nova-sudo`. User units are `nova-*.service`. polkit actions are
  `org.nova.*`.
- **The project Nova derives from is named in `NOTICE` only**, as its license
  asks. `make check-names` (run in CI) fails on the name anywhere else.

## Session flow (boot to desktop)

1. Limine boots the UKI. The config has `quiet: yes` and `timeout: 1`, so a key press
   shows the menu with snapshots. `nova recovery` reboots straight into that menu.
2. systemd initramfs, no plymouth. The firmware logo stays until Hyprland's first frame.
3. greetd `initial_session` runs `uwsm start hyprland` as the installed user, once per
   boot, with `NOVA_LOGIN=autologin`. Every command greetd runs sets `NOVA_LOGIN`;
   only the greeter's `password` means somebody authenticated. Anything else, or
   nothing, is treated as autologin, so the session fails closed.
4. Hyprland starts in the `nova-boot` submap, which has no binds.
5. The shell locks before it draws anything else.
6. `nova-session-guard` (a user unit every user has enabled) waits up to 15 s for
   `nova-shell lock state` to say `secure`. If it doesn't, the guard terminates the
   session, and greetd shows the greeter: `src/shell/greeter.qml` on a minimal
   Hyprland, or `agreety` on the console if that never shows. Nothing ever shows an
   unlocked desktop that nobody authenticated.
7. **First unlock after boot needs the password.**
   - `nova-lock-password` ends with `pam_gnome_keyring`, which unlocks the login
     keyring with the password during auth. The password never leaves PAM.
   - `nova-session-first-unlock` writes `$XDG_RUNTIME_DIR/nova/unlocked-once` and
     starts `nova-unlocked.target`, which brings up keyring users such as the
     migration of a passwordless keyring (`nova doctor` offers it).
   - A greeter login does the same through the guard: the greeter's PAM stack has
     already unlocked the keyring.
   - Fingerprint unlock is offered only once `unlocked-once` exists.
   - polkit's prompts and sudo take a finger from the start: neither needs the
     password for the keyring. Nova's `/etc/pam.d/polkit-1` shadows polkit's own,
     and `/etc/sudoers.d/20-nova-pam` points sudo at `nova-sudo`; both put
     `pam_fprintd` ahead of the stack they wrap, and skip it while the lid is shut.
8. **Removable drives mount only in an unlocked session.** Mounting one has the
   kernel read its file system, so a drive plugged into a locked computer waits.
   The lock service runs `nova-automount on` after the first unlock and `off`
   whenever it locks: udiskie (`nova-automount.service`) is started, then frozen
   and thawed, not restarted, since a fresh udiskie mounts every drive there is.

### On a Raspberry Pi 5

The firmware starts `kernel8.img` (Arch Linux ARM's `linux-rpi-16k`) and its
initramfs straight from the FAT partition at `/boot`; there is no boot menu,
and no snapshots. `nova-boot-check` refuses a kernel update while that
partition is not mounted, and says when it does not hold the installed kernel.
From there it is the same flow, from step 3.

The first start from Nova's image has no account yet: `nova-first-boot.service`,
which greetd's drop-in requires, asks on the first console what `nova-install`
asks on a PC (`installer/setup.bash`), then gives the greeter an account to
start. It runs only while `ConditionFirstBoot` holds, so a setup cut short is
asked again at the next start, and never once one has finished. Why each
piece is as it is: [hardware/raspberry-pi-5.md](hardware/raspberry-pi-5.md).

## Theme flow

A theme is a directory with a `colors.toml` palette (flat `key = "value"` lines), plus any
files it ships ready-made: a `shell.toml`, `shell.<section>.toml` overrides, an
`icons.theme` (the icon set it was made with, used when that set is installed, Adwaita
otherwise), or a per-app file that replaces a template. Nova's themes live in
`/usr/share/nova/themes/`; a theme of the same name in `~/.config/nova/themes/` overrides
it file by file.

`nova theme set <name>` (`nova-theme`, under 5 ms of its own work):
1. **Render** into a fresh `~/.local/state/nova/rendered/<name>.<stamp>/`:
   - the theme's files, Nova's copy first and then the user's;
   - every template (`~/.config/nova/templates/*.tpl`, then Nova's) rendered with the
     palette, unless the theme already ships that file;
   - the wordmark background `backgrounds/nova.svg`.
2. **Swap atomically:** `current/theme` is a symlink, replaced by one rename. Readers
   see the old theme or the new one, never a mix.
3. **Pick the background:** the one last chosen for this theme, else the latest shared
   photo chosen, else the wordmark.
4. **Tell the shell:** a `themeTransition` IPC fades to the new background and recolors
   the shell in one step.
5. **Apply** (`nova-theme-apply`, in parallel): `hyprctl reload`, GTK3/GTK4 `gtk.css` and
   color-scheme (Qt follows GTK), foot (new windows read `theme.ini`, open ones get OSC
   escapes), btop, VS Code, Claude Code, T3 Code, and the greeter mirror in
   `/var/lib/nova/greeter/`, from which a root path unit sets Chrome's color policy.

Palette values may contain only hex, `rgb()`, words, numbers and a few separators, so a
`colors.toml` can't inject code into the Lua, CSS or JSON it is rendered into. The files a
theme ships ready-made are used as they are, and some are code: Hyprland runs
`hyprland.lua`, and a `foot.ini` can set the terminal's shell. A downloaded theme with
more than a palette is a program, to install only from someone you trust. Theming
never needs root and never rebuilds an initramfs. Nothing before the lock screen is
themed.

**Backgrounds** (`nova theme bg pick|next|set`): a theme offers its own backgrounds,
`~/.config/nova/backgrounds/<theme>/`, and the shared `~/.config/nova/backgrounds/`.
Each theme remembers its pick in `~/.local/state/nova/backgrounds/by-theme/`. A pick from
the shared folder also becomes the default for themes that have no pick of their own.

## Power and hardware

- **One power system, `nova power`**, with its controls in Settings →
  Performance (the power mode, what the governor is doing right now, the
  discrete GPU and the undervolt) and Settings → Battery (the charge limit, the
  lid and the power button). Its manual is [power.md](power.md).
- **Power profiles** belong to power-profiles-daemon. `nova-power-profile` sets one
  and remembers it for the current power source; the shell's battery service runs
  `nova-power-profile restore` at login and on every plug and unplug, which puts back
  the remembered choice (performance on AC and power-saver on battery by default).
  The governor never sets one.
- **The governor** is two halves: `nova-power`, the policy, run on each plug and
  unplug, at boot and after resume (the dGPU off the PCI bus on battery, CPU and
  platform tunables, Wi-Fi power save, the hibernate rescan), and `nova-powerd`,
  which runs throughout and owns PL1, PL2, the frequency ceiling, the iGPU ceiling
  and the fans. Its tiers and limits are measured on the ThinkPad P1 Gen 4i, so
  today it starts only there: each unit has a DMI `ConditionFirmware=`, and the udev
  rule and sleep hook check the model themselves. The facts behind every choice are
  in [hardware/thinkpad-p1-gen4i.md](hardware/thinkpad-p1-gen4i.md).
- **When the discrete GPU is on** is the user's choice on a P1 Gen 4i:
  Settings → Performance offers *On When Plugged In* or *Always Off* (`nova power
  gpu mode`, which `nova power gpu-mode` applies at once; a polkit action
  lets the active session set it without a password). Other machines leave an
  idle NVIDIA card to the driver's runtime power management, and Settings
  shows no choice.
- **Undervolt** (`nova power undervolt set -70`, or `set -80 -70` for the core's
  and the cache's each): an offset on an Intel CPU's core and cache, through
  the overclocking mailbox, where the firmware lets one through (a P1 Gen 4i's
  only with its hidden Overclocking Lock off, fact 16). Nova sets none by
  itself: the depth is each CPU's own. `nova-undervolt`
  applies it at boot (`nova-undervolt.service`) and after every sleep, and
  reads it back. Before writing it records the boot it is on in, on disk; a
  clean shutdown takes it off and clears the record. So a boot that finds an
  earlier boot's record holds the offset instead of applying it, and so does
  the first machine check the kernel logs. Setting it takes an
  administrator's password, through polkit. On some of these CPUs the core
  and the cache share one voltage, at the higher of what each asks for (on
  the P1 Gen 4i the core's is its own), so `nova power undervolt compare`
  reads the core's own voltage
  (IA32_PERF_STATUS) under load with each of two offsets, to show whether a
  core deeper than its cache moves it at all.
- **Other laptops** get power-profiles-daemon, the charge limit and the
  undervolt for now. The governor starts on another model once its tiers are
  measured there and match the P1's results on the watt meter.
- **Charge limits** are reported as a capability: `threshold` (numeric, ThinkPad),
  `toggle` (Legion `Long_Life`), or `none`. Every write is read back, and only a
  verified value counts as success.
- **Sleep:** the lid, the suspend key and the menu's Suspend all `sleep`, which logind
  turns into suspend-then-hibernate (hibernating after 2 h, and never on AC) or plain
  suspend on a machine that cannot hibernate. Settings → Battery chooses three
  things over that, each through a `nova power` command: what a closed lid does
  plugged in (`lid`: sleep, or lock and keep running with the panel dark), what
  the power button does (`button`: the system menu, sleep or shut down; the
  session's, so no root), and the 2 h (`hibernate`: 1 to 24 hours, or never).
  The first and last are drop-ins in `/etc/systemd/{logind,sleep}.conf.d/`,
  written by `nova-power-sleep-apply` through polkit. At UPower's last 2% the computer
  hibernates outright (`/etc/UPower/UPower.conf.d/10-nova.conf`): sleeping to
  RAM first is what would empty it. The TPM key-provisioning units are
  skipped unless `nova.tpm2` is on the kernel command line: an encrypted Nova
  disk opens with its passphrase, never the TPM, and they cost about four
  seconds of every measured boot.
- **Unused:** the shell's idle service (`src/shell/plugins/services/idle`) starts
  the screensaver after `idle.screensaver` seconds (three minutes by default)
  and locks after `idle.lock` (five), both in `shell.json` and in Settings →
  Lock Screen. The screensaver (`nova-screensaver`) opens a foot window on each
  display, where `nova-screensaver-run` plays the wordmark through ttfx until
  a key, the mouse, the window losing focus or the lock ends it.
- **Caffeine** (`nova caffeine`, the bar's coffee cup, Super+Ctrl+I) is one
  switch, `$XDG_RUNTIME_DIR/nova/caffeine`, so it never outlives the session.
  While it is there the idle service does nothing; on a laptop it also holds a
  logind `handle-lid-switch` inhibitor, and the Hyprland lid binding goes
  through `nova caffeine close`, which turns the panel off with DPMS instead of
  locking. The P1's 5G modem, while its radio is on, is kept out of runtime
  suspend meanwhile, as root through `nova-caffeine-modem` (polkit). On battery
  it ends at 10%, from the idle service, and a lid closed meanwhile then locks
  and sleeps.
- **Hardware profiles** live in `data/hardware/`. `models` maps a DMI
  `product_version` pattern to a profile; `nova-hw-detect` and the Hyprland loader
  both read it. A profile holds:
  - `packages`: Arch packages the installer adds (microcode, firmware, drivers)
  - `etc/`: modprobe, NetworkManager and boot-entry drop-ins, which cannot apply to
    one model from `/usr`. `nova-hw-apply` copies them into `/etc` from a pacman hook
    on every install and upgrade of `nova`, and removes the ones a release dropped.

  Session-side settings check the model themselves: a uwsm `env.d` file and a
  `default/hypr/hardware/<profile>.lua` module. A speaker tuning
  (`data/audio/tunings/<name>/`, matched by DMI) needs the audio server, so it is
  turned on at login: `nova-speaker-tuning-auto.service` runs `nova audio tuning
  auto`, which applies it the first time, keeps it current after updates, and
  leaves it off once someone has turned it off.

## Packaging and releases

- **Packages**, built only in CI:

  | Package | Contents |
  |---|---|
  | `nova` | everything in this repo |
  | `nova-keyring` | the key the `[nova]` repository is signed with |
  | `linux-nova`, `linux-nova-headers` | Arch's kernel configuration with the BORE scheduler, `HZ_1000` and the x86-64-v3 instruction-set baseline |
  | `nvidia-open-nova` | NVIDIA modules prebuilt for `linux-nova` |
  | `limine-snapper-sync`, `limine-entry-tool` | rebuilt from the AUR |
  | `ttfx` | the screensaver's text effects ([omacom/ttfx](https://github.com/omacom/ttfx)), built from its release tag; Arch does not package it |
  | `mise` | the developer tools' version manager, the project's own arm64 build: Arch Linux ARM does not package it (aarch64 only) |

  `nova`, `nova-keyring`, `ttfx` and `mise` are built for aarch64 too, in Arch
  Linux ARM, for the Raspberry Pi 5.

- **Fallback kernel:** Arch's `linux-lts` + `nvidia-open-lts` stay installed as the
  fallback boot entry.
- **A release** (`v1.0.0-beta.1`, …) is a GitHub release with:
  - the installer ISO (`installer/iso`, built by `tools/build-iso`), which
    installs over the network, and its `.sha256`;
  - `nova-usb`, for making the stick (below);
  - the Raspberry Pi 5 image (`tools/build-pi-image`), and its `.sha256`;
  - `release.toml`, which pins the Arch Linux Archive date the release was tested
    against, the Arch Linux ARM set its Pi build pins, and says where its
    packages are.

  The rest is in the release's folder of the `nova-packages` bucket on
  Cloudflare R2 (`https://nova-packages.piserver.stream/<tag>`): the signed
  `[nova]` repository, `packages.txt` for the stick, and a `.sig` by the
  repository key for each file read without pacman (`release.toml`, the ISO's
  `.sha256`, `packages.txt`, `nova-usb`), which `nova update` and `nova-usb`
  check against the key alone. See [releasing.md](releasing.md).
- **The Raspberry Pi's packages.** Arch Linux ARM keeps no archive, so a
  release pins its own: `tools/alarm-pin` takes every package the image and
  `nova apps install` need from Arch Linux ARM's databases, at the versions
  the release was built with, into `nova-alarm.db`, signed by Nova and each
  entry still signed by its Arch Linux ARM packager. The list is in the
  release's `aarch64/` folder with its `[nova]` repository; the files are in
  a pool every release shares (`alarm/aarch64/`), each uploaded once. A Pi's
  pacman reads `[nova]`, then `[nova-alarm]`, then Arch Linux ARM's own
  repositories, and takes a package from the first that has it, so what the
  release pinned stays put and anything else installed comes from Arch Linux
  ARM as it is that day.
- **The stick:** `nova usb` (`installer/nova-usb`, also on every release page, so
  it runs on any Arch-based system) writes a GPT stick of its own instead of the
  raw ISO:
  - partition 1, `NOVA`: a FAT EFI partition holding the ISO's files, which
    archiso boots from as they are (it finds itself by a `/boot/<uuid>.uuid`
    file, not by the disk). With packages on the stick, `nova/repo/` holds
    every package any install can need (`packages.txt`, from
    `nova-install --list-packages`) and their signatures, as the
    `[nova-offline]` repository;
  - partition 2, `NOVA-DATA`, only when something is carried (the SSH keys,
    and the files and folders picked from the home): LUKS2, btrfs, and
    `carry/` with one `tar.zst` per item, `SHA256SUMS` and `manifest.json`.
    `nova-install --unlock` opens it before the questions; the install puts
    each item back into the new home once the account exists.

  `nova usb` and the stick's installer ask one question per screen, with gum,
  under the wordmark: `installer/ui.bash` holds the prompts both use, and the
  glyphs stay within the Linux console's font. The released `nova-usb` is one
  file, so `tools/inline-ui` writes `ui.bash` and the wordmark into it. A
  stick's boot menu also has memtest86+.

  Everything that writes a disk runs in one root step (`nova-usb write`), which
  checks the device again before touching it; `tests/usb/stick-test` runs it
  against a loop device in CI.

  [releasing.md](releasing.md) has the two-week cycle and the signing key;
  [packaging.md](packaging.md) has how each package is kept up to date.
- **Every release is installed before it is published:** `tests/install/run`
  makes a stick from the ISO as `nova usb` would, installs with no questions
  (`nova-install --answers`) onto a blank disk in a KVM machine, boots the
  result, and has a probe check the lock, Hyprland, the shell, greetd and
  `nova doctor` from inside.
- **Updating:** `nova update` moves a system to the newest release. It points the
  pacman mirror at the release's Arch date and the `[nova]` repository at its URL,
  updates the keyrings, then runs `pacman -Su`, with a snapper snapshot before and
  after. A failed step puts the old files and package databases back; afterwards it
  checks that every kernel's boot image was rebuilt. On a Raspberry Pi it points
  `[nova-alarm]` at the release's set and `[nova]` at its aarch64 folder, with no
  snapshots, and checks the boot partition instead. Pre-releases (the candidates)
  reach only systems that opted in (`nova update --candidates on`) or are
  already on one.
- **Not redistributed:** Chrome and VS Code. They are built on the machine from their
  AUR recipes, which download from the vendors (`nova apps install`). They are outside
  the release, so `nova update` ends by rebuilding whichever is behind the AUR
  (`nova apps update`), and the bar's update badge shows when one is. A recipe runs
  as the user and anyone can push to the AUR, so the commit each was built from is
  kept in `~/.local/state/nova/aur/`. A new release is built unasked only when its
  recipe changed nothing but `pkgver`, `pkgrel` and checksums. Any other change is
  shown in the terminal and built only on a yes; under `--yes` that app waits. The
  first build on a machine takes the recipe as it is.

## Code rules

- **Bash:**
  - `#!/bin/bash` and `set -euo pipefail`
  - 2-space indent
  - functions over copy-paste
  - shellcheck-clean (`make lint`)
  - each helper does one thing
  - errors go to stderr with a non-zero exit
  - no `sudo` inside helpers; privileged actions go through polkit (`pkexec`). The
    exceptions run in a terminal and say so: `nova power switch`,
    `nova apps install` (and the launcher's Uninstall) and `nova usb`
  - a heredoc's delimiter is quoted (`<<'EOF'`) unless its body must expand,
    and then the body holds no backticks, which would run
    ([P1 fact 14](hardware/thinkpad-p1-gen4i.md))
  - code that runs as root and writes into a home takes the account from
    `SUDO_USER` and gives back what it creates there: under `sudo`, `$HOME` is
    `/root` ([P1 fact 47](hardware/thinkpad-p1-gen4i.md))
- **QML:** qmllint-clean. Logic lives in singletons that can be tested against fixtures.
  Three traps that load without an error and draw nothing:
  - no `property var data` or `property string state` on an Item root: both shadow
    Item properties, and `data` is where children go;
  - inside `Type { }`, a name the type declares means the type's own property, so
    `Bar { shell: shell }` assigns the bar's empty `shell` to itself. Pass an outer
    object in under another name (see the bar's Loader in `shell.qml`);
  - Nerd Font icons in the private-use range (U+E000-U+F8FF) are easy to lose when a
    file is rewritten by a tool; `tests/unit/cli/menu.bats` catches an empty one in
    the menu.
- **Rust:** one Cargo workspace at the root. `cargo fmt`, `cargo clippy -D warnings`,
  no unsafe beyond FFI that std lacks (the governor's signal handlers), and std only
  unless a dependency clearly pays for itself. Tools a user waits on (the theme
  engine, the power manager) are Rust; glue that mostly runs other programs stays
  bash.
- **Tests:**
  - bats for helpers (`tests/unit/`); `make test` runs them
  - `tests/qml/run` runs the shell's logic tests (the plugin registry against
    the real plugin index) offscreen under Quickshell, from an installed tree
  - `tools/qml-smoke` opens the shell's windows offscreen from the same tree
    and fails on any runtime QML warning, which qmllint cannot see
  - `tools/shell-smoke` starts the whole shell under a headless sway, summons
    its windows over IPC and checks that it locks at startup, in CI only
  - `tests/usb/stick-test` writes and restores a real stick on a loop device,
    as root, in CI only
  - `tests/install/run` installs a release in QEMU and boots it, in the
    release workflow only
- **Commits:** imperative subject, a body that explains *why*.
