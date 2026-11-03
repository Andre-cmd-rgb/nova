# Nova bar

The bar is a plugin of [`nova-shell`](../../README.md) (`id: nova.bar`, kind
`bar`), mounted when the shell starts and kept for the whole session, one copy
on each screen.

- `Bar.qml` builds it from the `bar` part of the shell's config and lays out
  its widgets; `BarModel.js` holds the layout logic it shares with the tests;
  `BarIpc.qml` answers the `nova-shell` targets of its widgets
  (`nova-shell nova.audio toggle`, `nova-shell nova.indicators refresh`).
- `widgets/` holds the small widgets, each beside its manifest
  (`Workspaces.qml`, `Workspaces.manifest.json`). The widgets with a panel are
  plugins of their own, in `../panels/`; the media widget is the media
  service's (`../services/media/`), and the menu's is the menu's.
- `indicators/` holds the switches the Indicators widget shows.

## Where it is set

The config is the `bar` key of
[`~/.config/nova/shell.json`](../../README.md#persisted-state). A user with no
file of their own gets
[`$NOVA_PATH/default/shell.json`](../../../../data/defaults/shell.json); once
anything is changed (on the bar, with `nova bar`, in Settings, or by hand), the
user's file is the whole config, as the shell's README says.

Most of it is set on the bar itself:

- drag its empty space, or press and hold it, to take the bar to another
  edge;
- double click its empty centre for a transparent bar;
- drag a widget to another place.

`nova bar position`, `nova bar transparent`, `nova bar move` and `nova bar set`
do the same from a terminal; `nova bar put` and `nova bar remove`, or Settings,
add and take off widgets. `nova bar position` writes only the user's file.

The `bar` part of a `shell.json`:

```json
{
  "version": 1,
  "bar": {
    "position": "top",
    "transparent": false,
    "centerAnchor": "nova.clock",
    "layout": {
      "left": [
        { "id": "nova.menu" },
        { "id": "nova.spacer", "size": 12 },
        { "id": "nova.workspaces" }
      ],
      "center": [
        { "id": "nova.media" },
        { "id": "nova.clock", "format": "HH:mm" }
      ],
      "right": [
        { "id": "nova.audio" },
        { "id": "nova.power" }
      ]
    }
  }
}
```

`centerAnchor` names the centre widget held at the exact middle of the bar,
the others of the centre to either side of it. An empty string centres them as
one group instead.

## The widgets

| Widget | Shows | Pointer |
|---|---|---|
| `nova.menu` | The Nova menu | click = menu · right = terminal |
| `nova.workspaces` | Hyprland's workspaces | click = go to it |
| `nova.clock` | Date and time; a card with the month, ISO weeks, and month steps | click = card · right = next format · middle = time zone |
| `nova.media` | What plays (MPRIS), its title scrolling; a card with the cover | click = play/pause · middle = next · wheel = previous/next · right = card |
| `nova.indicators` | Switches: recording, night light, do not disturb, Caffeine | click = switch it |
| `nova.system-update` | A badge while a Nova or app update waits | click = updates, in Settings |
| `nova.tray` | The system tray, the unpinned icons in a drawer | pointer on the chevron = drawer · right on the chevron = pin and hide · icon: click = app, middle = its second action, right = its menu |
| `nova.weather` | Weather; a card with the forecast | click = card · right = full notification |
| `nova.microphone` | The microphone, lit while recorded | click = mute · middle = audio panel · wheel = its volume |
| `nova.keyboard-layout` | The keyboard layout, while there are two or more | click = next layout |
| `nova.active-window` | The focused window's title | click = focus it · middle or right = close it |
| `nova.spacer` | Empty room, `size` pixels | — |
| `nova.audio` | Volume; a panel with the volume, the outputs and each app's | click = panel · right = mute · middle = panel · wheel = volume |
| `nova.network` | Wi-Fi or Ethernet; a panel to scan, connect and pick a DNS provider | click = panel |
| `nova.power` | Battery or AC; a panel with the battery, power modes and the system | click = panel · right = percentage |
| `nova.bluetooth` | Bluetooth; a panel with the devices, to connect, and their batteries | click = panel · right = radio on or off |
| `nova.monitor` | Brightness and the laptop screen | click = panel |
| `nova.batterylife` | The battery and the time it has left, measured | click = its history, in Settings |
| `nova.screentime` | Today's screen time (off until turned on) | click = the breakdown, in Settings |
| `nova.mobile-data` | The mobile signal, while a modem has a SIM | click = its panel |

`nova.indicators` shows the indicators in `indicators/`: all of them, in their
order, when its `items` is missing or empty, else those it names, from `Dnd`,
`NightLight`, `Caffeine` and `ScreenRecording` (`["Dnd", "NightLight"]`). Those
that are off show only while the pointer is on them, or always with
`"alwaysShow": true`. It can be on the bar more than once, a different set in
each place.

## On a side

Every widget works on all four edges. Cards and panels open on the screen's
side of the bar. A side bar is 28 px wide, a top or bottom one 26 px high
(the theme can change both), and
the widgets that show text keep to their icon there (the media widget drops
its title, the active window goes).

## Your own widgets

Any id the bar does not know is the user's: a command whose output it shows,
or a QML file. Both go in `bar.layout.<section>` like the others.

A command, run every `interval` seconds (5 when not set):

```json
{
  "version": 1,
  "bar": {
    "layout": {
      "right": [
        { "id": "nova.tray" },
        { "id": "vpn", "type": "command", "exec": "~/.config/nova/bar/scripts/vpn-status", "interval": 5, "tooltip": "VPN", "onClick": "nm-connection-editor" },
        { "id": "nova.audio" }
      ]
    }
  }
}
```

It prints plain text, or JSON as Waybar takes it; a `class` of `active` draws
it in the urgent colour:

```json
{"text":"󰌆","tooltip":"Work VPN","class":"active"}
```

`onClick`, `onMiddleClick` and `onRightClick` are run on a click. With no
`type`, an entry with `exec` is a command and one with `source` a QML file.

A QML file:

```json
{
  "version": 1,
  "bar": {
    "layout": {
      "right": [
        { "id": "gpu", "type": "qml" },
        { "id": "nova.audio" }
      ]
    }
  }
}
```

The bar loads `~/.config/nova/bar/modules/gpu.qml`, or the file a `source`
names (`~/` and `$HOME/` are the home folder). It is an `Item` with an
`implicitWidth` and an `implicitHeight`; the bar sets its `bar`, `moduleName`
and `settings` when it has them:

```qml
import QtQuick

Item {
  property var bar
  property string moduleName
  property var settings

  implicitWidth: 28
  implicitHeight: bar ? bar.barSize : 26

  Text {
    anchors.centerIn: parent
    text: "GPU"
    color: bar ? bar.foreground : "white"
    font.family: bar ? bar.fontFamily : "monospace"
    font.pixelSize: 12
  }

  MouseArea {
    anchors.fill: parent
    onClicked: if (bar) bar.run("nova-launch-or-focus-tui btop")
  }
}
```

## What a widget gets

The bar sets each widget's `bar`, `moduleName` (its id) and `settings` (its
entry in the layout). On `bar`:

- `foreground`, `background`, `urgent`: the theme's colours, kept current;
  `barForeground`, the text colour on the bar as it is drawn, which follows
  the wallpaper while the bar is transparent;
- `fontFamily`: the monospace font;
- `position` (`"top"`, `"bottom"`, `"left"` or `"right"`) and `vertical`;
- `barSize`: 26, or 28 on a side;
- `run(command)`: runs a command with bash and does not wait for it (quote
  what goes into it with `Util.shellQuote` from `qs.Commons`);
- `showTooltip(target, text)` and `hideTooltip(target)`: the bar's one
  tooltip;
- `requestPopout(owner)` and `releasePopout(owner)`: one card open at a time.

Every widget is a plugin with a manifest: the small ones beside their QML in
`widgets/`, those with a panel in `../panels/`, and plugins that have a widget
among other things, such as `nova.menu` and `nova.media`, in their own
`manifest.json`. Ids carry the `nova.` prefix (`nova.audio`, `nova.clock`).
`nova bar` puts, moves and takes them off
(`nova bar put nova.weather --after nova.clock`).
