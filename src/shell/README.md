# Nova shell

`nova-shell` is a single long-running [Quickshell](https://quickshell.org/)
instance that hosts the Nova desktop. Hyprland's autostart launches one per
session through `nova-launch-shell`; everything else (the bar, lock screen,
notifications, panels, overlays) runs **inside** it as a plugin.

Hosting everything inside one shell means:

- shared services live once, not once per process
- summoning a panel is an IPC call into a process that is already running,
  not a fresh `quickshell -p ...` cold start

The runtime layout:

```
shell/
  shell.qml              entry point (ShellRoot): services, panels, IPC
  greeter.qml            the greeter's entry point
  services/
    PluginRegistry.qml   reads the plugin index, answers what is enabled
    BarWidgetRegistry.qml the bar widgets' components
  Commons/  Ui/          shared singletons and controls
  plugins/
    index.json           every manifest below, collected when Nova is built
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

Services and plugins that set `keepLoaded: true` are mounted at startup;
other panels, overlays and menus load the first time they are summoned and
stay loaded for the session.

Entry points may declare `novaPath`, `shell`, `manifest`, `pluginRegistry`,
`barWidgetRegistry` and, for a panel paired with a service, `service`; the
shell sets each one it finds. Bar widgets get the bar as `bar`, and reach the
shell's services with `bar.shell.serviceFor(id)`.

## IPC contract

The shell exposes a `shell` IPC target, plus whatever targets individual
plugins register (the image picker's `image-selector`, the bar's `bar`).
[`nova-shell`](../cli/bin/nova-shell) forwards calls to the running shell; it
does not start one. `nova bar` and `nova menu` are built on these calls.

| Method                                         | Returns          | Effect                                                    |
|------------------------------------------------|------------------|-----------------------------------------------------------|
| `ping`                                         | `ok`             | health check                                              |
| `summon <id> <payloadJson>`                    | `ok` / `unknown` | load and open a panel, overlay or menu                    |
| `hide <id>`                                    | —                | close it                                                  |
| `toggle <id> <payloadJson>`                    | —                | summon if closed, hide if open                            |
| `togglePanelAt <section> <index>`              | id / `unknown`   | toggle the bar panel at that position                     |
| `call <id> <method> <arg>`                     | string           | call a method on a loaded plugin                          |
| `applyTheme <colorsB64> <shellB64>`            | `ok`             | restyle the shell (`nova theme` sends it)                 |
| `reloadConfig`                                 | `ok`             | reload `~/.config/nova/shell.json`                        |
| `setPluginEnabled <id> <true\|false>`          | `ok` / `unknown` | switch a plugin on or off (only `"true"` enables)         |
| `enablePlugin <id> <placementJson>`            | `ok` / error     | switch on, placing a widget                               |
| `putBarWidget <id> <placementJson>`            | `ok` / error     | enable unless already on the bar                          |
| `moveBarWidget <id> <placementJson>`           | `ok` / error     | move a widget within or between sections                  |
| `setBarWidget <id> <key> <valueJson> <selectorJson>` | `ok` / error | set a widget entry's setting                             |
| `toggleBarTransparency`                        | `ok` / `no-bar`  |                                                           |
| `listPlugins`                                  | JSON             | every plugin, sorted by name                              |
| `listShellConfig`                              | JSON             | the effective `shell.json`                                |

```
nova-shell shell ping
nova-shell shell toggle nova.menu '{"menu":"root"}'
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
  "idle": { "lock": 300 },
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
   names it, in the bar or in `plugins[]`.
4. **Multiple instances** are allowed when a widget's manifest sets
   `allowMultiple: true`: two clocks in different time zones are two
   `nova.clock` entries with their own settings.
5. **`idle.lock`** is the seconds of inactivity before the screen locks; 0
   never locks.
