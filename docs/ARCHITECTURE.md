# Nova architecture

Nova is a small Arch Linux desktop: Hyprland, a Quickshell shell, one `nova` command, and a power governor. It ships as **one package, `nova`**, installed into a plain Arch system.

This document is the contract every component follows. Read it before adding code.

## Components and where they install

| Source | Installs to | What it is |
|---|---|---|
| `src/shell/` | `/usr/share/nova/shell/` | The Quickshell shell: bar, lock, menu, notifications, OSD, panels, Settings |
| `src/cli/nova` | `/usr/bin/nova` | Dispatcher: `nova <group> <verb> [args]` |
| `src/cli/bin/` | `/usr/lib/nova/bin/nova-<group>-<verb>` | Helper commands (bash), one per file |
| `src/power/` | `/usr/lib/nova/bin/nova-power`, `/usr/lib/nova/nova-powerd`, `nova-undervolt`, system units, udev rules, sleep hooks | Nova's power governor: the policy (bash) and the governor (Rust), tuned for and so far started only on the ThinkPad P1 Gen 4i; and the CPU undervolt (Rust), for any Intel laptop whose firmware allows one |
| `src/patch/` | `/usr/lib/nova/bin/nova-patch`, `/usr/lib/nova/nova-patch-apply`, a polkit action, `nova-patch-ram.service` | Patches: fixes for one computer's faults (bad memory, a device's quirk), kept across reinstalls by export and add; see [patches.md](patches.md) |
| `src/airdrop/` | `/usr/lib/nova/bin/nova-airdrop`, `/usr/lib/nova/nova-airdropd`, `nova-airdrop-bell`, `nova-airdrop-radio`, `nova-airdrop-apply`, a polkit action, `nova-airdrop@.service`, `nova-airdrop-bell@.service`, `nova-airdrop-bell-wake@.service` | AirDrop, receiving from and sending to iPhones nearby: the receiver and sender, its command and its doorbell (Rust), and the helper that lends it the Wi-Fi card and takes it back ([airdrop.md](airdrop.md)) |
| `src/apps/` | `/usr/lib/nova/bin/nova-apps-*`, `/usr/lib/nova/nova-apps-apply`, a polkit action, `/usr/share/nova/apps/`, the App Center's desktop entry and icon | The App Center's catalog (Rust) and its helpers, which `nova apps` runs too; the window is the shell's (`plugins/store`); see [apps.md](apps.md) |
| `src/iphone/` | `/usr/lib/nova/nova-iphone-notifications`, `/usr/lib/nova/bin/nova-notification-iphone`, `nova-iphone-notifications.service` (user) | iPhone notifications: an iPhone's notifications shown as Nova's, through Apple's Notification Center Service over Bluetooth LE (Python, with D-Bus and GLib), and its command ([iphone.md](iphone.md)) |
| `src/theme/` | `/usr/lib/nova/bin/nova-theme` | Theme engine (Rust): palettes, templates, theme and background switching, pickers |
| `src/screensaver/` | `/usr/lib/nova/bin/nova-screensaver-effect` | The screensaver's text effects (Rust): a text played in a terminal, one effect after another |
| `src/session/` | `/usr/lib/nova/nova-sessiond`, `nova-sessiond.service` (user) | What the session watches for as long as it runs, in one small process (Rust): the apps keeping the screen awake (`org.freedesktop.ScreenSaver`), the lock before sleep, "… quit unexpectedly" with Reopen for an app a crash took away, the clamshell passes and the X11 scale as displays come and go, and removable drives mounted while somebody has unlocked |
| `src/sd/` | – (in the programs that use it) | `nova-sd`, the crate through which Nova's Rust reaches D-Bus and the journal: libsystemd's sd-bus and sd-journal, by FFI |
| `theme/` | `/usr/share/nova/{themes,templates,wordmark}/` | Palettes, the per-app templates, the wordmark background template |
| `data/hypr/` | `/usr/share/nova/default/hypr/` | Hyprland defaults (Lua), loaded by the user's `~/.config/hypr/hyprland.lua` |
| `data/session/` | `/usr/lib/systemd/user/`, `/etc/pam.d/`, `/etc/sudoers.d/`, `/etc/xdg-desktop-portal/`, `/usr/share/uwsm/env.d/`, `/usr/share/nova/{session,greeter}/` | greetd (a config template the installer renders), the greeter, PAM, uwsm env, session guard, keyring, the desktop portals (gnome-keyring's for a Flatpak app's secrets) |
| `data/boot/` | `/etc/mkinitcpio.conf.d/`, `/etc/limine-entry-tool.d/`, `/usr/share/snapper/config-templates/`, pacman hooks | Boot chain drop-ins and the boot-entry guards |
| `data/systemd/` | `/usr/lib/systemd/user/`, `/usr/lib/systemd/{logind,sleep}.conf.d/` | Session user units; logind and sleep policy; the package autostarts Nova turns off (masked) |
| `data/firmware/` | `/usr/share/polkit-1/rules.d/` | the rule that lets nova-firmware-job tell fwupd to quit after a check |
| `data/audio/` | `/usr/share/nova/default/audio/` | Speaker tunings, matched to the machine by `nova-audio-tuning` |
| `data/battery/` | `/usr/lib/nova/bin/`, `/usr/lib/nova/`, a udev rule, a system unit, a polkit action, a UPower drop-in | The charge limit, and what UPower does at the battery's end |
| `data/browser/` | `/usr/lib/nova/`, Chrome's and Chromium's managed policies, a system path unit | Chrome's toolbar in the theme's color |
| `data/defaults/` | `/usr/share/nova/default/` | The defaults the shell reads (`shell.json`, `menu.jsonc`, the launcher's hidden entries), which `~/.config/nova` overrides |
| `data/skel/` | `/usr/share/nova/skel/` | A new account's starting files (`useradd -k`) |
| `data/caffeine/`, `data/screensaver/` | `/usr/lib/nova/bin/`, `/usr/lib/nova/`, `/usr/share/nova/screensaver/`, a polkit action | Caffeine (the screen stays on, a closed lid only darkens it) and the screensaver |
| `data/hardware/` | `/usr/share/nova/hardware/`, `/usr/share/uwsm/env.d/`, `/etc` via `nova-hw-apply` | Per-model **data**: the DMI model list, drop-ins, packages, the session environment |
| `installer/` | ISO only, except `nova-usb` in `/usr/lib/nova/bin/` | archiso profile, installer, USB creator |
| `packaging/` | – | PKGBUILDs: `nova`, `linux-nova`, `nvidia-open-nova`, AUR rebuilds |

How files reach a system:

- Every component has an `install.mk` that the top-level `Makefile` includes.
- `make DESTDIR=… install` is the only way files reach a system.
- The `nova` PKGBUILD calls exactly that, so pacman owns every file.

## Names, paths, environment

### Commands

- **The command is `nova`.** Helpers are `nova-<group>-<verb>` in `/usr/lib/nova/bin`, which the session puts on `PATH`.
- **Dispatch:** `nova` runs the longest helper name its words spell, with the remaining words as arguments. `nova theme set white` tries `nova-theme-set-white`, then `nova-theme-set`, and runs `nova-theme set white`. A group name alone that is no helper's, such as `nova capture`, lists the group's commands.
- **Help:** each helper declares one-line metadata in its header comments, which `nova help` reads:

  ```bash
  # nova:summary=Apply a theme
  # nova:args=<theme>
  ```

  Helpers marked `# nova:hidden=true` are internal, and stay out of the help. A compiled helper cannot carry the comments, so `src/cli/nova` holds its summary, or hides it.
- **What runs at rest earns its place.** Nova keeps every feature and holds little memory for them: a window is built when it opens and freed when it closes; a watcher waits on an event (a D-Bus signal, a socket, the journal's descriptor), never a clock; the session's watchers are one Rust process (`nova-sessiond`), not one interpreter each; a package's autostart runs only if Nova chose it (`data/systemd/install.mk`); a daemon woken for a moment is let go after (fwupd, by `nova-firmware-job`). The install test checks the autostarts and holds the session at rest to a memory budget (`tests/install/probe`).
- **Running apps are reached through `nova-session-pgrep`.** It finds, or with `--signal` signals, only the user's processes started with this `HOME` and `XDG_RUNTIME_DIR`. Use it for every lookup by name, never a bare `pgrep` or `pkill`. A second session of the same user is a different session: the tests, `tools/screenshots`, and a nested Hyprland each have a home and runtime folder of their own. A bare lookup by name once let a test recolour the user's terminals and end their clipboard's watchers. `tests/unit/cli/session-pgrep.bats` fails on a new bare lookup.
- **What belongs to the computer is written only from the account's own home.** That covers the greeter's mirror in `/var/lib/nova/greeter`, and Chrome's colour policy made from it.

### Environment

`NOVA_PATH=/usr/share/nova`. Code must never hard-code `/usr/share/nova` where `$NOVA_PATH` is available. That way tests can point it at the source tree.

### Locations

| Kind | Path | Holds |
|---|---|---|
| User config | `~/.config/nova/` | `shell.json`, `menu.jsonc`, `themes/`, `templates/`, `backgrounds/`, `hooks/`; `calendars.json`: the calendar's accounts and calendars, with no secret in it |
| | `~/.config/nova-<plugin>/` | a plugin's own settings (`nova-batterylife`, `nova-screentime`, `nova-mobile-data`) |
| User state | `~/.local/state/nova/` | `current/`, `rendered/`, `backgrounds/`, `aur/`; `monitors.json`: the displays as Settings keeps them; `input.json`: the keyboard's layouts and the pointer as Settings keeps them; `notifications.json`: Do Not Disturb, and its schedule's last turn; `calendar.json`: how far the calendar's reminders have been looked at; `calendar-sync/`: what each calendar's server last had, and how each account's last sync went; `calculator.json`: the Calculator's history, and Basic or Scientific, the angle's unit and the history pane as last left; `adaptive`: the adaptive theme's Auto, Dark or Light; `airdrop/`: the certificate the AirDrop receiver shows to senders, made at its first use; `welcome-pending`: a new account's, from Nova's skel, until it closes the welcome |
| | `~/.local/state/nova-<plugin>/` | a plugin's history |
| User data | `~/.local/share/nova/calendar/` | the calendars: `calendar.ics`, the one on this computer, and one file for each account's calendar and each subscription |
| | `~/.local/share/nova-dictation/` | the speech model, downloaded at dictation's first use |
| | `~/.local/share/flatpak/` | Flathub's apps, as the App Center installs them: flatpak's own |
| User cache | `~/.cache/nova/adaptive/` | the adaptive theme's palettes, by the photo's path, size and time |
| | `~/.cache/nova/apps/` | the App Center's catalog, the icons of Arch's catalog as PNGs, and the apps' pictures |
| System config | `/etc/nova/power.conf` | on a P1 Gen 4i, optional tunables |
| | `/etc` drop-ins from the hardware profile | listed in `/var/lib/nova/hardware-files` |
| | `/etc/nova/patches/` | this computer's patches; their `/etc` files are listed in `/var/lib/nova/patch-files` |
| System state | `/var/lib/nova/` | `greeter/`, the theme mirror, owned by the user the installer created; `hardware-files`; `patch-files`; `patches`: whether each patch is on |
| Runtime | `$XDG_RUNTIME_DIR/nova/` | `unlocked-once`, locks, sockets; `dictation/`'s recordings until they are read; a display change not kept yet; `caffeine`, Caffeine's switch; `nightlight-turn`: the last turn the night light's schedule made, so that a restarted shell does not make it again; `power-profile`: the power mode chosen since the unplug; `idle-inhibitors`: the apps keeping the screen awake through `org.freedesktop.ScreenSaver`, which `nova-sessiond` serves; `automount`: the session's Hyprland instance while removable drives may be mounted, which `nova-automount` writes for the lock screen; `automount-swept`: the session whose drives were all mounted at its first unlock; `airdrop.sock`, where `nova airdrop` and the shell reach the AirDrop receiver while it runs; `apps/`, the App Center's installs: `status.json`, how far each is, and each one's log; `iphone-notifications.json`: how the iPhone is, as iPhone notifications' service last said, for Settings and `nova notification iphone` |
| | `/run/nova-airdrop/` | while AirDrop is on, what there is to put back of the Wi-Fi; afterwards, how putting it back went |

### Identifiers

| Thing | Name |
|---|---|
| Shell plugin ids | `nova.<name>`; every plugin ships in the `nova` package and the shell loads no other (`plugins/index.json`, written at build time by `tools/plugin-index`, lists them) |
| Layer-shell namespaces | `nova-<name>` |
| PAM services | `nova-lock-password`, `nova-lock-fingerprint`, `nova-greeter`, `nova-sudo` |
| User units | `nova-*.service` |
| polkit actions | `org.nova.*` |
| Session bus names | `org.nova.*` (`org.nova.iPhoneNotifications`); `org.freedesktop.ScreenSaver`, which `nova-sessiond` holds for the session |

### Naming

**Nova's code is its own.** The project its shell began from is named nowhere, and none of its code is here.

- Each part was written anew. What the two still have in common is what cannot be said another way: the names of Hyprland's options, of VS Code's colors, of packages and of environment variables.
- `NOTICE` has the licenses of what Nova does build on: the color schemes behind the palettes, Unicode's emoji data, whisper.cpp, the Hyprland it patches, and the speech model.
- `make check-names` (run in CI) fails on that project's name anywhere.

## Session flow (boot to desktop)

1. **Limine boots the UKI.** The config has `quiet: yes` and `timeout: 1`, so a key press shows the menu with snapshots. `nova recovery` reboots straight into that menu.
2. **systemd initramfs, no plymouth.** The firmware logo stays until Hyprland's first frame.
3. **greetd's `initial_session`** runs `uwsm start hyprland` as the installed user, once per boot, with `NOVA_LOGIN=autologin`.
   - Every command greetd runs sets `NOVA_LOGIN`; only the greeter's `password` means somebody authenticated.
   - Anything else, or nothing, is treated as autologin, so the session fails closed.
4. **Hyprland starts in the `nova-boot` submap**, which has no binds.
5. **The shell locks** before it draws anything else.
6. **`nova-session-guard`** (a user unit every user has enabled) waits for `nova-shell lock state` to say `secure`: about 18 s while no shell runs, up to three minutes while one is starting and does not answer yet.
   - If it doesn't, the guard terminates the session, and greetd shows the greeter: `src/shell/greeter.qml` on a minimal Hyprland, or `agreety` on the console if that never shows.
   - Nothing ever shows an unlocked desktop that nobody authenticated.
7. **The first unlock after boot needs the password.**
   - `nova-lock-password` ends with `pam_gnome_keyring`, which unlocks the login keyring with the password during auth. The password never leaves PAM.
   - `nova-session-first-unlock` writes `$XDG_RUNTIME_DIR/nova/unlocked-once` and starts `nova-unlocked.target`, which brings up keyring users such as the migration of a passwordless keyring (`nova doctor` offers it).
   - It opens the welcome while the account has the marker its skel gave it (`welcome-pending`), which the welcome takes away as it closes.
   - A greeter login does the same through the guard: the greeter's PAM stack has already unlocked the keyring.
   - Fingerprint unlock is offered only once `unlocked-once` exists.
   - polkit's prompts and sudo take a finger from the start: neither needs the password for the keyring. Nova's `/etc/pam.d/polkit-1` shadows polkit's own, and `/etc/sudoers.d/20-nova-pam` points sudo at `nova-sudo`; both put `pam_fprintd` ahead of the stack they wrap, and skip it while the lid is shut.
8. **Removable drives mount only in an unlocked session.**
   - Mounting one has the kernel read its file system, so a drive plugged into a locked computer waits.
   - The lock service runs `nova-automount on` after the first unlock and `off` whenever it locks.
   - That writes or removes `automount` in the runtime directory, holding the session's Hyprland instance, so that one a crashed session left counts for nothing. `nova-sessiond` mounts through udisks while it is there: every drive at the session's first unlock, after that those plugged in since, so a drive unmounted on purpose stays so.
   - Only the drives udisks says a desktop may mount on its own (USB, memory cards, removable media), never one it counts as the system's or is told to leave alone (`UDISKS_IGNORE`, as `nova usb` marks the stick it writes). An encrypted one is asked for its passphrase.
9. **The machine sleeps locked.**
   - `nova-sessiond` holds a logind delay inhibitor while the machine is awake, as a descriptor no helper inherits.
   - At PrepareForSleep, `nova-system-sleep-lock` asks for the lock and waits for `secure`, up to 36 s of logind's 45 s window (`InhibitDelayMaxSec`). Then the inhibitor goes, to be taken again on the wake.
   - A healthy lock takes well under a second. A slow one gets the screens turned off after 2 s, and again each second, as a key press turns them on.
   - If logind suspends before it is secure (a delay inhibitor is a timer), the screens stay off after the wake and the lock is asked for again (`--resumed`, from `sleep-unsecured` in the runtime directory) until it is up.

## Theme flow

### What a theme is

A theme is a directory with a `colors.toml` palette (flat `key = "value"` lines), plus any files it ships ready-made:

- a `shell.toml`, and `shell.<section>.toml` overrides;
- an `icons.theme`: the icon set it was made with, used when that set is installed, Adwaita otherwise;
- a per-app file that replaces a template.

Nova's themes live in `/usr/share/nova/themes/`. A theme of the same name in `~/.config/nova/themes/` overrides it file by file.

### `nova theme set <name>`

`nova-theme` does this in under 5 ms of its own work:

1. **Render** into a fresh `~/.local/state/nova/rendered/<name>.<stamp>/`:
   - the theme's files, Nova's copy first and then the user's;
   - every template (`~/.config/nova/templates/*.tpl`, then Nova's) rendered with the palette, unless the theme already ships that file;
   - the wordmark background `backgrounds/nova.svg`.
2. **Swap atomically:** `current/theme` is a symlink, replaced by one rename. Readers see the old theme or the new one, never a mix.
3. **Pick the background:** the one last chosen for this theme, else the latest shared photo chosen, else the wordmark.
4. **Tell the shell:** a `themeTransition` IPC fades to the new background and recolors the shell in one step.
5. **Apply** (`nova-theme-apply`, in parallel):
   - `hyprctl reload`;
   - GTK: the palette as `nova.css` in `~/.config/gtk-3.0` and `gtk-4.0`, which `gtk.css` links to; color-scheme; the GTK 3 theme `adw-gtk3` or `adw-gtk3-dark`, which draws with the palette's colors (Qt follows GTK 3); and the same as XSETTINGS for X11 apps (`nova-hyprland-x11-scale`);
   - Flatpak: an override of the user's that shows every app those two folders, read-only, set once;
   - foot: new windows read `theme.ini`, open ones get OSC escapes;
   - btop, VS Code, Claude Code, T3 Code;
   - the greeter mirror in `/var/lib/nova/greeter/`, from which a root path unit sets Chrome's color policy.

### What a theme can and cannot do

- **A palette cannot inject code.** Palette values may contain only hex, `rgb()`, words, numbers and a few separators, so a `colors.toml` can't inject code into the Lua, CSS or JSON it is rendered into.
- **Files shipped ready-made are used as they are, and some are code.** Hyprland runs `hyprland.lua`, and a `foot.ini` can set the terminal's shell. A downloaded theme with more than a palette is a program, to install only from someone you trust.
- Theming never needs root and never rebuilds an initramfs.
- Nothing before the lock screen is themed.

### The adaptive theme

The adaptive theme takes its colors from the background instead of a fixed palette.

- **What marks one:** a `colors.toml` with `adaptive = "auto"` (or `"dark"`, `"light"`). The colors in it are for when there is no photo, the wordmark being drawn in the theme's own.
- **The mode chosen in Settings:** `nova theme adaptive auto|dark|light` (Settings → Appearance → Adaptive theme) keeps a choice in `~/.local/state/nova/adaptive`, for every adaptive theme, over the `adaptive` word in its `colors.toml`, and sets the theme in use again. With no argument it prints the choice in effect.
- **When it reads the photo:** on `nova theme set`, and on every `bg set` while such a theme is in use.
- **How:** the engine has `vipsthumbnail` shrink the photo to a PPM, and reads three things from it in OKLCH (`src/theme/src/adaptive.rs`): the hue of the parts the surfaces will stand in for (the darker ones for a dark theme), the hue that stands out, and how vivid it is.
- **Lightness comes from the role, not the photo**, so text reads on its surface whatever the photo is, and the terminal's red stays red.
- **Cache:** a palette is kept in `~/.cache/nova/adaptive/` by the photo's path, size and time.
- `nova theme palette <image>` prints one.

### A see-through bar

A see-through bar has no surface, so `nova-theme bar` measures the background along the bar's edge. It answers, by APCA's lightness contrast:

- the ink: the theme's text color, or its background color on a pale photo;
- the shade it needs behind it: none over a dark sky, a gradient of the other color where the photo is bright or busy.

The shell draws the shade as a layer of its own (`nova-bar-shade`) under the windows, twice the bar deep, so it ends in nothing rather than in a line.

### Backgrounds

`nova theme bg pick|next|set`:

- A theme offers its own backgrounds, `~/.config/nova/backgrounds/<theme>/`, and the shared `~/.config/nova/backgrounds/`.
- Each theme remembers its pick in `~/.local/state/nova/backgrounds/by-theme/`.
- A pick from the shared folder also becomes the default for themes that have no pick of their own.

## Power and hardware

### One power system

**`nova power`** is one system. Its controls are in:

- Settings → Performance: the power mode, what the governor is doing right now, the discrete GPU and the undervolt;
- Settings → Battery: the charge limit, the lid and the power button.

Its manual is [power.md](power.md).

### Power profiles

Power profiles belong to power-profiles-daemon, and are the battery's.

- **Plugged in** it is always performance, with nothing to choose.
- **On battery** every unplug starts in power-saver. `nova-power-profile set` changes the mode until the next plug-in or restart, kept in the runtime directory.
- **The shell's battery service** runs `nova-power-profile restore` at login and on every plug and unplug. That puts back performance plugged in and, unplugged, the mode chosen since the unplug, or power-saver.
- **The governor never sets one.** On the P1 Gen 4i it reads it, as how high to climb on battery.

### The governor

The governor is two halves:

| Half | Runs | Owns |
|---|---|---|
| `nova-power`, the policy | on each plug and unplug, at boot and after resume | the dGPU off the PCI bus on battery, CPU and platform tunables, Wi-Fi power save, the hibernate rescan |
| `nova-powerd` | throughout | PL1, PL2, the frequency ceiling, the iGPU ceiling and the fans |

Its tiers and limits are measured on the ThinkPad P1 Gen 4i, so today it starts only there: each unit has a DMI `ConditionFirmware=`, and the udev rule and sleep hook check the model themselves. The facts behind every choice are in [hardware/thinkpad-p1-gen4i.md](hardware/thinkpad-p1-gen4i.md).

### The discrete GPU

**When the discrete GPU is on** is the user's choice on a P1 Gen 4i.

- Settings → Performance offers *On When Plugged In* or *Always Off* (`nova power gpu mode`, which `nova power gpu-mode` applies at once).
- A polkit action lets the active session set it without a password.
- Other machines leave an idle NVIDIA card to the driver's runtime power management, and Settings shows no choice.

### Undervolt

`nova power undervolt set -70`, or `set -80 -70` for the core's and the cache's each, is an offset on an Intel CPU's core and cache, through the overclocking mailbox.

- **Where the firmware lets one through:** a P1 Gen 4i's only with its hidden Overclocking Lock off (fact 16).
- **Nova sets none by itself:** the depth is each CPU's own.
- **When it is applied:** `nova-undervolt` applies it at boot (`nova-undervolt.service`) and after every sleep, and reads it back.
- **When it is held:** before writing, it records the boot it is on in, on disk; a clean shutdown takes it off and clears the record. So a boot that finds an earlier boot's record holds the offset instead of applying it, and so does the first machine check the kernel logs.
- **Setting it** takes an administrator's password, through polkit.
- **Shared voltage:** on some of these CPUs the core and the cache share one voltage, at the higher of what each asks for (on the P1 Gen 4i the core's is its own). So `nova power undervolt compare` reads the core's own voltage (IA32_PERF_STATUS) under load with each of two offsets, to show whether a core deeper than its cache moves it at all.

### Other laptops

Other laptops get power-profiles-daemon, the charge limit and the undervolt for now. The governor starts on another model once its tiers are measured there and match the P1's results on the watt meter.

### Charge limits

Charge limits are reported as a capability:

| Capability | Hardware |
|---|---|
| `threshold` | a numeric limit, `charge_control_end_threshold` (ThinkPads, and most laptops) |
| `switch` | the firmware's own fixed limit, on or off: `charge_types` with `Long_Life` (Lenovo IdeaPad and Legion) |
| `none` | no limit Nova can set |

Every write is read back, and only a verified value counts as success.

### The charge shown

A charger fills the battery, then lets it rest: plugged in again at 96-99%, it waits for the charge to fall a few percent before it tops it up, which spares the battery. So plugged in with its charge done (UPower's fully-charged) and no limit on, a battery at 95% or more shows as 100%, as on a Mac. Under a limit it shows what it holds, and below 95% a stopped charge (a charger too weak, a battery too warm) shows as it is. The shell's widgets take the rule from `Commons/Charge.qml` (`ChargeRule.js`), which reads the limit from `nova battery limit --json` and is told of a new one by `nova-shell battery limitChanged`; `nova-battery-info`, behind the battery notification, has the same rule. The battery's record (`nova battery`) keeps the battery's own figures.

### Sleep

- **The lid, the suspend key and the menu's Suspend** all `sleep`. logind turns that into suspend-then-hibernate (hibernating after 2 h, and never on AC), or plain suspend on a machine that cannot hibernate.
- **While an update installs**, it holds logind off shutting down and off the lid (`shutdown:handle-lid-switch`, never `sleep`, which would refuse the menu's Suspend and UPower's hibernate too). The lid binding (`nova-system-lid-close`) sees a held lid and locks and turns the panel off, as for `lid lock`.
- **Settings → Battery chooses three things over that**, each through a `nova power` command:
  - `lid`: what a closed lid does plugged in: sleep, or lock and keep running with the panel dark;
  - `button`: what the power button does: the system menu, sleep or shut down; the session's, so no root;
  - `hibernate`: the 2 h, as 1 to 24 hours, or never.
- `lid` and `hibernate` are drop-ins in `/etc/systemd/{logind,sleep}.conf.d/`, written by `nova-power-sleep-apply` through polkit.
- **At UPower's last 2%** the computer hibernates outright (`/etc/UPower/UPower.conf.d/10-nova.conf`): sleeping to RAM first is what would empty it.
- **The TPM key-provisioning units are skipped** unless `nova.tpm2` is on the kernel command line: an encrypted Nova disk opens with its passphrase, never the TPM, and they cost about four seconds of every measured boot.

### Unused: the screensaver and the lock

- The shell's idle service (`src/shell/plugins/services/idle`) starts the screensaver after `idle.screensaver` seconds (three minutes by default) and locks after `idle.lock` (five). Both are in `shell.json` and in Settings → Lock Screen.
- The screensaver (`nova-screensaver`) opens a foot window on each display, where `nova-screensaver-run` has `nova-screensaver-effect` (`src/screensaver`) play the wordmark through Nova's six text effects, in the theme's accent and its border's second color, until a key, the mouse, the window losing focus or the lock ends it.

### Caffeine

Caffeine (`nova caffeine`, the bar's coffee cup, Super+Ctrl+I) is one switch, `$XDG_RUNTIME_DIR/nova/caffeine`, so it never outlives the session. While it is there:

- the idle service does nothing;
- on a laptop it also holds a logind `handle-lid-switch` inhibitor, and the Hyprland lid binding goes through `nova caffeine close`, which turns the panel off with DPMS instead of locking;
- the P1's 5G modem, while its radio is on, is kept out of runtime suspend, as root through `nova-caffeine-modem` (polkit).

On battery it ends at 10%, from the idle service, and a lid closed meanwhile then locks and sleeps.

### Hardware profiles

Hardware profiles live in `data/hardware/`. `models` maps DMI fields to a profile: a line is one or more `field=pattern` conditions (`sys_vendor`, `product_name`, `product_version`, `product_family`, `board_vendor`, `board_name`), tab-separated, and a bare pattern is `product_version`'s. `nova-hw-detect` and the Hyprland loader both read it, the same way. A profile holds:

- `packages`: Arch packages the installer adds (microcode, firmware, drivers);
- `etc/`: modprobe, NetworkManager and boot-entry drop-ins, which cannot apply to one model from `/usr`. `nova-hw-apply` copies them into `/etc` from a pacman hook on every install and upgrade of `nova`, and removes the ones a release dropped.

Session-side settings check the model themselves: a uwsm `env.d` file and a `default/hypr/hardware/<profile>.lua` module.

A speaker tuning (`data/audio/tunings/<name>/`, matched by DMI) needs the audio server, so it is turned on at login: `nova-speaker-tuning-auto.service` runs `nova audio tuning auto`, which applies it the first time, keeps it current after updates, and leaves it off once someone has turned it off.

A fault of one computer is not a profile's: it is a [patch](patches.md).

## Packaging and releases

### Packages

Built only in CI ([packaging.md](packaging.md) has how each is kept up to date):

| Package | Contents |
|---|---|
| `nova` | everything in this repo |
| `nova-keyring` | the key the `[nova]` repository is signed with |
| `linux-nova`, `linux-nova-headers` | Arch's kernel configuration with the BORE scheduler, `HZ_1000` and the x86-64-v3 instruction-set baseline |
| `nvidia-open-nova` | NVIDIA modules prebuilt for `linux-nova` |
| `limine-snapper-sync`, `limine-entry-tool` | rebuilt from the AUR |
| `whisper-cpp` | dictation's speech engine, with its own copy of ggml: Arch's links Arch's ggml, which breaks it as it moves on |
| `hyprland` | Arch's Hyprland with Nova's patch for `xwayland:scale`: X11 apps the same size on every display |

**Fallback kernel:** Arch's `linux-lts` + `nvidia-open-lts` stay installed as the fallback boot entry.

### A release

A release (`v1.0.0-beta.1`, …) is a GitHub release with:

- `nova-usb`, for making the stick (below);
- the ISO's `.sha256`;
- `release.toml`, which pins the Arch Linux Archive date the release was tested against and says where its packages are.

The rest is in the release's folder of the `nova-packages` bucket on Cloudflare R2 (`https://nova-packages.piserver.stream/<tag>`), which keeps the newest release, and the newest final one:

- the signed `[nova]` repository;
- the installer ISO (`installer/iso`, built by `tools/build-iso`), about 3 GB, with every package any install can need on it (`nova/repo`, the `[nova-offline]` repository, from `tools/offline-repo`), so that it installs without a network;
- a `.sig` by the repository key for each file read without pacman (`release.toml`, the ISO's `.sha256`, `nova-usb`), which `nova update` and `nova-usb` check against the key alone.

[releasing.md](releasing.md) has the two-week cycle and the signing key.

### The stick

`nova usb` (`installer/nova-usb`, also on every release page, so it runs on any Arch-based system) writes a GPT stick of its own instead of the raw ISO:

| Partition | Holds |
|---|---|
| 1, `NOVA` | a FAT EFI partition holding the ISO's files, which archiso boots from as they are (it finds itself by a `/boot/<uuid>.uuid` file, not by the disk). Among them, `nova/repo/` holds every package any install can need (`nova-install --list-packages`, with their dependencies) and their signatures, as the `[nova-offline]` repository |
| 2, `NOVA-DATA` | only when something is carried (the SSH keys, and the files and folders picked from the home): LUKS2, btrfs, and `carry/` with one `tar.zst` per item, `SHA256SUMS` and `manifest.json`. `nova-install --unlock` opens it before the questions; the install puts each item back into the new home once the account exists |

- **One question per screen:** `nova usb` and the stick's installer ask with gum, under the wordmark, in a column down the middle. `installer/ui.bash` holds the prompts both use, in the terminal's sixteen colours named by what they mean, and the glyphs stay within the console fonts' code page 437 set.
- **The stick's console:** on a Linux console, and only there, the installer sets Nova's sixteen colours (`ESC ] P`) and a Terminus font sized to the screen, and gives the kernel's colours back as it leaves (`ESC ] R`). A terminal's colours are its owner's.
- **One file:** the released `nova-usb` is one file, so `tools/inline-ui` writes `ui.bash` and the wordmark into it.
- **memtest86+** is in a stick's boot menu.
- **One root step:** everything that writes a disk runs in one root step (`nova-usb write`), which checks the device again before touching it. `tests/usb/stick-test` runs it against a loop device in CI.

### A portable stick

A portable stick is Nova installed on a USB disk of 32 GB or more, to start any PC from (`nova-install --portable`).

**How `nova usb`'s Portable makes one:** the release's own installer does it. Its root step (`nova-usb write-portable`):

1. mounts the ISO's live system read-only under a tmpfs overlay, with this computer's `/dev`, udev and network but no `efivarfs`;
2. stages what is brought as the same `carry/` a NOVA-DATA partition holds, at `/run/nova-carry`;
3. runs `nova-install --portable <disk>` in it, on the terminal.

The live stick's `nova-install-start` offers the same when a USB disk sits beside it.

**What makes it portable:**

- Arch's `linux` (no x86-64-v3), both microcodes, the Intel and AMD drivers and NVK. NVIDIA cards run on nouveau, since `nvidia-utils` blacklists it and the open modules drive nothing before Turing.
- An initramfs without `autodetect` and `kms` (about 60 MB rather than 220), no swap file and no `resume=`, and hibernation off in a sleep.conf drop-in.
- `SKIP_UEFI=yes` in `90-nova-install.conf`, so `limine-install`, the `limine` package's hook after an update included, writes Limine only to `EFI/BOOT/BOOTX64.EFI` and never into a computer's NVRAM.
- `/etc/nova/portable`, which keeps the model's `/etc` files (`nova-hw-apply`), its packages (`nova update`), an undervolt (`nova-undervolt.service`, `nova power undervolt`) and patches off. What reads the model at run time (Hyprland's and uwsm's per-model files, the P1's power services) still does, on whichever computer it starts.

An encrypted one is opened as `nova-usb-root` while it is made, since the computer making it may be a Nova with its own `nova-root`, and boots as `nova-root`.

### Every release is installed before it is published

`tests/install/run`:

1. makes a stick from the ISO as `nova usb` would;
2. installs with no questions (`nova-install --answers`) onto a blank disk in a KVM machine;
3. boots the result, and has a probe check the lock, Hyprland, the shell, greetd and `nova doctor` from inside.

### Updating

`nova update` moves a system to the newest release:

1. It points the pacman mirror at the release's Arch date and the `[nova]` repository at its URL.
2. It updates the keyrings.
3. It runs `pacman -Su`, with a snapper snapshot before and after.

A failed step puts the old files and package databases back. Afterwards it checks that every kernel's boot image was rebuilt. Before any of it, it makes sure `/` and the boot partition have room for the update, which a full disk would stop halfway.

Pre-releases (the candidates) reach only systems that opted in (`nova update --candidates on`) or are already on one.

### Not redistributed: Chrome and VS Code

Chrome and VS Code are built on the machine from their AUR recipes, which download from the vendors (`nova apps install`).

- They are outside the release, so `nova update` ends by rebuilding whichever is behind the AUR (`nova apps update`). The bar's update badge shows when one is, with a notification once.
- One that will not build or go in leaves Nova updated: the update finishes with problems (status 4, state `problems` for Settings), naming the app.
- A recipe runs as the user and anyone can push to the AUR, so the commit each was built from is kept in `~/.local/state/nova/aur/`.
- A new release is built unasked only when its recipe changed nothing but `pkgver`, `pkgrel` and checksums.
- Any other change is shown in the terminal and built only on a yes; under `--yes` that app waits.
- The first build on a machine takes the recipe as it is.

## Code rules

### Bash

- `#!/bin/bash` and `set -euo pipefail`
- 2-space indent
- functions over copy-paste
- shellcheck-clean (`make lint`)
- each helper does one thing
- errors go to stderr with a non-zero exit
- no `sudo` inside helpers; privileged actions go through polkit (`pkexec`). The exceptions run in a terminal and say so: `nova power switch`, `nova apps install` (and the launcher's Uninstall) and `nova usb`
- a heredoc's delimiter is quoted (`<<'EOF'`) unless its body must expand, and then the body holds no backticks, which would run ([P1 fact 14](hardware/thinkpad-p1-gen4i.md))
- code that runs as root and writes into a home takes the account from `SUDO_USER` and gives back what it creates there: under `sudo`, `$HOME` is `/root` ([P1 fact 47](hardware/thinkpad-p1-gen4i.md))

### QML

qmllint-clean. Logic lives in singletons that can be tested against fixtures.

Three traps that load without an error and draw nothing:

- no `property var data` or `property string state` on an Item root: both shadow Item properties, and `data` is where children go;
- inside `Type { }`, a name the type declares means the type's own property, so `Bar { shell: shell }` assigns the bar's empty `shell` to itself. Pass an outer object in under another name (see the bar's Loader in `shell.qml`);
- Nerd Font icons in the private-use range (U+E000-U+F8FF) are often lost when a tool rewrites a file; `tests/unit/cli/menu.bats` catches an empty one in the menu.

### Rust

- One Cargo workspace at the root.
- `cargo fmt`, `cargo clippy -D warnings`.
- No unsafe beyond FFI that std lacks (the governor's signal handlers, libsystemd).
- std only, unless a dependency clearly pays for itself. D-Bus and the journal go through `nova-sd` (`src/sd`), libsystemd's own, which every system has.
- Tools a user waits on (the theme engine, the power manager) are Rust, and so is what runs as long as the session does (`nova-sessiond`): a watcher in bash keeps a shell and what it waits on (socat, journalctl, jq) in memory for hours, where one in Rust is a thread asleep in `poll()`. Glue that mostly runs other programs, and then ends, stays bash.

### Tests

| Test | What it does |
|---|---|
| `tests/unit/` | bats tests for the helpers; `make test` runs them |
| `cargo test --workspace` | the Rust programs' tests; `nova-sessiond`'s against stand-ins: a private D-Bus (`dbus-daemon`) with a logind and a udisks of the test's own, a Hyprland socket, and journal files written by `systemd-journal-remote` |
| `tests/qml/run` | runs the shell's logic tests (the plugin registry against the real plugin index) offscreen under Quickshell, from an installed tree |
| `tools/qml-smoke` | opens the shell's windows offscreen from the same tree, and fails on any runtime QML warning, which qmllint cannot see |
| `tools/shell-smoke` | starts the whole shell under a headless sway, summons its windows over IPC and checks that it locks at startup; in CI only |
| `tools/xwayland-game-check` | an X11 game's fullscreen modes and mouse in a nested Hyprland at the ThinkPad P1's panel and X11 scale; by hand, for each new build of `packaging/hyprland` |
| `tests/usb/stick-test` | writes and restores a real stick on a loop device, as root; in CI only |
| `tests/install/run` | installs a release in QEMU and boots it; in the release workflow only |

### Commits

Imperative subject, a body that explains *why*.
