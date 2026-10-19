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
| `src/power/` | `/usr/lib/nova/nova-powerd`, `/usr/lib/nova/bin/nova-power-*` | Power manager (Rust daemon plus bash tools) |
| `src/theme/` | `/usr/lib/nova/bin/nova-theme` | Theme engine (Rust): palettes, templates, theme and background switching, pickers |
| `theme/` | `/usr/share/nova/{themes,templates,wordmark}/` | Palettes, the per-app templates, the wordmark background template |
| `data/hypr/` | `/usr/share/nova/hypr/` | Hyprland defaults (Lua), loaded by the user's `~/.config/hypr/hyprland.lua` |
| `data/session/` | `/usr/lib/systemd/{system,user}/`, `/usr/lib/pam.d/`, `/etc/greetd/` | greetd, PAM, uwsm env, session guard |
| `data/boot/` | `/etc/mkinitcpio.conf.d/`, `/etc/limine-entry-tool.d/`, `/etc/snapper/` | Boot chain drop-ins |
| `data/system/` | `/usr/lib/sysctl.d/`, `/usr/lib/systemd/zram-generator.conf.d/`, … | System tuning |
| `hardware/<model>/` | `/usr/share/nova/hardware/<model>/` | Per-model **data** (match rules, tunings, kernel args) |
| `installer/` | ISO only, except `nova-usb-*` in `/usr/lib/nova/bin/` | archiso profile, installer, USB creator |
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
  | System config | `/etc/nova/` (`power.toml`; written only by `nova` helpers via polkit) |
  | System state | `/var/lib/nova/` (greeter theme mirror, owned by the user who ran the installer) |
  | Runtime | `$XDG_RUNTIME_DIR/nova/` (`unlocked-once`, locks, sockets) |

- **Identifiers:** shell plugin ids are `nova.<name>`. Layer-shell namespaces are
  `nova-<name>`. PAM services are `nova-lock-password`, `nova-lock-fingerprint` and
  `nova-greeter`. User units are `nova-*.service`.
- **"omarchy" appears only in `NOTICE` and `docs/omarchy-script-map.csv`.** CI fails on
  any other occurrence outside `attic/` and `src/power/CLAUDE.md` history.

## Session flow (boot to desktop)

1. Limine boots the UKI. The config has `quiet: yes` and `timeout: 1`, so a key press
   shows the menu with snapshots. `nova recovery` reboots straight into that menu.
2. systemd initramfs, no plymouth. The firmware logo stays until Hyprland's first frame.
3. greetd `initial_session` runs `uwsm start hyprland` as the installed user, once per
   boot.
4. Hyprland starts in the `nova-boot` submap, which has no binds.
5. The shell locks before it draws anything else.
6. The `nova-session-guard` user unit waits up to 6 s for the shell to report
   `lock secure`. If it doesn't, the guard terminates the session, and greetd shows
   `nova-greeter`, or `agreety` if QML fails. Nothing ever shows an unlocked desktop that
   nobody authenticated.
7. **First unlock after boot needs the password.**
   - The lock passes it to `gnome-keyring-daemon --unlock`.
   - It writes `$XDG_RUNTIME_DIR/nova/unlocked-once`.
   - It starts `nova-unlocked.target`, which brings up keyring users such as Chrome and
     VS Code autostarts.
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

- `nova-powerd` is the only thing that writes power policy:
  - CPU limits and governor
  - platform profile
  - dGPU power
  - charge limit
  - Wi-Fi powersave
  - fan
- It picks a **backend** at start: `thinkpad`, `ideapad` (Legion and IdeaPad), or
  `generic`, plus an `nvidia-hybrid` add-on when an NVIDIA dGPU sits beside an iGPU.
- It reads `/etc/nova/power.toml` and exposes state and commands on the system bus
  (`org.nova.Power1`), which the shell and `nova power …` use.
- Charge limits are reported as a capability: `threshold` (numeric, ThinkPad),
  `toggle` (Legion `Long_Life`), or `none`. Every write is read back, and only a
  verified value counts as success.
- Hardware data lives in `hardware/<model>/model.toml`: DMI match rules, kernel args, an
  optional speaker tuning, and quirks. Nothing model-specific is hard-coded in code
  paths.

## Packaging and releases

- **Packages**, built only in CI:

  | Package | Contents |
  |---|---|
  | `nova` | everything in this repo |
  | `linux-nova`, `linux-nova-headers` | Arch's kernel configuration with the BORE scheduler, `HZ_1000` and the x86-64-v3 instruction-set baseline |
  | `nvidia-open-nova` | NVIDIA modules prebuilt for `linux-nova` |
  | `limine-snapper-sync`, `limine-entry-tool` | rebuilt from the AUR |

- **Fallback kernel:** Arch's `linux-lts` + `nvidia-open-lts` stay installed as the
  fallback boot entry.
- **A release** (`v1.0.0-beta.1`, …) has three parts:
  - the signed `[nova]` repository, attached to the GitHub release;
  - the installer ISO;
  - `release.toml`, which pins the Arch Linux Archive date the release was tested
    against.
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
  - no `sudo` inside helpers; privileged actions go through polkit (`pkexec`) or
    `nova-powerd`
- **QML:** qmllint-clean. Logic lives in singletons that can be tested against fixtures.
  No `property var data` or `property string state` on an Item root, because both shadow
  Item properties.
- **Rust:** one Cargo workspace at the root. `cargo fmt`, `cargo clippy -D warnings`,
  no unsafe, std only unless a dependency clearly pays for itself. Tools a user waits
  on (the theme engine, the power manager) are Rust; glue that mostly runs other
  programs stays bash.
- **Tests:**
  - bats for helpers (`tests/unit/`)
  - qmltestrunner for QML singletons
  - QEMU end-to-end tests (`tests/qemu/`) for install, boot and lock
  - `make test` runs everything that doesn't need QEMU
- **Commits:** imperative subject, a body that explains *why*.
