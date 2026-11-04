# Nova bar

Nova's bar is a plugin of [`nova-shell`](../../README.md) (`id: nova.bar`,
kind `bar`). The shell starts it with the session and keeps it to the end:
one bar along the same edge of every screen, each with the same widgets.

## Its files

| File | What it is |
|---|---|
| `Bar.qml` | The bar as a whole: its part of `shell.json`, its look, the slots of every widget on every screen, the panels and the one popup open, the tooltip, the peek, and all that a widget reads on `bar` |
| `ScreenBar.qml` | One screen's bar: the window on its edge, the tooltip that comes out of it, and the overlays drawn while a widget or the bar is dragged |
| `Sections.qml` | The left, centre and right sections in that window, and the bar's own gestures on its empty part |
| `WidgetSlot.qml` | One widget's place: it loads the widget, hands it the bar and its settings, marks it while its panel is open, and drags it |
| `CommandWidget.qml` | A user's widget that shows what a command prints |
| `SeeThrough.qml` | The text colour of a transparent bar, which `nova-bar-text-color` picks |
| `Tip.qml` | The bar's one tooltip |
| `WidgetDrag.qml`, `BarDrag.qml` | A widget being dragged to another place; the bar being dragged to another edge |
| `BarModel.js` | The rules the windows follow, apart so the tests reach them: entries, the tray's place, the centre's anchor, which copy a key reaches, where a drag lands, where a tooltip goes |
| `BarIpc.qml` | The `nova-shell` targets of the widgets (`nova-shell nova.audio toggle`, `nova-shell nova.indicators refresh`) |

`widgets/` holds the small widgets, each beside its manifest
(`Workspaces.qml`, `Workspaces.manifest.json`). A widget with a panel is a
plugin of its own, in `../panels/`; the media widget is the media service's
(`../services/media/`), and the menu's is the menu's. `indicators/` holds
the switches the Indicators widget shows.

## Setting it

The bar reads the `bar` key of
[`~/.config/nova/shell.json`](../../README.md#persisted-state). Until a user
has that file, it is
[`$NOVA_PATH/default/shell.json`](../../../../data/defaults/shell.json); the
first change (on the bar, with `nova bar`, in Settings or by hand) makes the
user's file the whole config, as the shell's README says. A `shell.json`
without a `bar` key gets Nova's bar.

On the bar itself:

- drag the bar by an empty part, or press there for a moment, and let go
  nearer another edge: the bar goes there;
- double click an empty part for a transparent bar, and again for a solid
  one;
- drag a widget, and let go beside another: it moves there, in another
  section too.

From a terminal, `nova bar position`, `nova bar transparent`, `nova bar move`
and `nova bar set` do the same; `nova bar put` and `nova bar remove`, or
Settings, add widgets and take them off. `nova bar position` writes only the
user's file. `nova-toggle-bar` hides the bar and shows it again.

A bar on the bottom edge, transparent, with the weather and the indicators
either side of the clock:

```json
{
  "version": 1,
  "bar": {
    "position": "bottom",
    "transparent": true,
    "centerAnchor": "nova.clock",
    "layout": {
      "left": [{ "id": "nova.menu" }, { "id": "nova.workspaces" }, { "id": "nova.active-window" }],
      "center": [
        { "id": "nova.weather" },
        { "id": "nova.clock", "format": "ddd d MMM HH:mm" },
        { "id": "nova.indicators", "items": ["Dnd", "Caffeine"] }
      ],
      "right": [{ "id": "nova.network" }, { "id": "nova.audio" }, { "id": "nova.power" }, { "id": "nova.tray" }]
    }
  }
}
```

`centerAnchor` is the centre widget the bar holds at its exact middle; the
others of the centre hang off its two sides, so one that grows or shrinks
moves only those beyond it. An anchor the centre does not have (an id from
before a rename) is the clock, while the centre has the clock. An empty
`centerAnchor` centres the whole centre as one run.

The tray's drawer opens away from the screen's edge, so the tray always goes
to its section's inner end: first on the right, last on the left and in the
centre, wherever the layout puts it (in the example, before the network).

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
that are off show while the pointer is on them, or always with
`"alwaysShow": true`. The pointer on the bar's centre shows them too, until it
leaves the bar, unless the clock's or the weather's card is open. It can be on
the bar more than once, a different set in each place.

The panels of the right section open with Super+Ctrl and a number key,
counted from one (`nova-shell shell togglePanelAt right 2`), on the focused
screen; in a panel, Tab and Shift+Tab go to the next one of its section and
the one before. One card or panel is open at a time: opening another closes
it.

## On a side

Every widget works on all four edges. Cards and panels open on the screen's
side of the bar. A side bar is 28 px wide, a top or bottom one 26 px high
(the theme can change both), and the widgets that show text keep to their
icon there (the media widget drops its title, the active window goes).

## Your own widgets

An id that is not one of Nova's widgets is the user's own: a command whose
output the bar shows, or a QML file. They go in `bar.layout` like the others.

A command is run with `bash -l` every `interval` seconds (5 when not set),
and once as the bar comes up:

```json
{ "id": "disk", "type": "command", "exec": "df --output=pcent / | tail -n 1", "interval": 600, "text": "…", "tooltip": "The disk in use", "onClick": "nova-launch-nautilus" }
```

It shows what the command printed; when the last line printed is a JSON
object as Waybar takes it, its `text`, `tooltip` and `class`: a `class` (or,
with none, an `alt`) of `active`, or a list of classes holding it, draws it in
the bar's urgent colour.

```json
{"text":"91%","tooltip":"The disk is nearly full","class":"active"}
```

`text` and `tooltip` in the entry stand in while the command prints none of
its own. `onClick`, `onMiddleClick` and `onRightClick` are run on those clicks.
`fontSize` (12), `horizontalMargin` (7.5), `verticalPadding` (6) and
`keepSpace` set its look. With no `type`, an entry with `exec` is a command
and one with `source` a QML file.

A QML file is `~/.config/nova/bar/modules/<id>.qml`, or the file its
`source` names (`~/` and `$HOME/` are the home folder):

```json
{ "id": "notes", "type": "qml", "label": "Notes" }
```

It is an `Item` with an `implicitWidth` and an `implicitHeight`. The bar sets
its `bar`, `moduleName` (its id) and `settings` (the rest of its entry), each
it declares:

```qml
import QtQuick

Item {
  property var bar
  property var settings: ({})

  implicitWidth: label.implicitWidth + 14
  implicitHeight: bar ? bar.barSize : 26

  Text {
    id: label
    anchors.centerIn: parent
    text: settings.label || "Notes"
    color: bar ? bar.barForeground : "white"
    font.family: bar ? bar.fontFamily : "monospace"
    font.pixelSize: 12
  }

  TapHandler {
    onTapped: if (bar) bar.run("nova-launch-editor ~/notes.md")
  }
}
```

## What a widget reads on `bar`

The bar sets each widget's `bar`, `moduleName` and `settings`. On `bar`:

- `foreground`, `background`, `urgent`: the theme's colours, kept current;
  `barForeground`, the text colour as drawn, which follows the wallpaper
  while the bar is transparent, and `foregroundAnimationEnabled`, whether a
  change of it may fade;
- `fontFamily`: the monospace font;
- `position` (`"top"`, `"bottom"`, `"left"` or `"right"`), `vertical`,
  `barSize` (26, or 28 on a side) and `barHidden`;
- `run(command)`: runs a command with bash and does not wait for it (quote
  what goes into it with `Util.shellQuote` from `qs.Commons`);
- `showTooltip(target, text)` and `hideTooltip(target)`: the bar's one
  tooltip, shown while `target.tooltipHovered` is true;
- `requestPopout(owner)`, `releasePopout(owner)` and `activePopout`: one card
  or panel open at a time;
- `switchPanelFrom(owner, direction)`: the next panel of the same section;
- `setCenterHoverRevealSuppressed(on)`, `centerSectionRevealHeld` and
  `centerHoverRevealSuppressed`: the peek;
- `moduleWidgets(id)`: every copy of a widget, one on each screen's bar;
- `registerClickTarget(button)` and `unregisterClickTarget(button)`: the
  buttons a click on the bar reaches (`WidgetButton` lists itself).

Every widget of Nova's is a plugin with a manifest: the small ones beside
their QML in `widgets/`, those with a panel in `../panels/`, and plugins
that have a widget among other things, such as `nova.menu` and `nova.media`,
in their own `manifest.json`. Their ids carry the `nova.` prefix; `nova bar`
puts, moves and takes them off (`nova bar put nova.weather --after
nova.clock`).
