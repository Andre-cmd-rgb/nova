# Nova architecture

Nova is a small Arch Linux desktop: Hyprland, a Quickshell shell, one `nova` command,
and a power manager. It ships as **one package, `nova`**, installed into a plain Arch
system. This document is the contract every component follows; read it before adding
code.

## Components and where they install

| Source | Installs to | What it is |
|---|---|---|
| `src/shell/` | `/usr/share/nova/shell/` | The Quickshell shell: bar, lock, menu, notifications, OSD, panels, Settings |
| `src/cli/nova` | `/usr/bin/nova` | Dispatcher: `nova <group> <verb> [args]` |
| `src/cli/bin/` | `/usr/lib/nova/bin/nova-<group>-<verb>` | Helper commands (bash), one per file |
| `src/power/` | `/usr/lib/nova/bin/thinkpad-power{,d}`, system units, udev rules, a sleep hook | The ThinkPad P1 Gen 4i's power manager (bash policy, Rust governor); inert on other machines |
| `src/theme/` | `/usr/lib/nova/bin/nova-theme` | Theme engine (Rust): palettes, templates, theme and background switching, pickers |
| `theme/` | `/usr/share/nova/{themes,templates,wordmark}/` | Palettes, the per-app templates, the wordmark background template |
| `data/hypr/` | `/usr/share/nova/default/hypr/` | Hyprland defaults (Lua), loaded by the user's `~/.config/hypr/hyprland.lua` |
| `data/session/` | `/usr/lib/systemd/user/`, `/etc/pam.d/`, `/usr/share/uwsm/env.d/`, `/usr/share/nova/{session,greeter}/` | greetd (a config template the installer renders), the greeter, PAM, uwsm env, session guard, keyring |
| `data/boot/` | `/etc/mkinitcpio.conf.d/`, `/etc/limine-entry-tool.d/`, `/usr/share/snapper/config-templates/`, pacman hooks | Boot chain drop-ins and the boot-entry guards |
| `data/systemd/` | `/usr/lib/systemd/user/`, `/usr/lib/systemd/{logind,sleep}.conf.d/` | Session user units; logind and sleep policy |
| `data/hardware/` | `/usr/share/nova/hardware/`, `/usr/share/uwsm/env.d/`, `/etc` via `nova-hw-apply` | Per-model **data**: the DMI model list, drop-ins, packages, the session environment |
| `installer/` | ISO only, except `nova-usb` in `/usr/lib/nova/bin/` | archiso profile, installer, USB creator |
| `packaging/` | – | PKGBUILDs: `nova`, `linux-nova`, `nvidia-open-nova`, AUR rebuilds |

Every component has an `install.mk` that the top-level `Makefile` includes, and
`make DESTDIR=… install` is the only way files reach a system. The `nova` PKGBUILD calls
exactly that, so pacman owns every file.

## Names, paths, environment

- **Command:** `nova`. Helpers are `nova-<group>-<verb>` in `/usr/lib/nova/bin`, which
  the session puts on `PATH`. `nova <group> <verb>` runs `nova-<group>-<verb>` when it
  exists, else `nova-<group>` with the verb as its first argument, so `nova theme set
  white` runs `nova-theme set white`.
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
  | User config | `~/.config/nova/` (`shell.json`, `menu.jsonc`, `themes/`, `templates/`, `backgrounds/`, `usb.toml`, `hooks/`) |
  | User state | `~/.local/state/nova/` (`current/`, `rendered/`, `backgrounds/`, battery and screen-time history) |
  | System config | `/etc/thinkpad-power.conf` on a P1 Gen 4i (optional tunables); `/etc` drop-ins from the hardware profile, listed in `/var/lib/nova/hardware-files` |
  | System state | `/var/lib/nova/` (`greeter/`, the theme mirror owned by the user the installer created; `hardware-files`) |
  | Runtime | `$XDG_RUNTIME_DIR/nova/` (`unlocked-once`, locks, sockets) |

- **Identifiers:** shell plugin ids are `nova.<name>`. Layer-shell namespaces are
  `nova-<name>`. PAM services are `nova-lock-password`, `nova-lock-fingerprint` and
  `nova-greeter`. User units are `nova-*.service`.
- **"omarchy" appears only in `NOTICE` and `docs/`.** CI fails on any `omarchy-`,
  `omarchy_`, `/omarchy`, `OMARCHY_PATH` or `qs.Omarchy` under `src/` and `data/`.

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
     migration of a carried-over keyring.
   - A greeter login does the same through the guard: the greeter's PAM stack has
     already unlocked the keyring.
   - Fingerprint unlock is offered only once `unlocked-once` exists.

## Theme flow

A theme is a directory with a `colors.toml` palette (flat `key = "value"` lines), plus any
files it ships ready-made: a `shell.toml`, `shell.<section>.toml` overrides, an
`icons.theme`, or a per-app file that replaces a template. Nova's themes live in
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
downloaded theme can't inject code into the Lua, CSS or JSON it is rendered into. It
never needs root and never rebuilds an initramfs. Nothing before the lock screen is
themed.

**Backgrounds** (`nova theme bg pick|next|set`): a theme offers its own backgrounds,
`~/.config/nova/backgrounds/<theme>/`, and the shared `~/.config/nova/backgrounds/`.
Each theme remembers its pick in `~/.local/state/nova/backgrounds/by-theme/`. A pick from
the shared folder also becomes the default for themes that have no pick of their own.

## Power and hardware

- **Power profiles** belong to power-profiles-daemon. `nova-power-profile` sets one
  and remembers it for the current power source; the shell's battery panel runs
  `nova-power-profile restore` at login and on every plug and unplug, which puts back
  the remembered choice (performance on AC and power-saver on battery by default).
- **The ThinkPad P1 Gen 4i** adds `thinkpad-power` (the policy: the dGPU off the PCI
  bus on battery, CPU and platform tunables, Wi-Fi power save, the hibernate rescan)
  and `thinkpad-powerd` (the governor that owns PL1, PL2, the frequency ceiling, the
  iGPU ceiling and the fans). Both are enabled by the package for every machine and
  start only on a P1 Gen 4i: each unit has a DMI `ConditionFirmware=`, and the udev
  rule and sleep hook check the model themselves. The facts behind every choice are
  in [hardware/thinkpad-p1-gen4i.md](hardware/thinkpad-p1-gen4i.md).
- **A generic `nova-powerd`** with backends (`thinkpad`, `ideapad` for the Legion,
  `generic`, plus an `nvidia-hybrid` add-on) is in progress on the `power-rewrite`
  branch. It replaces thinkpad-power only once it matches it on the watt meter.
- **Charge limits** are reported as a capability: `threshold` (numeric, ThinkPad),
  `toggle` (Legion `Long_Life`), or `none`. Every write is read back, and only a
  verified value counts as success.
- **Sleep:** the lid, the suspend key and the menu's Suspend all `sleep`, which logind
  turns into suspend-then-hibernate (hibernating after 2 h, and never on AC) or plain
  suspend on a machine that cannot hibernate. The TPM key-provisioning units are
  skipped unless `nova.tpm2` is on the kernel command line: Nova does not encrypt the
  disk, and they cost about four seconds of every measured boot.
- **Hardware profiles** live in `data/hardware/`. `models` maps a DMI
  `product_version` pattern to a profile; `nova-hw-detect` and the Hyprland loader
  both read it. A profile holds:
  - `packages`: Arch packages the installer adds (microcode, firmware, drivers)
  - `etc/`: modprobe, NetworkManager and boot-entry drop-ins, which cannot apply to
    one model from `/usr`. `nova-hw-apply` copies them into `/etc` from a pacman hook
    on every install and upgrade of `nova`, and removes the ones a release dropped.

  Session-side settings check the model themselves: a uwsm `env.d` file and a
  `default/hypr/hardware/<profile>.lua` module.

## Packaging and releases

- **Packages**, built only in CI:

  | Package | Contents |
  |---|---|
  | `nova` | everything in this repo |
  | `nova-keyring` | the key the `[nova]` repository is signed with |
  | `linux-nova`, `linux-nova-headers` | Arch's kernel configuration with the BORE scheduler, `HZ_1000` and the x86-64-v3 instruction-set baseline |
  | `nvidia-open-nova` | NVIDIA modules prebuilt for `linux-nova` |
  | `limine-snapper-sync`, `limine-entry-tool` | rebuilt from the AUR |

- **Fallback kernel:** Arch's `linux-lts` + `nvidia-open-lts` stay installed as the
  fallback boot entry.
- **A release** (`v1.0.0-beta.1`, …) has three parts:
  - the signed `[nova]` repository, attached to the GitHub release;
  - the installer ISO (`installer/iso`, built by `tools/build-iso`), which
    installs over the network;
  - `release.toml`, which pins the Arch Linux Archive date the release was tested
    against;
  - `nova-usb` and `packages.txt`, for making the stick (below).
- **The stick:** `nova usb` (`installer/nova-usb`, also on every release page, so
  it runs on any Arch-based system) writes a GPT stick of its own instead of the
  raw ISO:
  - partition 1, `NOVA`: a FAT EFI partition holding the ISO's files, which
    archiso boots from as they are (it finds itself by a `/boot/<uuid>.uuid`
    file, not by the disk). With packages on the stick, `nova/repo/` holds
    every package any install can need (`packages.txt`, from
    `nova-install --list-packages`) and their signatures, as the
    `[nova-offline]` repository;
  - partition 2, `NOVA-DATA`, only when something is carried: LUKS2, btrfs,
    and `carry/` with one `tar.zst` per item, `SHA256SUMS` and `manifest.json`.
    `nova-install --unlock` opens it before the network is needed (carried
    Wi-Fi gets the live system online); the install puts each item back once
    the account exists. Bluetooth pairings and fingerprints come back only on
    the computer they came from.

  Everything that writes a disk runs in one root step (`nova-usb write`), which
  checks the device again before touching it; `tests/usb/stick-test` runs it
  against a loop device in CI.

  [releasing.md](releasing.md) has the steps and the signing key;
  [packaging.md](packaging.md) has how each package is kept up to date.
- **Updating:** `nova update` moves a system to the newest release. It rewrites the
  pacman mirror to that date, runs `pacman -Syu` and updates the `[nova]` repository
  URL, with a snapper snapshot before and after.
- **Not redistributed:** Chrome and VS Code. They are built on the machine from their
  AUR recipes, which download from the vendors.

## Code rules

- **Bash:**
  - `#!/bin/bash` and `set -euo pipefail`
  - 2-space indent
  - functions over copy-paste
  - shellcheck-clean (`make lint`)
  - each helper does one thing
  - errors go to stderr with a non-zero exit
  - no `sudo` inside helpers; privileged actions go through polkit (`pkexec`). The
    one exception is `thinkpad-power switch`, which runs in a terminal and says so
- **QML:** qmllint-clean. Logic lives in singletons that can be tested against fixtures.
  No `property var data` or `property string state` on an Item root, because both shadow
  Item properties.
- **Rust:** one Cargo workspace at the root. `cargo fmt`, `cargo clippy -D warnings`,
  no unsafe beyond FFI that std lacks (the governor's signal handlers), std only unless a dependency clearly pays for itself. Tools a user waits
  on (the theme engine, the power manager) are Rust; glue that mostly runs other
  programs stays bash.
- **Tests:**
  - bats for helpers (`tests/unit/`)
  - qmltestrunner for QML singletons
  - `tools/qml-smoke` opens the shell's windows offscreen from an installed tree
    and fails on any runtime QML warning, which qmllint cannot see
  - QEMU end-to-end tests (`tests/qemu/`) for install, boot and lock
  - `make test` runs everything that doesn't need QEMU
- **Commits:** imperative subject, a body that explains *why*.
