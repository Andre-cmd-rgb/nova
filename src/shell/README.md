# Nova shell

`nova-shell` is a single long-running [Quickshell](https://quickshell.org/)
instance that hosts the Nova desktop. Hyprland autostart launches one shell
per graphical session; everything else — the bar, background switcher, panels,
and overlays — runs **inside** the shell as a plugin.

Hosting everything inside one shell means:

- shared services and singletons live once, not once per process
- summoning a panel is an IPC call into a process that is already running,
  not a fresh `quickshell -p ...` cold start
- third-party plugins can be loaded from disk without changing any source
  code in Nova itself

The runtime layout:

```
shell/
  shell.qml              entry point (ShellRoot)
  services/
    PluginRegistry.qml   discovers, validates plugins, looks up enabled state in shell.json
    BarWidgetRegistry.qml unified registry for bar widgets (1p + 3p)
  plugins/
    bar/                 first-party plugins (see plugins/README.md)
    image-picker/
    menu/
    notifications/
    panels/
      audio/
      bluetooth/
      monitor/
      network/
      power/
      weather/
    agents/
    services/
      battery/
      idle/
    osd/
    polkit/
```

The plugin discovery path is documented in [plugins/README.md](plugins/README.md).

## Plugin manifest

Every plugin ships a `manifest.json` describing what it is and how the
shell should load it. Minimal example:

```json
{
  "schemaVersion": 1,
  "id": "my.org.cool-clock",
  "name": "Cool clock",
  "version": "1.0.0",
  "author": "You",
  "description": "A clock that does cool things",
  "kinds": ["bar-widget"],
  "entryPoints": { "barWidget": "Widget.qml" },
  "barWidget": {
    "displayName": "Cool clock",
    "category": "Time",
    "allowMultiple": false,
    "defaultSection": "left",
    "defaults": { "format": "HH:mm" },
    "schema": [
      { "key": "format", "type": "string", "label": "Format" }
    ]
  }
}
```

Supported `kinds`:

| Kind         | What it is                                                   |
|--------------|--------------------------------------------------------------|
| `bar-widget` | A component that the active bar can drop into a section      |
| `panel`      | A persistent or summoned floating window (e.g. OSD)          |
| `overlay`    | A fullscreen overlay (e.g. background switcher)              |
| `menu`       | A summoned menu surface                                      |
| `service`    | A headless singleton, no UI                                  |
| `bar`        | A full bar option that can replace the built-in `nova.bar` |

Only one `bar` plugin is active at a time. Missing or invalid selections fall
back to the built-in `nova.bar`, so users always have a safe path home.
Panels, overlays, and menus are loaded when summoned. Plugins that need
to outlive a single summon can set `keepLoaded: true` (e.g. the image
picker keeps its overlay window mounted between summons). The same flag
keeps a service mounted across plugin hot-reload, so tearing down a
changed bar widget cannot destroy `nova.lock` while Hyprland still
holds the session lock. The kept instance is not replaced, so code
changes to a `keepLoaded` service itself only take effect on a shell
restart. First-party services are loaded at startup.

Entry points may declare `novaPath`, `shell`, `manifest`, `pluginRegistry`, and `barWidgetRegistry` properties for host injection. Built-in plugins receive the trusted host objects. Third-party plugins receive capability-scoped facades: ordinary plugins can look up and control only their own service and lifecycle, built-in clones retain narrow source-specific configuration and UI compatibility, menu plugins receive an application-library facade, and plugins can read detached scalar bar state. A full-bar plugin additionally receives detached bar configuration and widget-catalog snapshots, narrow proxies for the non-authentication services used by built-in bar widgets, and lifecycle control over configured non-authentication UI plugins. Authentication capabilities are stamped from trusted first-party manifests, authentication services are retained outside the host's public service map and QML object tree, and changing a third-party registry or configuration snapshot cannot mutate host state. Facades do not isolate visual widgets from the parent hierarchy of the shared QML scene, so sensitive state must remain outside that reachable graph.

Widgets rendered by a third-party replacement bar receive a service-less entry facade with target-scoped lifecycle and settings operations. Their live service objects are available only when the trusted built-in bar hosts them; otherwise the replacement bar could request and retain any configured widget's service.

The full schema lives in `services/PluginRegistry.qml`.

## Installing a third-party plugin

A plugin is a **git repo** with a `manifest.json` at its root. Adding one
clones it straight into `~/.config/nova/plugins/<id>/` (named by the
manifest id); updating is a fast-forward pull of that checkout.

```bash
nova plugin add https://github.com/acme/nova-weather.git
nova plugin update acme.weather       # fetches, shows a diff, fast-forwards
nova plugin update                    # updates every git-managed plugin
nova plugin remove acme.weather
```

> ⚠️ **Plugins run as unsandboxed code inside `nova-shell`.** Adding warns you before cloning, plugins land disabled so you can review the code before enabling, and updates show a diff of the changes before touching anything. The scoped QML interfaces remove direct authentication-service and generic replacement-bar service lookups, but visual plugins still share and can traverse the ordinary host scene. Only add repos whose code you are willing to run.

Add, update, and remove commands confirm in a terminal even when given
arguments; without a terminal they refuse rather than guess. Pass `--yes` to
skip every prompt — this is the path for scripts and AI agents:

```bash
nova plugin add https://github.com/acme/nova-weather.git --enable --yes
nova plugin update --yes
```

The installer never runs plugin code, install hooks, or sudo — it only clones
files, validates the manifest, and toggles enabled state over shell IPC. Since
an installed plugin is a plain git checkout, anything beyond add/update
(pinning a ref, switching branches) is ordinary git in the plugin directory.

### Installing by hand

You can still drop a plugin in without git:

1. Put it in `~/.config/nova/plugins/<plugin-id>/` with a `manifest.json`
   plus the QML referenced from its `entryPoints`.
2. `nova-shell shell rescanPlugins`.
3. `nova plugin enable <id>`. Bar widgets start in
   `barWidget.defaultSection`, or in the center when it is omitted, and can be
   moved with `nova bar move`; a full bar replaces the one in use.

The lower-level IPC equivalents remain available via `nova-shell shell rescanPlugins`,
`nova-shell shell enablePlugin <id> '{}'`, and `nova-shell shell listPlugins`.
The `nova plugin` commands wrap those calls. `nova bar move` and
`nova bar set` edit the persisted widget layout in `shell.json`.

To hack on a built-in plugin safely, clone it into user config instead of
editing the built-in source. The complete plugin directory is copied, including
every declared kind and local dependency. A built-in id such as
`nova.clock` becomes `<username>.clock` (e.g. `dhh.clock`), with `My Clock`
as its display name. The username prefix keeps shared clones from colliding
with each other or with other plugin authors.

```bash
nova plugin clone nova.clock
```

Cloning switches from the built-in to the new personal plugin, preserving an
existing bar widget's position and settings. Setup > Plugins > Clone provides
the interactive picker, then opens the new `<username>.*` directory in `$EDITOR`.
Existing shortcuts and shell IPC calls made to the built-in id are routed to
the enabled clone, so cloning does not require changing its callers. Removing
an active clone switches back to its built-in source.
Saving a file anywhere under `~/.config/nova/plugins/` reloads plugin code
automatically; `nova-shell shell rescanPlugins` remains available to force a reload.

First-party plugins under `shell/plugins/` are discovered the same way and load
by default. Disabling a non-widget records it in `disabledPlugins[]`; disabling
a widget removes it from the bar layout while leaving its component available
to add again. A full bar has no off state and is replaced by enabling another.

## IPC contract

The shell exposes a single `shell` IPC target plus whatever extra targets
individual plugins register (e.g. the bar's `bar` target for refresh
hooks, the image picker's `image-selector` target). `nova-menu` uses the
shell target to summon the first-party `nova.menu` plugin instead of
running a separate Quickshell instance.

| Method                                   | Returns | Effect                                                |
|------------------------------------------|---------|-------------------------------------------------------|
| `ping`                                   | `ok`    | health check                                          |
| `summon <id> <payloadJson>`              | `ok` / `unknown` | load + open a panel/overlay plugin           |
| `hide <id>`                              | —       | close a previously-summoned plugin                    |
| `toggle <id> <payloadJson>`              | —       | summon if closed, hide if open                        |
| `call <id> <method> <arg>`               | string  | call a method on an already-loaded plugin             |
| `rescanPlugins`                          | —       | re-walk plugin dirs and hot-reload plugin code        |
| `reloadConfig`                           | `ok`    | reload `~/.config/nova/shell.json`                 |
| `setPluginEnabled <id> <enabled>`        | `ok` / `unknown` | flip the persisted enabled bit (see note)    |
| `listPlugins`                            | JSON    | every discovered plugin, sorted by name               |

Direct invocation:

```
quickshell ipc -p $NOVA_PATH/shell call shell ping
```

Hyprland autostart launches the shell directly with `quickshell -p
$NOVA_PATH/shell`. Use `nova-restart-shell` to stop every running
instance of that config and launch one fresh shell process.

A convenience wrapper, [`nova-shell`](../bin/nova-shell), forwards IPC
calls to the running shell. It does not start the shell.

```
nova-shell shell ping
nova-shell shell toggle nova.menu '{"menu":"root"}'
nova-shell shell listPlugins
nova-shell shell rescanPlugins
```

**Note on `setPluginEnabled`:** the `enabled` argument is a string. Only the
literal `"true"` enables the plugin; every other value (including `"True"`,
`"1"`, `"yes"`, or omitted) disables it. This keeps the IPC surface
type-stable across QML's `string`-only IPC arguments.

## Persisted state

There is one user config file. Everything that distinguishes your
customization from the shipped defaults lives in it.

| Path                              | Owner          | Purpose                                                |
|-----------------------------------|----------------|--------------------------------------------------------|
| `~/.config/nova/shell.json`    | the shell      | full layout + per-entry settings + enabled plugin list |
| `~/.config/nova/plugins/<id>/` | user           | drop-in third-party plugin source files                |

The `config/nova/shell.json` default config describes the
fresh-install state. When the user has no `shell.json`, the shell uses
the defaults verbatim. Once the user customizes anything, `shell.json`
becomes the authoritative file — we do **not** deep-merge defaults back in.

### shell.json shape

```json
{
  "version": 1,
  "idle": {
    "lock": 300
  },
  "bar": {
    "id": "nova.bar",
    "position": "top",
    "transparent": false,
    "centerAnchor": "nova.clock",
    "layout": {
      "left":   [ { "id": "nova.menu" }, { "id": "nova.workspaces" } ],
      "center": [ { "id": "nova.clock", "format": "HH:mm" } ],
      "right": [
        { "id": "nova.audio" }
      ]
    }
  },
  "plugins": []
}
```

### Storage rules

1. **The active bar option is `bar.id`.** Omit it or set it to `nova.bar`
   to use the built-in bar. Set it to another plugin id whose manifest declares
   `kind: "bar"` to replace the full bar.
2. **Every plugin instance is one entry.** Either in `bar.layout.<section>`
   for bar widgets, or in `plugins[]` for panels, overlays, services,
   menus, and anything else non-bar.
3. **Settings are inline on the entry.** No `config:` sub-object, no
   separate per-plugin settings file, no merge layers. The fields on each
   entry are the values the plugin sees.
4. **Built-in widget ids are namespaced.** Use ids such as `nova.clock`,
   `nova.audio`, and `nova.network`. The migration rewrites older ids
   like `Clock` and `AudioPanel` forward.
5. **Third-party enabled ⇔ present.** A third-party plugin is enabled iff
   its id appears somewhere in shell.json. For full bar options, that means
   `bar.id`; for bar widgets, plugin enable/disable adds/removes layout entries;
   other plugin kinds are enabled the same way. First-party non-bar plugins
   are enabled unless listed in `disabledPlugins[]`.
6. **Multiple instances** are allowed when a manifest sets
   `allowMultiple: true`. Each instance is independent — e.g. two clock
   widgets in different timezones are just two `{"id":"nova.clock", "timezone": ...}`
   entries with their own values.
7. **The idle timing is top-level.** `idle.lock` is the seconds of
   inactivity before the screen locks; 0 never locks.
8. **`version: 1` is required** at the top level. The shell will fall back
   to defaults rather than load an unknown version.

## Implementation history

Built up in phases on this branch:

- Phase 1 — `nova-shell phase 1: host the existing bar in a single shell`
- Phase 2 — `nova-shell phase 2: plugin registry and bar widget registry`
- Phase 3 — `nova-shell phase 3: fold bar-settings into the shell as a panel plugin`
- Phase 4 — `nova-shell phase 4: absorb background-switcher as a plugin`
- Phase 5 — `nova-shell phase 5: docs, cleanup, and migration crumbs`
- Phase 6 — `nova-shell phase 6: reviewer cleanup (path traversal, collision, races)`
- Phase 7 — `nova-shell phase 7: replace socket with IpcHandler, rename to image-picker`
- Phase 8a — `nova-shell phase 8a: unified shell.json with inline plugin settings`

Shared services and Pipewire/UPower/Hyprland consolidation are explicitly
out of scope here and deferred to a follow-up after a review pass.
