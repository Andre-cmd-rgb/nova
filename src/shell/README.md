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
  shell.qml              entry point (ShellRoot): services, panels, IPC
  greeter.qml            the greeter's entry point
  services/
    PluginRegistry.qml      reads the plugin index, answers what is enabled
    BarWidgetRegistry.qml   the bar widgets' components
    AppLibrary.qml          the installed apps, sorted, launched and removed, for the menu
    AppSearch.js            how a search matches and ranks them
    hidden-entries.sh       the desktop entries hidden from this desktop
  Commons/  Ui/             shared singletons and controls
  plugins/
    index.json              every manifest below, collected when Nova is built
    bar/ lock/ menu/ notifications/ panels/ services/ settings/ ...
```

The plugins and what each one is are listed in [plugins/README.md](plugins/README.md).

## Plugins

Every plugin is Nova's own and ships in the `nova` package; there are no
plugins from anywhere else. Each declares itself in a `manifest.json` (or a
`<Name>.manifest.json` beside its QML, for the small bar widgets that share a
directory):

```json
{
  "schemaVersion": 1,
  "id": "nova.clock",
  "name": "Clock",
  "version": "1.0.0",
  "kinds": ["bar-widget"],
  "entryPoints": { "barWidget": "BarWidget.qml" },
  "barWidget": {
    "displayName": "Clock",
    "category": "Time",
    "defaultSection": "center",
    "defaults": { "format": "dddd HH:mm" }
  }
}
```

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

Services and plugins that set `keepLoaded: true` are loaded at startup.
Other panels, overlays and menus load when they are summoned, and stay
loaded until the shell hides them (`hide`, or `toggle` while open); one
that closes its own window stays loaded.

Entry points may declare `novaPath`, `shell`, `manifest`, `pluginRegistry`,
`barWidgetRegistry` and, for a panel paired with a service, `service`; the
shell sets each one it finds. Bar widgets get the bar as `bar`, and reach the
shell's services with `bar.shell.serviceFor(id)`.

## IPC

The shell answers two IPC targets of its own: `shell`, below, and
`image-selector`, through which the image selector opens the image picker
(`open`, `preload`, `cancel`, `ping`). Plugins add theirs, such as the
bar's `bar`. [`nova-shell`](../cli/bin/nova-shell) passes a call on to the
shell that is running, and never starts one; `nova bar` and `nova menu`
are made of these calls.

| Call                                           | Answer           | What it does                                              |
|------------------------------------------------|------------------|-----------------------------------------------------------|
| `ping`                                         | `ok`             | whether the shell answers                                 |
| `summon <id> <payloadJson>`                    | `ok` / `unknown` | load and open a panel, overlay or menu                    |
| `hide <id>`                                    | —                | close it                                                  |
| `toggle <id> <payloadJson>`                    | —                | hide it when open, summon it when not                     |
| `togglePanelAt <section> <index>`              | id / `unknown`   | toggle the bar panel at that position                     |
| `call <id> <method> <arg>`                     | string           | call a method on a loaded plugin                          |
| `applyTheme <colorsB64> <shellB64>`            | `ok`             | restyle the shell (`nova theme` sends it)                 |
| `reloadConfig`                                 | `ok`             | read `~/.config/nova/shell.json` again                    |
| `setPluginEnabled <id> <true\|false>`          | `ok` / error     | switch a plugin on or off (only `"true"` enables)         |
| `enablePlugin <id> <placementJson>`            | `ok` / error     | switch on, placing a widget                               |
| `putBarWidget <id> <placementJson>`            | `ok` / error     | enable unless already on the bar                          |
| `moveBarWidget <id> <placementJson>`           | `ok` / error     | move a widget within or between sections                  |
| `setBarWidget <id> <key> <valueJson> <selectorJson>` | `ok` / error | set a widget entry's setting                             |
| `toggleBarTransparency`                        | `ok` / `no-bar`  |                                                           |
| `listPlugins`                                  | JSON             | every plugin, sorted by name                              |
| `listShellConfig`                              | JSON             | the effective `shell.json`                                |
| `debugBarGeometry`                             | JSON             | where the bar's windows are, for debugging                |

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
    "position": "top",
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
2. **A widget is on the bar while its entry is in `bar.layout`.** Settings
   are inline on the entry; there are no per-plugin settings files.
3. **Everything else is on unless switched off,** which is recorded in
   `disabledPlugins[]`. A plugin whose manifest says `"enabledByDefault":
   false` (Screen Time) is the other way round: on only while `shell.json`
   names it, in the bar or in `plugins[]`. One that says `"alwaysOn": true`
   (the bar, the lock) cannot be switched off.
4. **Multiple instances** are allowed when a widget's manifest sets
   `allowMultiple: true`: two clocks in different time zones are two
   `nova.clock` entries with their own settings.
5. **`idle.screensaver`** and **`idle.lock`** are the seconds unused before
   the screensaver starts and before the screen locks; 0 is never.
