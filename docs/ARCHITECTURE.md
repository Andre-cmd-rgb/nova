# Nova architecture

Nova is a small Arch Linux desktop: Hyprland, a Quickshell shell, one `nova` command, and a power governor. It ships as **one package, `nova`**, installed into a plain Arch system.

This document is the contract every component follows. Read it before adding code.

## Components and where they install

| Source | Installs to | What it is |
|---|---|---|
| `src/shell/` | `/usr/share/nova/shell/`, `/usr/lib/nova/libnova_shell_alloc.so` | The Quickshell shell: bar, lock, menu, notifications, OSD, panels, Settings; and its allocator and Qt buffer settings (Rust), a library preloaded into Quickshell alone |
| `src/cli/nova` | `/usr/bin/nova` | Dispatcher: `nova <group> <verb> [args]` |
| `src/cli/bin/` | `/usr/lib/nova/bin/nova-<group>-<verb>` | Helper commands (bash), one per file |
| `src/power/` | `/usr/lib/nova/bin/nova-power`, `/usr/lib/nova/nova-powerd`, `nova-undervolt`, system units, udev rules, sleep hooks | Nova's power governor: the policy (bash) and the governor (Rust), tuned for and so far started only on the ThinkPad P1 Gen 4i; and the CPU undervolt (Rust), for any Intel laptop whose firmware allows one |
| `src/patch/` | `/usr/lib/nova/bin/nova-patch`, `/usr/lib/nova/nova-patch-apply`, a polkit action, `nova-patch-ram.service` | Patches: fixes for one computer's faults (bad memory, a device's quirk), kept across reinstalls by export and add; see [patches.md](patches.md) |
| `src/airdrop/` | `/usr/lib/nova/bin/nova-airdrop`, `/usr/lib/nova/nova-airdropd`, `nova-airdrop-bell`, `nova-airdrop-radio`, `nova-airdrop-apply`, a polkit action, `nova-airdrop@.service`, `nova-airdrop-bell@.service`, `nova-airdrop-bell-wake@.service` | AirDrop, receiving from and sending to iPhones nearby: the receiver and sender, its command and its doorbell (Rust), and the helper that lends it the Wi-Fi card and takes it back ([airdrop.md](airdrop.md)) |
| `src/calendar/` | `/usr/lib/nova/bin/nova-calendar-sync`, `/usr/share/nova/calendar/google.json` | The Calendar's two-way sync (Rust, HTTP and TLS through libcurl): iCloud, Google and CalDAV accounts, and iCal subscriptions, in step with the files the shell's Calendar reads; run by the shell while it syncs, never resident ([calendar README](../src/shell/plugins/calendar/README.md)) |
| `src/apps/` | `/usr/lib/nova/bin/nova-apps-*`, `/usr/lib/nova/nova-apps-apply`, a polkit action, `/usr/share/nova/apps/`, the App Center's desktop entry and icon | The App Center's catalog (Rust) and its helpers, which `nova apps` runs too; the window is the shell's (`plugins/store`). `/usr/share/nova/apps/recipes` says what an Arch app installs with it, what is done as root once it is in, and where it is offered from first; `nova-apps-apply` reads it from there alone, root-owned, takes only package names and one fixed step (turning on a packaged socket) from it, never puts an account in a group, and removes with an app only the extras that no other app's recipe names and nothing that stays needs or may use (pacman lists an optional dependency in no Required By). `tools/apps-recipes-check` says when an optional dependency of a front-page app has no decision (a release stops on it, against the snapshot it pins; CI warns, on today's Arch); see [apps.md](apps.md) |
| `src/iphone/` | `/usr/lib/nova/nova-iphone-notifications`, `/usr/lib/nova/bin/nova-notification-iphone`, `nova-iphone-notifications.service` (user) | iPhone notifications: an iPhone's notifications shown as Nova's, through Apple's Notification Center Service over Bluetooth LE (Rust, D-Bus through `nova-sd`), and its command ([iphone.md](iphone.md)) |
| `src/memory/` | `/usr/lib/nova/nova-memory-pressure`, `nova-memory-pressure.service` (system) | The kernel's reserve while memory is short (Rust, root): asleep on a trigger on `/proc/pressure/memory`, it raises `vm.watermark_scale_factor` to 125 while tasks stall on memory and puts the boot's lean value back after five quiet minutes; `nova-memory-reserve` (`data/systemd/`) sets that lean value at boot (see "The memory shown in use", under [Commands](#commands)) |
| `src/dictation/` | `/usr/lib/nova/nova-dictationd`, `nova-dictationd.socket` and `.service` (user) | Dictation's speech to text (Rust): NVIDIA's Parakeet on the CPU, through whisper-cpp's `libparakeet` (opened with `dlopen`, so that the package builds and tests without it; one of another release than `engine.rs` declares is no engine, as its soname would not tell). systemd holds the socket (`$XDG_RUNTIME_DIR/nova/dictation.sock`) all session and starts the daemon at the first dictation; it ends two minutes after the last one, at once before sleep or under memory pressure, so that its 700 MB model is in memory only while it is of use. One connection is one dictation (`server.rs`): `pw-record` on a pipe, never a file; heard while it is said, at each pause and every three seconds of voice (`dictation.rs`), a silence over 0.6 s heard as 0.6 s, so that a pause to think gets no full stop; a sentence settled once two hearings agree on it with words after it (`settle.rs`), and where they never do (a television behind the voice), the oldest part settled by force once 45 s are unsettled, never the newest 15 s, so that a hearing stays short; the words tidied (fillers, stutters, "scratch that": `tidy.rs`) and spelt the user's way (`~/.config/nova/dictation/vocab.toml`: `vocab.rs`), answered to the shell's pill (`src/shell/plugins/dictation`) and kept in `$XDG_RUNTIME_DIR/nova/dictation/last`. On battery the end is heard with power-profiles-daemon's performance profile held. `examples/compare.rs` measures the words and the cost against one hearing of a whole recording |
| `src/preview/` | `/usr/lib/nova/nova-previewer`, a D-Bus service file | Quick Look's front (Rust): Files asks it for a preview with Space, under the name GNOME Sushi had, and it describes the file through GIO and hands it to the shell's window (`plugins/preview`); D-Bus starts it, and it quits once the preview has been closed half a minute |
| `src/account/` | `/usr/lib/nova/bin/nova-password-change`, `/usr/lib/nova/bin/nova-keyring-migrate` | The account's password and keyring (Rust): Settings' Change Password, which answers passwd's prompts on a terminal of its own so that pwquality and the login keyring take part, and the move of a passwordless keyring into the login keyring that `nova doctor` offers (`nova-keyring-migrate.service`, in `data/session/`, runs it at the next unlock) |
| `src/theme/` | `/usr/lib/nova/bin/nova-theme` | Theme engine (Rust): palettes, templates, theme and background switching, pickers |
| `src/screensaver/` | `/usr/lib/nova/bin/nova-screensaver-effect` | The screensaver's text effects (Rust): a text played in a terminal, one effect after another |
| `src/session/` | `/usr/lib/nova/nova-sessiond`, `nova-sessiond.service` (user) | What the session watches for as long as it runs, in one small process (Rust): the apps keeping the screen awake (`org.freedesktop.ScreenSaver`), the lock before sleep, logind's Lock for the session (`loginctl lock-session` and `lock-sessions` lock the screen; its Unlock is not followed, since any program of the user's may ask logind for one, and the shell sets the session's LockedHint as the lock is: `plugins/lock/LockedHint.qml`), the wall clock moving in a way the shell's timers cannot follow (a wake, a clock set, a new time zone: `clock.rs`), "… quit unexpectedly" with Reopen for an app a crash took away, the clamshell passes and the X11 scale as displays come and go, removable drives mounted while somebody has unlocked (an encrypted one's passphrase asked on the shell's card: `prompt.rs`, the shell's `plugins/prompts`), the questions of a Bluetooth pairing the user picked, on that card (Nova's BlueZ agent, there only while `nova-bluetooth-device` pairs, for that device alone), and printing: while a job of the user's is queued, the printers holding it are watched (`nova-printers watch`) and a notification says once what the user must do (no paper, a jam, a cover open, no ink, a printer that cannot be reached or has stopped), with Open Printers (Settings → Printers), and a held job's user name and password are asked on the card (`nova-printers authenticate`); CUPS's signals come through a subscription `nova-printers subscribe` makes and renews; gnome-keyring's questions (a keyring that did not open at login, a new one's password), as gcr's system prompter `org.gnome.keyring.SystemPrompter`, on the card, the password sent back in gcr's secret exchange (`exchange.rs`, libgcrypt's); and the file picker apps get from the desktop portal (`org.freedesktop.impl.portal.desktop.nova`, its FileChooser): the shell's `plugins/file-picker` window, asked over `$XDG_RUNTIME_DIR/nova/file-picker.sock`, with GTK's portal where no shell answers. The same program, by the name it is run under, is `nova-pinentry`, gpg-agent's passphrases on the card (Arch's `/usr/bin/pinentry` runs it through `/etc/pinentry/preexec` while a Nova shell listens), `nova-share-picker`, what an app sharing the screen may show (a screen, a window, an area drawn with slurp), which xdg-desktop-portal-hyprland runs as `~/.config/hypr/xdph.conf` says (the daemon writes that file when it is missing), `nova-sim-pin`, mobile-data's SIM PIN to ModemManager, read from the standard input so that no process's arguments show it, and `nova-tray-quit`, the tray menu's Quit: it finds the app behind a tray icon (its StatusNotifierItem's connection, that process's cgroup) and ends its own systemd unit, only when the icon is the app that unit was started for, or else only its own processes in a unit that holds more (an app started from a terminal, a link opened from the browser, a game Steam started), and refuses for a service and what it let go of, the shell or the session, known by what they are (`trayquit.rs`) |
| `src/session/launch/` | `/usr/lib/nova/bin/nova-launch` | How every app is started (Rust, only libsystemd): `nova-launch -- <command>` or `-- <id>.desktop[:action] [files]` makes a transient scope `app-<desktop>-<app>-<hex>.scope` in `app-graphical.slice` over the user bus (`StartTransientUnit`, waiting for the job) and then becomes the app, as `systemd-run --scope` does, with no daemon; the entry's Exec is read as the Desktop Entry Specification says (field codes, `Terminal` through `xdg-terminal-exec`, `Path`, actions), and one that asks for the discrete GPU (`PrefersNonDefaultGPU`) starts through `nova-power prefer`. Apps it starts get `GTK_USE_PORTAL=1`, so a GTK 3 app asks Nova's file picker through the portal (one started another way, by D-Bus, an autostart entry or the shell's own opens, keeps GTK's own picker); the session as a whole never has it, since GTK 3 then waits on the portal as it starts, with no time limit, and the shell (Qt's GTK theme starts GTK 3) has to lock the screen at login whatever the portal does. With systemd out of reach the app starts anyway, without a scope. Hyprland's keys, the menu, the App Center, the `nova-launch-*` helpers and the crash notification's Reopen all run it |
| `src/session/xwayland/` | `/usr/lib/nova/bin/Xwayland` | `nova-xwayland` (Rust): what Hyprland runs as Xwayland, which sleeps on the X sockets and becomes Xwayland with the first X11 app, its scale and theme in place before the app is let in (see "No X server until an X11 app", under [Commands](#commands)) |
| `src/sd/` | – (in the programs that use it) | `nova-sd`, the crate through which Nova's Rust reaches D-Bus and the journal: libsystemd's sd-bus and sd-journal, by FFI |
| `theme/` | `/usr/share/nova/{themes,templates,wordmark}/`, `/usr/share/icons/Nova/` | Palettes, the per-app templates, the wordmark background template; Nova's cursor theme (`theme/cursor`, see [The cursor](#the-cursor)) |
| `data/hypr/` | `/usr/share/nova/default/hypr/` | Hyprland defaults (Lua), loaded by the user's `~/.config/hypr/hyprland.lua` |
| `data/session/` | `/usr/lib/systemd/user/`, `/etc/pam.d/`, `/etc/sudoers.d/`, `/etc/xdg-desktop-portal/`, `/usr/share/xdg-desktop-portal/portals/`, `/usr/share/dbus-1/services/`, `/usr/share/uwsm/env.d/`, `/usr/share/nova/{session,greeter}/` | greetd (a config template the installer renders), the greeter, PAM, uwsm env, session guard, keyring, the desktop portals (gnome-keyring's for a Flatpak app's secrets, Nova's own file picker, `nova.portal`) |
| `data/boot/` | `/etc/mkinitcpio.conf.d/`, `/etc/limine-entry-tool.d/`, `/usr/share/snapper/config-templates/`, pacman hooks | Boot chain drop-ins and the boot-entry guards; every update of `nova` builds the boot entries again (see [Hardware profiles](#hardware-profiles)), so a change to a drop-in takes effect at the next restart |
| `data/systemd/` | `/usr/lib/systemd/user/`, `/usr/lib/systemd/{logind,sleep,system,oomd,zram-generator}.conf.d/`, `/usr/lib/{sysctl,modules-load,tmpfiles}.d/`, drop-ins for `systemd-tpm2-setup*` | Session user units; logind and sleep policy; PID 1's restart without a hardware watchdog (`RebootWatchdogSec=off`); the memory setup (zram, the reclaim sysctls and huge pages, systemd-oomd); the ntsync module Wine and Proton use, loaded at boot; the TPM's setup only with `nova.tpm2`; the package autostarts Nova turns off (masked); the order that holds XDG autostart apps until the boot lock is secure (`app-.service.d/`) |
| `data/network/` | `/usr/lib/nova/bin/`, pacman hooks, `/usr/lib/systemd/resolved.conf.d/`, `/usr/lib/NetworkManager/conf.d/`, `/usr/lib/ModemManager/fcc-unlock.d/` | Networking: the Wi-Fi rules of the computer's country, ModemManager with every FCC unlock it ships, name resolution through Avahi and no LLMNR, and captive portal checks |
| `data/bluetooth/` | `/usr/lib/nova/bin/nova-bluetooth-le`, `/usr/lib/nova/nova-bluetooth-le-apply`, a polkit action | Bluetooth LE on or off (`ControllerMode` in `/etc/bluetooth/main.conf`) |
| `data/mime/` | `/usr/share/applications/mimeapps.list` | Which app opens a file nobody picked one for: photos in Loupe, video and music in mpv, text in VS Code |
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
| `site/` | – (GitHub Pages) | The site: the landing page, real screenshots of Nova (`site/images/` and `docs/images/` from `tools/screenshots`) over CC0 photos (`site/wallpapers/`, their adaptive palettes from `tools/site-palettes`, their credits rendered to `credits/` from `site/wallpapers/CREDITS.md`), where a photo picked shows Nova over it and puts the page in its palette; and a page for each user doc that `tools/build-site` renders with cmark-gfm in its look (GitHub's heading ids; a link between two docs made one between their pages, a maintainer doc or a source file linked on GitHub), every theme's colors from `theme/palettes`, and the menu's own code (`MenuModel.js`, `Calculator.js`, `menu.jsonc`) for the landing page's Super+Space. Plain HTML, CSS and JavaScript, fetching nothing from another site; its font is Nova's, cut by `tools/site-fonts`. `.github/workflows/pages.yml` builds and publishes it from main |

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
- **What runs at rest earns its place.** Nova keeps every feature and holds little memory for them: a window is built when it opens and freed when it closes; a watcher waits on an event (a D-Bus signal, a socket, the journal's descriptor), never a clock; the session's watchers are one Rust process (`nova-sessiond`), not one interpreter each; a package's autostart runs only if Nova chose it (`data/systemd/install.mk`); a daemon woken for a moment is let go after (fwupd, by `nova-firmware-job`). The install test checks the autostarts and holds the session at rest to a memory budget (`tests/install/probe`; the budgets are its 4 GB machine's, and on a computer with more the probe only says the figures).
- **The memory shown in use is accounted for.** "In use" is `MemTotal` less `MemAvailable`, in `free`, btop, fastfetch and Nova's Memory readout alike, and the kernel's `MemAvailable` leaves out more than what programs hold: a reserve it keeps free (the zones' high watermarks, and what lower zones keep from higher ones), half of the page cache and of the reclaimable kernel memory up to the low watermarks, and the free pages on the per-CPU lists, which follow the low watermark and are not in `MemFree`. `nova-doctor-memory` prints every part, summing to the figure, from `/proc/meminfo` and `/proc/zoneinfo`; `nova doctor --bundle` and the install test carry it.
  - **The reserve is lean at rest and full while memory is short.** `vm.watermark_scale_factor` sets the gap between the kernel's min and low watermarks, the head start background reclaim has on a burst, as a share of memory. With swap on zram a head start pays, and Nova's 1.25% stays on a computer up to 8 GB (100 MiB there). On a 32 GB one the same share was 400 MiB, and with it 0.86 GiB kept free, 0.46 GiB of cache counted as unavailable and up to 0.46 GiB on the per-CPU lists: about 2 GiB of the 3.8 GiB the ThinkPad P1 showed in use at rest, where nothing is reclaimed and the head start is not used. So at rest the gap is the same 100 MiB above 8 GB (factor 31 at 32 GB), never under the kernel's own 0.1%: `nova-memory-reserve`, run by a drop-in before `systemd-sysctl`, writes `/run/sysctl.d/90-nova-memory-reserve.conf`, and a value of the administrator's in `/etc/sysctl.d` still wins. While the kernel is reclaiming, the full 1.25% is back: `nova-memory-pressure` (`src/memory`, 0.3 MB, asleep on one descriptor) holds a trigger on `/proc/pressure/memory` that wakes it in any second with tasks stalled on memory for a tenth of it, writes 125 then, and the boot's value again after five minutes without such a second. It is not started where the boot's value is the full one (memory up to 8032 MiB, `ConditionMemory=`), ends at once where the value is not Nova's, and ends the first time it finds one that is neither the boot's nor its own raise (`sysctl -w`, a file applied by hand), saying so in the journal: an administrator's value is never raised or put back. It runs with `CAP_SYS_RESOURCE` alone, which its trigger's one-second window takes; the sysctl takes root's uid. Pressure in a memory-capped cgroup (a stall inside a service's `MemoryMax=`) counts too and raises the reserve, which is the safe side. Where it is not running (masked, failed, a kernel without pressure information) the lean reserve stays under pressure too, the fixed 100 MiB below, still ahead of the kernel's own. Ended while the full reserve is in force, it leaves that in force; systemd starts it again (`Restart=on-failure`), and the mark in its runtime directory tells it the 125 is its own raise and not an administrator's, so the five minutes begin again. A value something puts back meanwhile (pacman's hook runs `systemd-sysctl` when a package brings a sysctl file) is raised again with the next second of pressure.
  - **Measured, 2026-11-21**, in a VM on Nova's kernel (7.2.11) with zram and Nova's sysctls: sixty seconds of a workload holding 1.25 times the memory (programs of 192 MiB touching a fifth of it, 256 MiB asked for every two seconds, a frame every 8 ms, a file read at 64 MiB/s), three runs a setting, medians. On four CPUs, at 4 GB the 1.25% gap (48 MiB) against the kernel's own (16 MiB) made 868 direct-reclaim stalls against 2196 and 18 frames more than 16 ms late against 35; at 8 GB (99 against 16 MiB) 2748 against 4862 and 47 against 59. With a 32 GB machine's zones and watermarks (the memory beyond 8.5 GiB set aside in an untouched huge-page pool), eight CPUs and each burst asked for by eight processes at once: the full 401 MiB gap made 2228 stalls, 31 late frames and a frame's lateness of 3.6 ms at the 99th percentile; 200 MiB 2367, 50 and 4.7 ms; 100 MiB 3073, 43 and 7.2 ms; the kernel's own 32 MiB 4641, 42 and 9.2 ms, with one run at 36 ms and a burst that took 4.9 s. That difference between 100 MiB and the full gap is what `nova-memory-pressure` is for. The three in one sitting, turn and turn about, on a quieter laptop: the full gap made 2381 stalls, 33 late frames and 2.5 ms; the fixed 100 MiB 3232, 33 and 5.0 ms; 100 MiB with `nova-memory-pressure` running 2565, 37 and 3.6 ms, its minute taking in the seconds before the raise. In seven such runs the factor read 125 between 0.05 and 0.42 s after the first program stalled in direct reclaim (once before any had), and, put back to the boot's value by hand ten seconds later, 0.39 s after that. A clean rc.14 at rest in the install test's machine given 32 GB showed 2233 MiB in use with the fixed 1.25% (587 held by programs and the kernel, 1646 kept aside) and 1244 MiB with the reserve sized (567 and 677). The harness is not in the tree; the numbers are a builder's, on a laptop in use.
- **No X server until an X11 app.** Hyprland starts Xwayland with the session (its lazy mode is a to-do upstream): 26 MB, 64 MB resident, and 6 MiB of graphics memory for a desktop with no X11 app. It runs `Xwayland` from `PATH`, where Nova's commands come first, so it runs `nova-xwayland` (`src/session/xwayland`, installed as `/usr/lib/nova/bin/Xwayland`), which sleeps on the X sockets Hyprland handed it (0.4 MB) and becomes Xwayland with the first connection.
  - **The first app finds its settings.** Toolkits read the scale once, as they start (Qt and SDL `Xft.dpi` from the resources, Chrome and Electron the XSETTINGS through GTK). Xwayland serves the apps' sockets only once a window manager owns `WM_S0`, and Hyprland starts its own when Xwayland writes that it is ready (`-displayfd`). The starter gives Xwayland a socket for its settings (`-initfd`, `$XDG_RUNTIME_DIR/nova/xwayland-N.init`), keeps the word back, runs `nova-hyprland-x11-scale --new-server` through that socket (which starts xsettingsd again for the new server, whatever the last one left it doing, and says so), asks the X server until `_XSETTINGS_S0` has an owner when xsettingsd is coming, and then passes the word on; where the socket cannot be made, the word goes first and the settings pass after. What it runs holds none of what Hyprland handed over (the apps' sockets, the window manager's, the ready pipe). `-noreset` keeps the server from starting over when `xrdb`, its only client until then, leaves. Measured in a nested Hyprland at the P1's panel and X11 scale 2: the first client connected after 141 to 209 ms and found `Xft.dpi` 192, the XSETTINGS scale 2 and the cursor's theme and size in 15 runs of 15, a GTK 3 window had scale 2 and a Qt 6 one a pixel ratio of 2 in 3 of 3 each, and two apps started at once both did.
  - **While it sleeps** (`xwayland-N.wait`), `nova-hyprland-x11-scale` writes the settings down and connects to nothing; `nova-xsettings.service` comes with the X server and ends with it (status 1, not a failure), with no restart timer that would ask a sleeping server every two seconds: one that failed is started again with the next X server. Both marks go whenever a starter begins on that display, plain or Nova's, and before any fallback to plain Xwayland, so one left by a starter killed asleep or by an X server that ended is gone with the next. Anything else that runs `Xwayland` (gamescope's own) is not Hyprland's child and gets Xwayland unchanged, whatever its environment says: the parent is asked first. Under Hyprland, `NOVA_XWAYLAND=eager` in the session's environment starts the server with the session, its settings still first; gamescope started in that session inherits the variable and still gets plain Xwayland.
- **Running apps are reached through `nova-session-pgrep`.** It finds, or with `--signal` signals, only the user's processes started with this `HOME` and `XDG_RUNTIME_DIR`. Use it for every lookup by name, never a bare `pgrep` or `pkill`. A second session of the same user is a different session: the tests, `tools/screenshots`, and a nested Hyprland each have a home and runtime folder of their own. A bare lookup by name once let a test recolour the user's terminals and end their clipboard's watchers. `tests/unit/cli/session-pgrep.bats` fails on a new bare lookup.
- **What belongs to the computer is written only from the account's own home.** That covers the greeter's mirror in `/var/lib/nova/greeter`, and Chrome's colour policy made from it.

### Environment

`NOVA_PATH=/usr/share/nova`. Code must never hard-code `/usr/share/nova` where `$NOVA_PATH` is available. That way tests can point it at the source tree.

### Locations

| Kind | Path | Holds |
|---|---|---|
| User config | `~/.config/nova/` | `shell.json`, `menu.jsonc`, `themes/`, `templates/`, `backgrounds/`, `hooks/`; `calendars.json`: the calendar's accounts and calendars, with no secret in it |
| | `~/.config/nova/dictation/vocab.toml` | dictation's spellings: words Parakeet writes another way (`nova dictation vocab`) |
| | `~/.config/nova-<plugin>/` | a plugin's own settings (`nova-batterylife`, `nova-screentime`, `nova-mobile-data`) |
| User state | `~/.local/state/nova/` | `current/`, `rendered/`, `backgrounds/`, `aur/`; `monitors.json`: the displays as Settings keeps them; `input.json`: the keyboard's layouts and the pointer as Settings keeps them; `notifications.json`: Do Not Disturb, and its schedule's last turn; `calendar.json`: how far the calendar's reminders have been looked at; `calendar-sync/`: what each calendar's server last had, and how each account's last sync went; `calculator.json`: the Calculator's history, and Basic or Scientific, the angle's unit and the history pane as last left; `adaptive`: the adaptive theme's Auto, Dark or Light; `airdrop/`: the certificate the AirDrop receiver shows to senders, made at its first use; `welcome-pending`: a new account's, from Nova's skel, until it closes the welcome |
| | `~/.local/state/nova-<plugin>/` | a plugin's history |
| User data | `~/.local/share/nova/calendar/` | the calendars: `calendar.ics`, the one on this computer, and one file for each account's calendar and each subscription |
| | `~/.local/share/nova-dictation/` | the speech model, downloaded at dictation's first use |
| | `~/.local/share/flatpak/` | Flathub's apps, as the App Center installs them: flatpak's own |
| User cache | `~/.cache/nova/adaptive/` | the adaptive theme's palettes, by the photo's path, size and time |
| | `~/.cache/nova/apps/` | the App Center's catalog, its list and the apps' pages, the icons of Arch's catalog as PNGs, and the apps' pictures |
| System config | `/etc/nova/power.conf` | on a P1 Gen 4i, optional tunables |
| | `/etc` drop-ins from the hardware profile | listed in `/var/lib/nova/hardware-files` |
| | `/etc/nova/patches/` | this computer's patches; their `/etc` files are listed in `/var/lib/nova/patch-files` |
| System state | `/var/lib/nova/` | `greeter/`, the theme mirror, owned by the user the installer created; `hardware-files`; `patch-files`; `patches`: whether each patch is on |
| Runtime | `$XDG_RUNTIME_DIR/nova/` | `unlocked-once`, locks, sockets; `dictation.sock`, where the shell reaches `nova-dictationd`, and `dictation/last`, the last dictation's words (for `nova dictation last`); a display change not kept yet; `caffeine`, Caffeine's switch; `nightlight-turn`: the last turn the night light's schedule made, so that a restarted shell does not make it again; `power-profile`: the power mode chosen since the unplug; `idle-inhibitors`: the apps keeping the screen awake through `org.freedesktop.ScreenSaver`, which `nova-sessiond` serves; `clock`: the last time the wall clock moved in a way a timer cannot follow (a wake, a clock set, a new time zone), which `nova-sessiond` writes and the shell's `Wake` watches; `automount`: the session's Hyprland instance while removable drives may be mounted, which `nova-automount` writes for the lock screen; `automount-swept`: the session whose drives were all mounted at its first unlock; `airdrop.sock`, where `nova airdrop` and the shell reach the AirDrop receiver while it runs; `apps/`, the App Center's installs: `status.json`, how far each is, and each one's log; `iphone-notifications.json`: how the iPhone is, as iPhone notifications' service last said, for Settings and `nova notification iphone`; `notifications/`: what Nova's notifications run (a click's command, the buttons), a file each, which the notification's `nova-command` hint names: no hint carries a command, since any program may send hints, a sandboxed app's too (`src/shell/plugins/notifications/README.md`) |
| | `/run/nova-airdrop/` | while AirDrop is on, what there is to put back of the Wi-Fi; afterwards, how putting it back went |

### Identifiers

| Thing | Name |
|---|---|
| Shell plugin ids | `nova.<name>`; every plugin ships in the `nova` package and the shell loads no other (`plugins/index.json`, written at build time by `tools/plugin-index`, lists them) |
| Layer-shell namespaces | `nova-<name>` |
| PAM services | `nova-lock-password`, `nova-lock-fingerprint`, `nova-greeter`, `nova-sudo` |
| User units | `nova-*.service` |
| polkit actions | `org.nova.*` |
| Session bus names | `org.nova.*` (`org.nova.iPhoneNotifications`); `org.freedesktop.ScreenSaver`, `org.gnome.keyring.SystemPrompter` and `org.freedesktop.impl.portal.desktop.nova`, which `nova-sessiond` holds for the session |

### Naming

**Nova's code is its own.** The project its shell began from is named nowhere, and none of its code is here.

- Each part was written anew. What the two still have in common is what cannot be said another way: the names of Hyprland's options, of VS Code's colors, of packages and of environment variables.
- `NOTICE` has the licenses of what Nova does build on: the color schemes behind the palettes, Unicode's emoji data, whisper.cpp, the Hyprland it patches, and the speech model.
- `make check-names` (run in CI) fails on that project's name anywhere.

## Session flow (boot to desktop)

1. **Limine boots the UKI.** The config has `quiet: yes` and `timeout: 1`, so a key press shows the menu with snapshots. `nova recovery` reboots straight into that menu.
2. **systemd initramfs, no plymouth.** The firmware logo stays until Hyprland's first frame.
3. **greetd's `initial_session`** runs `nova-session-start` (`uwsm start hyprland`, with nothing of uwsm's on the console: it is all in the journal) as the installed user, once per boot, with `NOVA_LOGIN=autologin`. The greeter starts a session the same way; the console login (`agreety`) runs uwsm plainly, its report on the console it is typed at.
   - Every command greetd runs sets `NOVA_LOGIN`; only the greeter's `password` means somebody authenticated.
   - Anything else, or nothing, is treated as autologin, so the session fails closed.
   - The session's environment is uwsm's: `/etc/profile` and `~/.profile`, then the `env.d` files. Nova's first one (`data/session/uwsm/10-nova`) adds what the user's login shell sets, as a console login has it, through `nova-session-profile`. That covers `~/.bash_profile`, which bash reads in place of `~/.profile`, and a zsh or fish profile.
     - The profile gets 5 s; one that hangs or fails adds nothing. It runs without the session's VT, seat and session id, and with uwsm's `IN_UWSM_ENV_PRELOADER=true`, so a profile that starts a compositor on the first VT does not start one there.
     - It never sets the session's identity (`NOVA_LOGIN`, `XDG_SESSION_ID` and the like), the shell's own names (`UID`, `IFS`, `BASH_ENV`), or `GTK_USE_PORTAL`, which `10-nova` unsets after it.
     - Each line is a `command export`, so a name readonly in uwsm's sh is skipped, not the end of the session's start.
4. **Hyprland starts in the `nova-boot` submap**, which has no binds. Where nothing is drawn it shows black (`misc:background_color`, `data/hypr/behavior.lua`), as the boot and the greeter do.
5. **The shell locks** before it draws anything else.
   - The bar and the desktop wait for the boot's lock to be secure (`Commons/BootLock.qml`), so nothing of the desktop shows before it; a greeter login, which starts unlocked, shows them at once.
   - The lock's surfaces are black, and its view draws nothing until its picture is ready: the backdrop `nova-theme` made (below), read in the first frame. The boot's lock fades it in from black, from the window's first frame. Without a backdrop the view blurs the background itself; a picture that never comes is waited for 1.5 s, then the theme's background stands in.
6. **`nova-session-guard`** (a user unit every user has enabled) waits for `nova-shell lock state` to say `secure`: about 18 s while no shell runs, up to three minutes while one is starting and does not answer yet.
   - If it doesn't, the guard terminates the session, and greetd shows the greeter: `src/shell/greeter.qml` on a minimal Hyprland, or `agreety` on the console if that never shows.
   - Nothing ever shows an unlocked desktop that nobody authenticated.
   - It has no order against `graphical-session.target` either way (`DefaultDependencies=no`): the target does not wait for the lock, so the session's units (the desktop portals among them) start while it waits, and nothing the shell needs to lock may wait on it; nor does it wait for the target, so a unit that hangs at start cannot keep it from running. `tests/unit/session/unit-order.bats` checks the orders with systemd itself.
   - XDG autostart apps (`app-*.service`) wait for it (`data/systemd/user/app-.service.d/`), so none shows a window before the lock.
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

`nova-theme` does this in under 5 ms of its own work, and about a tenth of a second more when the background changes, for the lock's backdrop (step 4):

1. **Render** into a fresh `~/.local/state/nova/rendered/<name>.<stamp>/`:
   - the theme's files, Nova's copy first and then the user's;
   - every template (`~/.config/nova/templates/*.tpl`, then Nova's) rendered with the palette, unless the theme already ships that file;
   - the wordmark background `backgrounds/nova.svg`.
2. **Swap atomically:** `current/theme` is a symlink, replaced by one rename. Readers see the old theme or the new one, never a mix.
3. **Pick the background:** the one last chosen for this theme, else the latest shared photo chosen, else the wordmark.
4. **Tell the shell:** a `themeTransition` IPC fades to the new background and recolors the shell in one step.
   - Meanwhile the lock's backdrop is made (`src/theme/src/backdrop.rs`): the background shrunk to 384 pixels and blurred as the lock showed it, in `current/backdrop.ppm`, about 250 KB. Its header names what it was made of (the picture's path, size and time), so a theme that keeps the photo skips it, and `nova-theme refresh` makes one that is missing (the first login after an update from a Nova without backdrops). One that cannot be made is removed. `nova-theme backdrop` makes it again whatever is there. Each is made under the theme's lock, and `refresh` and `backdrop`, which change neither theme nor background, mirror it for the greeter themselves when they changed it.
5. **Apply** (`nova-theme-apply`, in parallel):
   - `hyprctl reload`;
   - GTK: the palette as `nova.css` in `~/.config/gtk-3.0` and `gtk-4.0`, which `gtk.css` links to; color-scheme; the GTK 3 theme `adw-gtk3` or `adw-gtk3-dark`, which draws with the palette's colors (Qt follows GTK 3); and the same as XSETTINGS for X11 apps (`nova-hyprland-x11-scale`); then xdg-desktop-portal-gtk is started again, for its dialogs: only after the color-scheme change, which it hands on to apps through the settings portal, and which a restart under way would lose;
   - Flatpak: an override of the user's that shows every app those two folders, read-only, set once;
   - foot: new windows read `theme.ini`, open ones get OSC escapes;
   - btop, VS Code, Claude Code, T3 Code;
     - T3 Code: a copy of the palette in `~/.t3/userdata/themes/nova.json`, for its light appearance and its dark alike (any role a variant lacks would be T3 Code's stock color, so all 61 are filled), named its `defaultTheme`. It is told once to follow the system's light or dark (`defaultAppearance: system`), which it reads from the settings portal live, as GTK sets it here.
   - the greeter mirror in `/var/lib/nova/greeter/` (the palette, the background and its backdrop, or no backdrop when there is none), from which a root path unit sets Chrome's color policy.

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
- Each `bg set` makes the lock's backdrop of the new picture (above) and mirrors both for the greeter.

### The cursor

Nova's cursors are a theme of their own, `Nova`, the same under every colour theme (the theme's accent does not tint them):

- **Made when the package is built:** `theme/cursor/build` draws the SVG sources in `theme/cursor/src` with the look `theme/cursor/style` sets (one ink, edge, corner, line weight and shadow for all), into `/usr/share/icons/Nova/` in two forms: Hyprcursor's (`manifest.hl`, `hyprcursors/`), the SVGs, which Hyprland draws at any scale; and XCursor's (`cursors/`, `index.theme`), drawn at the sizes `style` lists, for apps that load cursors themselves and X11 apps. `theme/cursor/names` lists every name a toolkit asks for, as links and overrides. The build ends with its check (every name in both forms, links inside the theme, hotspots on the drawing, frames and delays), and the same sources make the same bytes.
- **Named by the session:** `data/hypr/cursor.lua`, from `env.lua`, sets `XCURSOR_THEME` and `HYPRCURSOR_THEME` to `Nova`. Hyprland copies the XCursor name into GSettings, which GTK, Flatpak apps (the settings portal; `XCURSOR_PATH` there shows them the host's icons) and X11 apps (XSETTINGS, `nova-hyprland-x11-scale`) read. The greeter and the lock are Hyprland's and the shell's, so they draw it too; the greeter names it in `greeter-hyprland.lua`.
- **A choice of the user's wins:** an `XCURSOR_THEME` or `HYPRCURSOR_THEME` the session started with, or a default theme in `~/.local/share/icons/default/index.theme` (or `~/.icons/`) whose `Inherits=` names one, as nwg-look writes it. Then Hyprland draws that theme's Hyprcursor form, or, with none, its XCursor form: Hyprcursor turned off, since it falls back to any theme it finds, which would be Nova's.
- **The name is shared** with the accent-coloured icon theme `Nova` in `~/.local/share/icons` (`nova-theme-apply`), which libXcursor finds first; that one links to `/usr/share/icons/Nova/cursors`, so both name the same cursors.

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
- Flatpak apps reach NVIDIA's driver through a runtime extension built for one driver version (`org.freedesktop.Platform.GL.nvidia-620-73-04`). flatpak picks it from the module loaded now, so an update would fetch the old driver's, and a laptop whose card is off the bus none. `nova-flatpak-gl` gives every install, update and clean-up Nova runs the installed driver's and the loaded one's, and a login check (`nova-flatpak-gl.service`) fetches one that is missing, asking again for one Flathub has not built yet a day later, then twice as long each time, a week at most. On the P1, whose session hides NVIDIA's EGL and Vulkan, `flatpak run` drops the EGL list, so the session sets `FLATPAK_GL_DRIVERS=default:host` instead, and `nova power run` and `prefer` unset it for their program.

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
  - `button`: what the power button does: the system menu, sleep or shut down; the session's, so no root. Behind the lock a press opens nothing (only sleep still sleeps), as no bind marked `locked` may open a window, a menu or a panel there (`tests/unit/shell/locked-keys.bats`);
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
- `etc/`: modprobe, NetworkManager and boot-entry drop-ins, which cannot apply to one model from `/usr`. `nova-hw-apply` copies them into `/etc` from a pacman hook on every install and upgrade of `nova`, and removes the ones a release dropped. A modprobe or boot-entry file takes effect at the restart after the update that brings it: the initramfs carries `modprobe.d`, and every update of `nova` builds each kernel's image and boot entry again after `nova-hw-apply` (the package's `nova-blacklist` initramfs hook is a file the initramfs' pacman hook watches; `tests/unit/hardware/hw.bats` keeps the two in place). One edited by hand takes effect with `sudo limine-update`.

Session-side settings check the model themselves: a uwsm `env.d` file and a `default/hypr/hardware/<profile>.lua` module.

What every computer needs by its hardware, beside a profile, comes from one place: `nova-hw-packages` reads the CPU and the display controllers and camera in sysfs and prints the microcode and the 64- and 32-bit OpenGL and Vulkan drivers. The installer installs them; `nova update` installs the 32-bit ones once anything 32-bit is, and removes an NVIDIA userspace that came in as a dependency on a computer with no NVIDIA module package (`--stray`, which `nova doctor` reads too), in the update that brings a release and on a system already on it; the App Center adds them to an install that needs a driver. After the install, an NVIDIA card counts as NVIDIA's only where a package that provides `NVIDIA-MODULE` is installed; without one, nouveau drives it and it gets NVK. Left to pick a provider of `vulkan-driver` (Steam needs one, and a 32-bit one), pacman takes NVIDIA's on every computer, and `nvidia-utils` blacklists nouveau and puts NVIDIA first for every EGL app wherever it is.

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
| `whisper-cpp` | dictation's speech engine (`libparakeet`, which `nova-dictationd` opens), with its own copy of ggml: Arch's links Arch's ggml, which breaks it as it moves on |
| `supernova` | Nova's own browser, from a pinned Supernova commit; the default, which the installer installs unless Firefox is asked for |
| `hyprland` | Arch's Hyprland with Nova's six patches (`packaging/hyprland/UPSTREAM.md` has them as offered upstream): `xwayland:scale`, X11 apps the same size on every display; an X11 game fullscreen at the resolution it set through RandR; a pointer motion no mouse made sent with a zero relative motion, which older SDL games read as a still mouse otherwise; a release bind that fires when its modifier is let go first; and a window group's tab gradients drawn from textures one pixel wide, not four the monitor's size (160 MiB at 3840x2400); and, on Mesa's iris only, a stencil texture with no depth buffer beside it (48 MiB a monitor at 3840x2400), back to the stock one where a framebuffer would not be complete |
| `cmatrix` | Arch's cmatrix built from upstream's current code: its last release fills the window with solid blocks after a resize |

**Fallback kernel:** Arch's `linux-lts` + `nvidia-open-lts` stay installed as the fallback boot entry.

### A release

A release (`v1.0.0-beta.1`, …) is a GitHub release with:

- `nova-usb`, for making the stick (below);
- the ISO's `.sha256`;
- `release.toml`, which pins the Arch Linux Archive date the release was tested against and says where its packages are.

The rest is in the release's folder of the `nova-packages` bucket on Cloudflare R2 (`https://nova-packages.piserver.stream/<tag>`), which keeps the newest release, and the newest final one:

- the signed `[nova]` repository;
- the installer ISO (`installer/iso`, built by `tools/build-iso`), about 3 GB, with every package any install can need on it (`nova/repo`, the `[nova-offline]` repository, from `tools/offline-repo`), so that it installs without a network (Firefox, which a person can ask for online, is not on it: the installer reads it from the release's Arch snapshot after the stick, `ONLINE_TOO` in `installer/install-packages.bash`);
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

What follows `pacman -Su` (this computer's packages, its graphics drivers and game controllers' rules, the snapshot after, the boot check) is run by the `nova-update-apply` that `pacman -Su` installed, so a release's own steps apply in the update that brings it; one from before that hand-over (after a move back) leaves them to the one running. On a system already on the newest release, `nova update` still makes the repairs that need no release, which `nova doctor` points at: `nova-update-apply --repairs` says them as the user, and only then is there an authentication (`--repair`).

Pre-releases (the candidates) reach only systems that opted in (`nova update --candidates on`) or are already on one.

### Not redistributed: Chrome and VS Code

Chrome and VS Code are built on the machine from their AUR recipes, which download from the vendors (`nova apps install`; alone, it adds VS Code where it is missing and updates what is installed, and Chrome goes in only when asked for, by the installer's browser question or the App Center).

- An install online builds VS Code, and Chrome when it is the browser asked for (`install_apps` in `installer/setup.bash`); offline it builds neither, and the welcome's Apps page offers VS Code at the first login online. Neither is on the stick.
- The package is built uncompressed (`PKGEXT=.pkg.tar`): it is installed and thrown away, and compressing Chrome's 460 MB took longer than packing it.

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

A window over the whole screen, and every lock surface, is `color: "black"` or `"transparent"`. The window's own colour is what shows in its first frames, before anything in it is ready: a white or themed one flashed between the boot's black and the lock. What is drawn in it waits until it is ready, as the lock's view does (`tests/qml/lock-view-test.qml` reads its frames back). `tools/lint-patterns` fails on such a window with any other colour, or none: one anchored or sized to the screen, nested in another or not, and one used by the name of a file whose root it is.

A command's output is complete in its `StdioCollector` by the time `onExited` runs: Quickshell finishes both streams first (`src/io/process.cpp`). A command that cannot start is never heard to exit, only to stop running, so what waits on its end listens to `onRunningChanged` too; a `Process` made for one question and destroyed once it is over is destroyed there as well, or it stays for good (`tools/lint-patterns` finds one that is not).

Waiting without a clock:

- a file followed as it changes is a `WatchedFile` (`Commons`), not a `FileView` with `onFileChanged: reload()`: Quickshell 0.3.2's `reload()` does nothing while a read is under way, so a change that lands then is not read until the next one. A `WatchedFile` reads once more after a load that followed a change (`tests/qml/watched-file-test.qml`); `tests/unit/shell/file-watch.bats` fails on a new bare one, but for the shell's own writers it lists;
- a time of day (a schedule's turn, a reminder) is waited for by a `Timer` aimed at it, and aimed again at `Wake.woke()`: a `Timer` runs on the monotonic clock, which stands still through a sleep and does not follow a clock set or a new time zone, and `nova-sessiond` says each of those (`$XDG_RUNTIME_DIR/nova/clock`).

### Rust

- One Cargo workspace at the root.
- `cargo fmt`, `cargo clippy -D warnings`.
- No unsafe beyond FFI for what std lacks: Linux calls it does not wrap (signal handlers, inotify, timerfd, signalfd, sockets of kinds it has no type for, ioctl, terminal modes), libsystemd, and the C libraries a feature links (jemalloc's `malloc_conf`, libc's `environ` for the shell's `getenv`, zlib, curl for the calendar, gcrypt for the keyring exchange, GIO for Quick Look's descriptions).
- std only, unless a dependency clearly pays for itself. D-Bus and the journal go through `nova-sd` (`src/sd`), libsystemd's own, which every system has.
- Tools a user waits on (the theme engine, the power manager) are Rust, and so is what runs as long as the session does (`nova-sessiond`): a watcher in bash keeps a shell and what it waits on (socat, journalctl, jq) in memory for hours, where one in Rust is a thread asleep in `poll()`. Glue that mostly runs other programs, and then ends, stays bash.

### Tests

| Test | What it does |
|---|---|
| `tests/unit/` | bats tests for the helpers; `make test` runs them |
| `cargo test --workspace` | the Rust programs' tests; `nova-sessiond`'s against stand-ins: a private D-Bus (`dbus-daemon`) with a logind and a udisks of the test's own, a Hyprland socket, and journal files written by `systemd-journal-remote`; `nova-dictationd`'s on a socket of its own, with a microphone that plays a recording and an engine that hears tones as words (and, given the model and a recording, `tests/speech.rs`: a pause to think on real speech) |
| `tests/qml/run` | runs the shell's logic tests (the plugin registry against the real plugin index) offscreen under Quickshell, from an installed tree |
| `tools/lint-patterns` | in `make lint` and CI: kinds of bug found more than once, by their text: a translated listing (pactl, CUPS, `pacman -Qi/-Qk/-Si/-Qu`) parsed without `LC_ALL=C`, `exec` keeping `2>/dev/null` for the whole script, `journalctl -g` under pipefail with nothing to catch its exit 1, a bare `&` in a bash replacement, a QML root shadowing `Item.state` or its children's `data`, a lock surface or a full-screen window that is neither black nor transparent, a reader that stops early under pipefail (`head`, `grep -q`) and so kills its writer with SIGPIPE, a QML `Process` that destroys itself on exit with no `onRunningChanged`; sourced scripts too (by shellcheck's `# shellcheck shell=`), and none found is an error; `tests/unit/tools/lint-patterns.bats` shows each |
| `tools/qml-smoke` | opens the shell's windows offscreen from the same tree, and fails on any runtime QML warning, which qmllint cannot see |
| `tools/shell-smoke` | starts the whole shell under a headless sway, with what `data/hypr/env.lua` sets on the machine (Qt's GTK theme must load) and a desktop portal that never answers, summons its windows over IPC and checks that it locks at startup; in CI only |
| `tools/build-site` | builds the site, and fails on a link between its pages, an #anchor, a picture, wallpaper asset, credit line or file of the repository that is not there, a picture without its size, anything fetched from another site, a theme or wallpaper palette left out or whose text does not read on it, or a function of the menu's code the site runs that is gone; in CI on every push, and before each publication |
| `tools/xwayland-game-check` | an X11 game's fullscreen modes and mouse in a nested Hyprland at the ThinkPad P1's panel and X11 scale; by hand, for each new build of `packaging/hyprland` |
| `tests/usb/stick-test` | writes and restores a real stick on a loop device, as root; in CI only |
| `tests/install/run` | installs a release in QEMU and boots it; in the release workflow only |

### Commits

Imperative subject, a body that explains *why*.
