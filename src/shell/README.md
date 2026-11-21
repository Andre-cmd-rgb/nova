# Nova shell

The Nova desktop is one [Quickshell](https://quickshell.org/) process, the
shell, which runs for the whole session: Hyprland starts it at login through
`nova-launch-shell`. The bar, the lock screen, the notifications, the panels
and the overlays are all plugins **inside** it. So:

- a service shared by plugins runs once, in one process;
- opening a panel is an IPC call to a shell that is up already, with
  nothing to start.

What is installed under `$NOVA_PATH/shell`:

```
shell/
  shell.qml              entry point (ShellRoot): wires the parts below; IPC
  greeter.qml            the greeter's entry point
  services/
    ShellJson.qml           shell.json, Nova's and the user's: the config in effect
    PluginRegistry.qml      reads the plugin index, answers what is on, and the verbs
    Layout.js               what the verbs do to shell.json's bar layout and lists
    PluginServices.qml      a running object for each service that is on
    Panels.qml              a loader for each panel, overlay and menu that is on
    BarWidgets.qml          the bar widgets' components
    AppLibrary.qml          the installed apps, sorted, launched and removed, for the menu
    AppSearch.js            which of them the menu lists, and in what order
    hidden-entries.sh       the desktop entries hidden from this desktop, and those for the discrete GPU
  Commons/  Ui/             shared singletons and controls
  plugins/
    index.json              every manifest below, collected when Nova is built
    bar/ lock/ menu/ notifications/ panels/ services/ settings/ ...
```

Beside it, in `/usr/lib/nova`, the shell's allocator settings: `alloc/`, a
Rust library that `nova-launch-shell` preloads into Quickshell. It gives
Quickshell's jemalloc two arenas, not four a CPU, and takes itself out of
`LD_PRELOAD` as it loads, so the apps the shell starts inherit neither.

The plugins and what each one is are listed in [plugins/README.md](plugins/README.md).

## Plugins

Every plugin is Nova's own and ships in the `nova` package; there are no
plugins from anywhere else. Each declares itself in a `manifest.json` (or a
`<Name>.manifest.json` beside its QML, for the small bar widgets that share a
directory):

```json
{
  "id": "nova.clock",
  "name": "Clock",
  "description": "Date/time label with a calendar popup",
  "kinds": ["bar-widget"],
  "entryPoints": { "barWidget": "BarWidget.qml" }
}
```

What each field does is in [`plugins/README.md`](plugins/README.md).

The build collects them into `plugins/index.json` with
[`tools/plugin-index`](../../tools/plugin-index), which also checks them: a
missing field, an unknown kind, an entry point that does not exist or an id
used twice fails the build. The shell reads that one file at startup.

| Kind         | What it is                                         | Entry point  |
|--------------|----------------------------------------------------|--------------|
| `bar`        | the bar (`nova.bar`, the only one)                 | `bar`        |
| `bar-widget` | a component the bar drops into a section           | `barWidget`  |
| `panel`      | a floating window, summoned or kept (e.g. the OSD) | `panel`      |
| `overlay`    | a fullscreen overlay (e.g. the image picker)       | `overlay`    |
| `menu`       | a summoned menu surface                            | `menu`       |
| `service`    | a headless singleton                               | `service`    |

Services and plugins that set `keepLoaded: true` are loaded at startup;
the windows that do, the windows the services and the bar make, and the
Timers that run all the time are listed, with why, in
[`tests/unit/shell/idle-work.bats`](../../tests/unit/shell/idle-work.bats).
Other panels, overlays and menus load when they are summoned, and stay
loaded until the shell hides them (`hide`, or `toggle` while open); a
second after the last window closes, the shell collects what they held
(a collection stops what is on screen, so it waits for none to be open).
One that closes its own window stays loaded unless it tells the shell, as
Nova's do with `shell.hide`.

Entry points may declare `shell`, `manifest` and, for a panel paired with a
service, `service`; the shell sets each one it finds. Bar widgets get the bar as `bar`, and reach the
shell's services with `bar.shell.serviceFor(id)`.

## IPC

The shell answers two IPC targets of its own: `shell`, below, and
`image-selector`, whose `open` is how `nova theme` opens the image picker.
Plugins add theirs, such as the bar's `bar`.
[`nova-shell`](../cli/bin/nova-shell) passes a call on to the shell that is
running, and never starts one; `nova bar` and `nova menu` are made of these
calls.

| Call                                           | Answer           | What it does                                              |
|------------------------------------------------|------------------|-----------------------------------------------------------|
| `ping`                                         | `ok`             | whether the shell answers                                 |
| `summon <id> <payloadJson>`                    | `ok` / `unknown` | load and open a panel, overlay or menu                    |
| `hide <id>`                                    | —                | close it                                                  |
| `toggle <id> <payloadJson>`                    | —                | hide it when open, summon it when not                     |
| `togglePanelAt <section> <index>`              | id / `unknown`   | toggle the bar panel at that position                     |
| `call <id> <method> <arg>`                     | string           | call a method on a loaded plugin                          |
| `reloadConfig`                                 | `ok`             | read `~/.config/nova/shell.json` again                    |
| `setPluginEnabled <id> <true\|false>`          | `ok` / error     | switch a plugin on or off (only `"true"` enables)         |
| `putBarWidget <id> <placementJson>`            | `ok` / error     | enable unless already on the bar                          |
| `moveBarWidget <id> <placementJson>`           | `ok` / error     | move a widget within or between sections                  |
| `setBarWidget <id> <key> <valueJson> <selectorJson>` | `ok` / error | set a widget entry's setting                             |
| `listPlugins`                                  | JSON             | every plugin, sorted by name                              |

```
nova-shell shell summon nova.settings '{"page":"updates"}'
nova-shell shell setPluginEnabled nova.screentime true
quickshell ipc -p $NOVA_PATH/shell call shell listPlugins
```

`nova-restart-shell` stops the running shell and starts a fresh one; the shell
does not reload itself when its files change, so a package upgrade restarts it.

## Persisted state

There is one user config file, `~/.config/nova/shell.json`. Without one the
shell uses `$NOVA_PATH/default/shell.json` verbatim; once you customize
anything, your file is authoritative and defaults are **not** merged back in.

```json
{
  "version": 1,
  "idle": { "screensaver": 180, "lock": 300 },
  "bar": {
    "transparent": false,
    "centerAnchor": "nova.clock",
    "layout": {
      "left":   [ { "id": "nova.menu" }, { "id": "nova.workspaces" } ],
      "center": [ { "id": "nova.clock", "format": "HH:mm" } ],
      "right":  [ { "id": "nova.audio" } ]
    }
  },
  "plugins": [],
  "disabledPlugins": []
}
```

1. **`version: 1` is required.** The shell falls back to the defaults rather
   than load an unknown version.
2. **A widget is on the bar while its entry is in `bar.layout` and not
   marked `"off": true`.** Switched off, a widget keeps its entry, marked
   so, and comes back to the same place when it is switched on again.
   Settings are inline on the entry; there are no per-plugin settings files.
3. **Everything else is on unless switched off,** which is recorded in
   `disabledPlugins[]`. A plugin whose manifest says `"enabledByDefault":
   false` (Screen Time) is the other way round: on only while `shell.json`
   names it, in the bar or in `plugins[]`, and not marked off. One that says `"alwaysOn": true`
   (the bar, the lock) cannot be switched off.
4. **`idle.screensaver`** and **`idle.lock`** are the seconds unused before
   the screensaver starts and before the screen locks; 0 is never.
5. **`nightlight`** is the night light's schedule and warmth, which `nova
   nightlight schedule` and `nova nightlight warmth` set: `schedule` is
   `"off"`, `"sunset"` or `"hours"`, `from` and `to` the hours as `"22:00"`,
   `temperature` the night's kelvin, 2500 to 5500 (4000 unless set).
6. **`doNotDisturb`** is the hours do not disturb holds every day, which `nova
   notification schedule` sets: `schedule` is `"off"` or `"hours"`, `from`
   and `to` the hours as `"22:00"`.
