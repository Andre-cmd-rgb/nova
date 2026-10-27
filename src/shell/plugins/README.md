# Plugins

Everything the shell shows is one of these plugins. Each declares itself in a
`manifest.json`, or a `<Name>.manifest.json` beside its QML for the small bar
widgets in `bar/widgets/`; the build collects them into `index.json`, which is
how the shell finds them (see [../README.md](../README.md#plugins)).

All are on by default except Screen Time. Services and keep-loaded panels are
mounted at startup; other panels, overlays and menus load when first summoned.
Three have "battery" in what they do: Battery (`nova.battery`) is the service
behind the low-battery warning and the power mode, Power (`nova.power`) the
bar's battery widget and its panel, and Battery Life (`nova.batterylife`) the
history and the time left. Battery Life, Mobile Data, Screen Time and the bar
have READMEs of their own, linked from their rows.

| Plugin | id | kinds | entry points |
|---|---|---|---|
| Background | `nova.background` | `service` | `background/Background.qml` |
| [Bar](bar/README.md) | `nova.bar` | `bar` | `bar/Bar.qml` |
| Active window | `nova.active-window` | `bar-widget` | `bar/widgets/ActiveWindow.qml` |
| Indicators | `nova.indicators` | `bar-widget` | `bar/widgets/Indicators.qml` |
| Keyboard layout | `nova.keyboard-layout` | `bar-widget` | `bar/widgets/KeyboardLayout.qml` |
| Microphone | `nova.microphone` | `bar-widget` | `bar/widgets/Microphone.qml` |
| Spacer | `nova.spacer` | `bar-widget` | `bar/widgets/Spacer.qml` |
| Nova update | `nova.system-update` | `bar-widget` | `bar/widgets/SystemUpdate.qml` |
| System tray | `nova.tray` | `bar-widget` | `bar/widgets/Tray.qml` |
| Workspaces | `nova.workspaces` | `bar-widget` | `bar/widgets/Workspaces.qml` |
| [Battery Life](batterylife/README.md) | `nova.batterylife` | `service`, `bar-widget` | `batterylife/Service.qml`, `batterylife/BarWidget.qml` (its page: `settings/BatteryLifeView.qml`) |
| Clipboard | `nova.clipboard` | `overlay` | `clipboard/Clipboard.qml` |
| Dictation | `nova.dictation` | `panel` | `dictation/Dictation.qml` (its speech side: `dictation/bin/dictation`, `nova dictation`) |
| Emojis | `nova.emojis` | `overlay` | `emojis/Emojis.qml` |
| Image picker | `nova.image-picker` | `overlay` | `image-picker/ImagePicker.qml` |
| Lock Screen | `nova.lock` | `service` | `lock/Service.qml` |
| Nova menu | `nova.menu` | `menu`, `bar-widget` | `menu/Menu.qml`, `menu/BarWidget.qml` |
| [Mobile Data](mobile-data/README.md) | `nova.mobile-data` | `bar-widget` | `mobile-data/BarWidget.qml` |
| Notifications | `nova.notifications` | `service` | `notifications/Service.qml` |
| On-screen display | `nova.osd` | `panel` | `osd/Osd.qml` |
| Audio | `nova.audio` | `bar-widget` | `panels/audio/Panel.qml` |
| Bluetooth | `nova.bluetooth` | `bar-widget` | `panels/bluetooth/Panel.qml` |
| Clock | `nova.clock` | `bar-widget` | `panels/clock/BarWidget.qml` |
| Display | `nova.monitor` | `bar-widget` | `panels/monitor/Panel.qml` |
| Network | `nova.network` | `bar-widget` | `panels/network/Panel.qml` |
| Power | `nova.power` | `bar-widget` | `panels/power/Panel.qml` |
| Weather | `nova.weather` | `bar-widget` | `panels/weather/BarWidget.qml` |
| Polkit Agent | `nova.polkit` | `service` | `polkit/PolkitAgent.qml` |
| [Screen Time](screentime/README.md) | `nova.screentime` | `service`, `bar-widget` | `screentime/Service.qml`, `screentime/BarWidget.qml` (its page: `settings/ScreenTimeView.qml`) |
| Battery | `nova.battery` | `service` | `services/battery/Service.qml` |
| Idle | `nova.idle` | `service` | `services/idle/Service.qml` |
| Media | `nova.media` | `service`, `bar-widget` | `services/media/Service.qml`, `services/media/BarWidget.qml` |
| Night Light | `nova.nightlight` | `service` | `services/nightlight/Service.qml` |
| Settings | `nova.settings` | `panel` | `settings/Panel.qml` |

## Bar

The status bar. Its layout lives in the top-level `bar:` subtree of
`~/.config/nova/shell.json` (with the shell providing
[`$NOVA_PATH/default/shell.json`](../../../data/defaults/shell.json) when the
user has no file). See [`bar/README.md`](bar/README.md) for the widget
catalogue and customization schema.

## Image picker

Fullscreen image-grid selector overlay. Used by `nova-theme bg pick`
(background picker) and `nova-theme pick` (theme picker) and any
other caller that wants to present a directory of images with previews.

Two ways to drive it:

- Shell-level summon: `nova-shell shell summon nova.image-picker '<jsonPayload>'`.
  The payload can carry `imageDirs`, `imageRows`, `selectedImage`,
  `selectionFile`, `doneFile`, `showLabels`, `filterable`. Best for
  in-shell callers that already speak JSON.
- Direct IPC target: `nova-shell image-selector open <imageDirs> <imageRowsB64> <selectedImage> <selectionFile> <doneFile> <showLabels> <filterable>`.
  Positional args; `imageRowsB64` is base64-encoded so embedded newlines /
  tabs survive the bash argv handoff. This is what `nova-theme` uses
  (`src/theme/src/picker.rs`). Colors come from the central shell theme
  singleton; there is no per-call override surface.

The selection round-trip remains file-based: callers create a
`selection_file` and `done_file` (both `mktemp`), pass the paths, and
poll `done_file` for existence. The plugin writes the chosen path into
`selection_file` and touches `done_file` when it's done. `cancel` IPC
clears it without writing a selection.

The plugin has `keepLoaded: true` so the layer-shell window survives
between summons within a single shell session.

## Lock screen

Session-lock surface using Quickshell's native `WlSessionLock` and two separate
PAM services: `nova-lock-password` for password auth and, only when
fingerprints are enrolled, `nova-lock-fingerprint` for fingerprint auth. It
shows the blurred wallpaper and the password field, in the theme's colors and
with Hyprland's corners. Like every service it is mounted at startup and lives
as long as the shell.

## Polkit agent

Theme-aware authentication dialog for privileged actions. It uses
Quickshell's native `Quickshell.Services.Polkit.PolkitAgent` backend and
runs inside the long-lived `nova-shell` process.

## Nova menu

Quickshell-powered Nova command menu. The menu UI lives in `menu/Menu.qml` as a
first-party `menu` plugin and is summoned through the shell
(`nova-shell shell summon nova.menu ...`), so it shares the long-running
`nova-shell` process instead of starting a second Quickshell instance.

The menu definition lives outside the shell host code:

- defaults: `$NOVA_PATH/default/menu.jsonc`
- user overrides: `~/.config/nova/menu.jsonc`, merged key by key

The shell parses both JSONC files at startup (with `watchChanges: true`
so edits take effect without a restart), evaluates `when:` / `checked:`
bash expressions in a single batched subprocess, and executes the
selected `action:` string directly via `Quickshell.execDetached`. The
long-running shell process keeps the parsed menu in memory, so the
keybind → IPC → visible path costs ~30ms cold.
