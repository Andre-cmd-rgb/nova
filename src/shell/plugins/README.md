# Plugins

Apart from its core (`shell.qml` and `services/`), everything the shell
shows or runs is a plugin in this directory: the bar and its widgets, the
panels, overlays and menus, and the services that have no window. All of
them ship with Nova. This page is for writing one; how the shell is put
together is in [../README.md](../README.md).

## The manifest

A plugin says what it is in a `manifest.json` in its directory, or, for the
small bar widgets that share `bar/widgets/`, a `<Name>.manifest.json` beside
its QML. When Nova is built, [`tools/plugin-index`](../../../tools/plugin-index)
collects them into `index.json`, refusing a missing field, an unknown kind, an
entry point that is not there or an id used twice; the shell reads that one
file when it starts.

```json
{
  "id": "nova.weather",
  "name": "Weather",
  "kinds": ["service", "bar-widget"],
  "entryPoints": { "service": "Forecast.qml", "barWidget": "BarWidget.qml" },
  "barWidget": { "switchable": true }
}
```

| Field | What the shell does with it |
|---|---|
| `id` | names the plugin in `shell.json`, in the IPC and to other plugins |
| `name` | what `listPlugins` shows, and the error for a plugin that has no off |
| `kinds`, `entryPoints` | which parts it has, and the QML file of each (below) |
| `keepLoaded` | a panel, overlay or menu loaded at startup, and never unloaded; each is listed, with why, in `tests/unit/shell/idle-work.bats` |
| `enabledByDefault: false` | off until `shell.json` names it, in the bar or in `plugins` |
| `alwaysOn: true` | no off: the bar, the lock and the volume keys |
| `barWidget.defaultSection` | where the widget goes when switched on, if Nova's default layout does not have it; else the center |
| `barWidget.switchable: true` | Settings → Menu Bar has a switch for the widget; any other widget is always on the bar |
| `barWidget.shownWith` | the id of the plugin whose service the widget shows, and only while that plugin is on (Screen Time's widget, `nova.screentime-today`, with `nova.screentime`); Settings → Menu Bar says so under the widget's switch while that plugin is off, and the build refuses an id that is no plugin with a service |

Settings lists a widget by
`barWidget.displayName` (else `name`) and `barWidget.description` (else
`description`), read by `nova-settings state`; a manifest sets those two
only where the widget is put otherwise than the plugin.

## Kinds and entry points

| Kind | Entry point | When it runs |
|---|---|---|
| `service` | `service` | one object while the plugin is on: made the moment it is switched on, destroyed when it is switched off |
| `panel`, `overlay`, `menu` | the same name | loaded the first time it is summoned (or at startup, with `keepLoaded`), and kept until it is hidden |
| `bar-widget` | `barWidget` | a component the bar puts in each slot of its layout that names the plugin |
| `bar` | `bar` | the bar, `nova.bar`, which the shell makes itself |

The three window kinds differ only in the window the plugin makes; the shell
loads them alike, from the entry point of the first of `panel`, `overlay` and
`menu` the plugin has. A plugin can have several kinds: the weather is a
service and a bar widget, the calendar a service and a panel. Where
the widget must go on and off apart from the service, it is a plugin of its
own in the same directory: Screen Time records (`nova.screentime`, a service)
without its widget on the bar (`nova.screentime-today`).

On and off: a plugin is on unless `shell.json` lists it in
`disabledPlugins`; one with `enabledByDefault: false` is on only while
`shell.json` names it, and one with `alwaysOn` whatever it says. Being in the
bar is apart from that: switching a widget off, in Settings or with
`setPluginEnabled`, takes it out of the bar, and while its plugin is on its
component stays made, ready to be put back. `shell.json` is the user's
`~/.config/nova/shell.json`, or Nova's `$NOVA_PATH/default/shell.json` while
there is none; the rest of its rules are in
[../README.md](../README.md#persisted-state).

## What the shell hands an entry point

The shell sets these on a service and on a panel, overlay or menu, each only
when the root object declares a property of that name, and only once the
object exists: they are not there yet in `Component.onCompleted`.

- `shell`: the shell, below.
- `manifest`: the plugin's manifest.
- `service`: for a panel, overlay or menu of a plugin that is a service too,
  that service (the calendar's panel, for one).

A bar widget gets its own from the bar instead (see `Ui/BarWidget.qml`):
`bar`, the bar it sits in; `widgetId`, its id; and `settings`, its entry in
the layout. It reaches the shell as `bar.shell`.

Each screen's bar has a copy of every widget, so a widget does no work of
its own: no `Process`, polling `Timer`, watched file or other watcher. The
work is its plugin's service's, once for all the copies. The widget names
the service in `sharedId`, reads it as `shared`, and holds it while the copy
lives (`Ui/ServiceHold.qml`, which a part of a widget, such as an indicator,
uses by itself). A service built on `Ui/BarWidgetService.qml` works while a copy holds
it (`wanted`) and rests while none does. It reads its settings from the
first copy's entry with `setting(name, fallback)`, and `panelOpen` tells
whether a copy's panel is open. A watch shared with the rest of the shell,
such as rfkill's, is a singleton in `Commons` instead.
[`tests/unit/shell/idle-work.bats`](../../tests/unit/shell/idle-work.bats)
fails on a widget's own process, file watch or poll, unless it is listed
there with its reason.

## What a plugin can ask of the shell

| Member | |
|---|---|
| `serviceFor(id)` | another plugin's service, or null while that one is off or not made yet; a binding on it follows |
| `summon(id, payload)` | opens a panel, overlay or menu, or a bar widget's panel; false when the plugin is unknown, off, has nothing to open, or is a widget not in the bar |
| `hide(id)` | closes it |
| `shellConfig`, `barConfig` | the config in effect, and its `bar` part: read them, never change them; each is a new object when it changes |
| `updateEntryInline(id, settings)` | writes the plugin's own settings, all of them, into its entries in the bar layout, else into its entry in `plugins`; saves, and answers true, only when an entry changes |
| `mutateShellConfig(change)` | calls `change(config)` on a copy of the config, then saves it: the bar's own position and transparency, and its drag and drop |
| `appLibrary` | the installed apps, for the menu |
| `bar` | the bar, for a window placed by it (the notifications) |

## A panel, overlay or menu

`summon` loads the plugin if it has not loaded, and calls its `open(payload)`
with the payload as it was sent, a JSON string or "". Payloads sent while it
loads reach `open()` in order once it has. `hide` calls its `close()`. A
toggle asks its `opened`, when it has one, and otherwise goes by whether it
was summoned. `nova-shell shell call <id> <method> <arg>` calls any method of
the loaded object and answers what it returns: `ok` for nothing, `unknown`
when the plugin has not loaded or has no such method, `error` when it throws.
A plugin of any kind can also take calls of its own, with an `IpcHandler`
whose target `nova-shell` names (`nova-shell -q nova.indicators refresh`).

A panel that fails to load says why in the log and is taken off the summoned
list. One switched off while open loses its loader; switched on again, it
stays closed until it is summoned.

A bar widget with a panel of its own is built on `Ui/Panel.qml`, which keeps
`opened`, `open()` and `close()`. For those the shell passes `summon`, `hide`
and the toggle to the bar, which picks the copy of the widget on the screen
in use.

## The plugins

Paths are under `plugins/`. Battery Life, the calendar, Mobile Data, Screen
Time and the bar have READMEs of their own, linked from their names.

| Plugin | id | Kinds and entry points | What it is |
|---|---|---|---|
| Background | `nova.background` | service `background/Background.qml` | the desktop's background on every screen |
| [Bar](bar/README.md) | `nova.bar` | bar `bar/Bar.qml` | the bar along one edge of every screen |
| Active window | `nova.active-window` | widget `bar/widgets/ActiveWindow.qml` | the focused window's title |
| Indicators | `nova.indicators` | service `bar/widgets/RecorderSearch.qml`, widget `bar/widgets/Indicators.qml` | switches: recording, night light, do not disturb, Caffeine; the recorder looked for once for every screen |
| Keyboard layout | `nova.keyboard-layout` | service `bar/widgets/KeyboardLayoutSeat.qml`, widget `bar/widgets/KeyboardLayout.qml` | the layout's short code, with more than one layout, read once for every screen |
| Microphone | `nova.microphone` | widget `bar/widgets/Microphone.qml` | the default microphone, muted or in use |
| Spacer | `nova.spacer` | widget `bar/widgets/Spacer.qml` | room along the bar, of its entry's `size` |
| Nova update | `nova.system-update` | service `bar/widgets/SystemUpdateCheck.qml`, widget `bar/widgets/SystemUpdate.qml` | a badge while an update waits, asked once for every screen |
| System tray | `nova.tray` | widget `bar/widgets/Tray.qml` | the tray, an icon for each app, any of which can be hidden |
| Workspaces | `nova.workspaces` | widget `bar/widgets/Workspaces.qml` | Hyprland's workspaces |
| AirDrop | `nova.airdrop` | service `airdrop/AirDrop.qml`, panel `airdrop/AirDropToggle.qml` | AirDrop in notifications: an iPhone's offer to accept or decline, a transfer's bar, what came in; sending, from a window that lists the iPhones nearby (`nova airdrop send --window`); the doorbell's switching; the menu's toggle (`nova airdrop`) |
| [Battery Life](batterylife/README.md) | `nova.batterylife` | service `batterylife/Service.qml`, widget `batterylife/BarWidget.qml` | how long the battery lasts; its page is `settings/BatteryLifeView.qml` |
| Calculator | `nova.calculator` | panel `calculator/Panel.qml` | the Calculator's window (`nova calculator`), its keys' sums made in `calculator/Keypad.js`; `calculator/Calculator.js` and `calculator/Qalc.qml` put a sum to `qalc` and read its answer, for it and the menu alike |
| [Calendar](calendar/README.md) | `nova.calendar` | service `calendar/Service.qml`, panel `calendar/Panel.qml` | the calendar's events and tasks, behind its window and the clock's card (`nova calendar`) |
| Screen picker | `nova.capture` | overlay `capture/Capture.qml` | the still of the screen that screenshots, screen recordings and text from the screen are picked on (`nova-capture-region`), kept loaded, with PRINT a key of its own |
| Clipboard | `nova.clipboard` | overlay `clipboard/Clipboard.qml` | the clipboard's history |
| Dictation | `nova.dictation` | panel `dictation/Dictation.qml` | speech to text: the pill, a client of `nova-dictationd` (`src/dictation`); the model's download, the paste and `nova dictation last` are `dictation/bin/dictation` (`nova dictation`) |
| Emojis | `nova.emojis` | overlay `emojis/Emojis.qml` | the emoji picker |
| File picker | `nova.file-picker` | service `file-picker/FilePicker.qml` | the window apps get when they ask for a file to open, a name to save under or a folder to choose, through the desktop portal (`nova.portal`) |
| Image picker | `nova.image-picker` | overlay `image-picker/ImagePicker.qml` | images to choose from, for `nova theme` (below) |
| Lock Screen | `nova.lock` | service `lock/Service.qml` | the lock screen (below) |
| Quick Look | `nova.preview` | panel `preview/Preview.qml` | the preview Files opens with Space: one file in a floating window, with its name and nothing else; `src/preview` (`nova-previewer`, Rust) answers Files on D-Bus, as GNOME Sushi did, and summons it |
| Nova menu | `nova.menu` | menu `menu/Menu.qml`, widget `menu/BarWidget.qml` | the menu and its button (below) |
| [Mobile Data](mobile-data/README.md) | `nova.mobile-data` | service `mobile-data/Service.qml`, widget `mobile-data/BarWidget.qml` | the mobile broadband signal, asked once for every screen, and its panel |
| Notifications | `nova.notifications` | service `notifications/Service.qml` | the notification server and its toasts, and do not disturb's hours; its page is `settings/NotificationsView.qml` |
| On-screen display | `nova.osd` | panel `osd/Osd.qml` | the card for volume, brightness and messages; it and the dictation pill share one place at the bottom of the screen, one at a time (`Commons/Bottom.qml`): a card takes it from the pill for its moment, and the pill is back after |
| Audio | `nova.audio` | widget `panels/audio/Panel.qml` | the volume, and its panel |
| Bluetooth | `nova.bluetooth` | widget `panels/bluetooth/Panel.qml` | Bluetooth, and its panel |
| Clock | `nova.clock` | widget `panels/clock/BarWidget.qml` | the date and time, and the month's card |
| Display | `nova.monitor` | widget `panels/monitor/Panel.qml` | the screens and their brightness, and their panel |
| Network | `nova.network` | widget `panels/network/Panel.qml` | the network link, and its panel |
| Power | `nova.power` | widget `panels/power/Panel.qml` | the battery's charge, and its panel |
| Weather | `nova.weather` | service `panels/weather/Forecast.qml`, widget `panels/weather/BarWidget.qml` | the weather, asked once for every screen, and the forecast's card |
| Polkit Agent | `nova.polkit` | service `polkit/PolkitAgent.qml` | the password card when an app needs root (below) |
| Prompts | `nova.prompts` | service `prompts/Prompts.qml` | the card nova-sessiond asks on: an encrypted drive's passphrase, a Bluetooth pairing's code, a network's password (below) |
| [Screen Time](screentime/README.md) | `nova.screentime`, `nova.screentime-today` | service `screentime/Service.qml`; widget `screentime/BarWidget.qml`, a plugin of its own (`Today.manifest.json`) | time spent per app, and today's total on the bar while it records (off until switched on); its page is `settings/ScreenTimeView.qml` |
| [Readouts](readouts/README.md) | `nova.readouts` | service `readouts/Service.qml`, widgets `readouts/Cpu.qml`, `Graphics.qml`, `Memory.qml` | how busy the processor and graphics card are and how much memory is in use, on the bar (off until switched on) |
| Battery | `nova.battery` | service `services/battery/Service.qml` | the low-battery warning and the power mode |
| Idle | `nova.idle` | service `services/idle/Service.qml` | the screensaver and the lock after `idle` in `shell.json`, and Caffeine |
| Volume and brightness keys | `nova.keys` | service `services/keys/Service.qml` | the volume, brightness and keyboard backlight keys |
| Media | `nova.media` | service `services/media/Service.qml`, widget `services/media/BarWidget.qml` | the MPRIS players, and what plays |
| Night Light | `nova.nightlight` | service `services/nightlight/Service.qml` | hyprsunset's colour temperature, and its schedule; its section is `settings/NightLightView.qml` |
| Network sign-in | `nova.network-portal` | service `services/network/Service.qml` | a notification when a network asks to sign in |
| Settings | `nova.settings` | panel `settings/Panel.qml` | Settings' window |
| Welcome | `nova.welcome` | panel `settings/Welcome.qml` | a new account's welcome, made of Settings' parts (below) |
| App Center | `nova.store` | panel `store/Panel.qml` | the App Center's window, over `nova apps`' helpers (`nova apps store`; [apps.md](../../../docs/apps.md)) |

Three have to do with the battery: Battery is the service behind the warning
and the power mode, Power the bar's button and panel, and Battery Life the
record of how long a charge lasts.

## Notes on some plugins

### Screen picker

`nova-capture-region` asks with `nova-shell nova.capture pick <mode> <fifo>
<token>` (smart, region or windows; the token is `NOVA_CAPTURE_PICK`, or
`-`), and reads the answer from the FIFO it made: the region as slurp writes
one, "X,Y WxH", or a blank line for a pick given up. Every screen's still is
a `ScreencopyView` taken as the pick starts, and nothing is drawn on it until
it has come, so that no dimming is in it. The still stays, bare, after the
answer, for grim to take the region from, until `thaw <fifo>`, or ten
seconds; a `thaw` while it is picked gives the pick up. `waiting <fifo>`
says whether the request is still being answered, which the caller asks
every ten seconds, and gives up on a "no", or on three without an answer. A
request while another's still is held waits for it to go; one while a pick
is under way replaces that pick's request, which is told it was given up.
The windows and screens offered are `nova-capture-region --layout`'s.

PRINT is the plugin's global shortcut, while the shell's backgrounds are on
screen (`data/hypr/keys/desktop.lua`): it freezes the screen at once and
starts `nova-capture-screenshot` with a token of its own, whose request, when
it comes, joins the pick under way, or is given what it came to; no request
without that token is. Without the shell, PRINT starts the command, which
picks with hyprpicker and slurp, as it does when the shell does not answer.

### Image picker

`nova theme` opens it with the `image-selector` IPC target, whose `open` takes
the request as seven words: the folders to list when there are no rows (`nova
theme` sends ""), the rows (a line per image, its path and its thumbnail's
apart by a tab, the lot in base64 to cross the command line), the image to
start on, the answer file, the done file, and whether to show names and a
search field (`true` or `false`). From inside the shell, summon
`nova.image-picker` with the same request as JSON: `imageDirs`, `imageRows`,
`selectedImage`, `selectionFile`, `doneFile`, `showLabels`, `filterable`.

The answer goes through files the caller makes: the chosen path is written
to the answer file and then the done file is made, which is what the caller
waits for; a request dismissed, or replaced by another, gets its done file
alone. The picker is kept loaded, so its window is there at once.

### Lock screen

Wayland's session lock (`WlSessionLock`) holds the session and puts the lock
view on every screen. The password goes through the PAM service
`nova-lock-password`; once the boot's first unlock is done, a finger can
unlock too, through `nova-lock-fingerprint`. An autologin session locks
before anything shows, which is why the lock has no off: the bar and the
desktop wait for the boot's lock (`Commons/BootLock.qml`). logind hears how
the lock is (the session's LockedHint, `lock/LockedHint.qml`), and its Lock
(`loginctl lock-session`) locks, through nova-sessiond; its Unlock opens
nothing, as only the password or the finger may.

The view (`lock/LockView.qml`, the greeter's too) draws nothing over its
black surface until its picture is ready. That picture is the backdrop
`nova-theme` makes whenever the background changes
(`~/.local/state/nova/current/backdrop.ppm`, small and already blurred),
read in the first frame; without one, the background, blurred on the
graphics card. The boot's lock and the greeter fade it in from black.
`tests/qml/lock-view-test.qml` reads its frames back.

### Polkit agent

When an app needs root, a card over the dimmed screen asks for the password,
or for a finger while PAM waits on the reader, through Quickshell's polkit
agent (`Quickshell.Services.Polkit`). Nothing is asked while the screen is
locked: a request that starts then is cancelled at once, and the one on screen
when the lock comes up too, since a program behind the lock could otherwise
take the fingerprint reader and have the next touch "to unlock" authorise it.
The program asks again after the unlock.

### Prompts

What nova-sessiond needs typed or confirmed is asked on the polkit card's
twin, in the same colours (the theme's `[polkit]`): an encrypted drive's
passphrase, a Bluetooth pairing's code, a network's password. The shell
listens on `$XDG_RUNTIME_DIR/nova/prompts.sock`, in the user's private
runtime folder; a duty connects, and one connection is one dialog, a line of
JSON each way at a time (`prompts/PromptsModel.js`, and the duty's side in
`src/session/daemon/src/prompt.rs`). Answered, the card says "Checking..."
until the duty says done, or wrong, when it shakes and is answered again.
What is typed goes through the socket only, never a program's arguments or a
file. A second dialog waits for the first to end.

### Welcome

A new account's welcome is a second plugin in Settings' directory
(`settings/Welcome.manifest.json`), so that its pages are Settings' own
parts (`WifiView`, `ThemeView`, `NightLightView`) and its changes Settings'
commands, run and read back by the same `SettingsState`; Chrome and VS Code
go in through nova update, followed by the same `UpdateRun` as Settings →
Updates. `WelcomeModel.js` says which pages come: each only where it
matters, judged as the page before is left, and nothing the installer has
asked (the keyboard, the account, the computer's name and time zone, a
fingerprint).

It opens at the first unlock of each start while the account has
`~/.local/state/nova/welcome-pending`, which comes with a new account from
Nova's skel (`nova welcome first`, from `nova-session-first-unlock`), and
takes the marker away as it closes, on any page (`nova welcome done`). So an
account made before the welcome existed never sees it, and one whose session
ended with it open sees it again. `nova welcome` opens it at any time.

### Nova menu

The menu's rows come from `menu.jsonc`: Nova's in `$NOVA_PATH/default`, and
the user's in `~/.config/nova`, laid over Nova's a field at a time; both are
read again when they change. Every `when:` and `checked:` is a bash
expression, and they run as one script in plain bash whenever the menu
changes and each time it opens: with the session's environment (what uwsm read
from `/etc/profile` and `~/.profile`, and what the login shell sets, from
`~/.bash_profile` say, as the session started), not a login shell, so a change
to a profile reaches them at the next login, and an action at once. Those
about the shell's own state, written as Nova's
`menu.jsonc` writes them (do not disturb, Caffeine, Screen Time, the
see-through bar, AirDrop), the shell answers itself, at once
(`MenuModel.js`'s `SHELL_ANSWERS`); a `when:` of an entry marked `"once":
true` (whether the computer is a laptop) is asked at the first opening and
kept. A row's `action:` runs in bash as a login shell. The menu
is kept loaded, so opening it is an IPC call to the running shell with
nothing to start.

Settings' pages are the `settings.*` entries of `menu.jsonc`, under an
action, so a search finds them and the list does not show them. A search
from the root that reads as a sum or a conversion (`calculator/Calculator.js`
says which, and turns "in" into qalc's "to") goes to `qalc` once the keys
have rested 50 ms, one run at a time, and without currencies, whose rates
would need the network; qalc keeps its settings in
`$XDG_RUNTIME_DIR/nova/calculator`. Its answer is the first row: Return
copies it with `wl-copy`, Ctrl+Return opens the sum in the Calculator. While the next sum is worked out, the last answer
stays, and Return waits for the new one.
