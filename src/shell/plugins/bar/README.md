# Nova bar

Nova's bar is a plugin of [`nova-shell`](../../README.md) (`id: nova.bar`,
kind `bar`). The shell starts it with the session and keeps it to the end:
one bar along the top of every screen, each with the same widgets.

## Its files

| File | What it is |
|---|---|
| `Bar.qml` | The bar as a whole: its part of `shell.json`, its look, the slots of every widget on every screen, the panels and the one popup open, the tooltip, the peek, and all that a widget reads on `bar` |
| `ScreenBar.qml` | One screen's bar: the window along the top, the tooltip that comes out of it, and the overlay drawn while a widget is dragged |
| `BarFrame.qml` | The frame that overlay draws, and the slot a dragged widget leaves |
| `Sections.qml` | The left, centre and right sections in that window, and the double click on its empty part |
| `WidgetSlot.qml` | One widget's place: it loads the widget, hands it the bar and its settings, marks it while its panel is open, and drags it |
| `CommandWidget.qml` | A user's widget that shows what a command prints |
| `CommandRuns.qml`, `CommandRun.qml` | The users' commands, each run once for every screen's copy of its widget |
| `SeeThrough.qml` | The ink of a see-through bar and the shade behind it, which `nova-theme bar` picks |
| `Tip.qml` | The bar's one tooltip |
| `WidgetDrag.qml` | A widget being dragged to another place |
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

- double click an empty part for a transparent bar, and again for a solid
  one;
- drag a widget, and let go beside another: it moves there, in another
  section too.

From a terminal, `nova bar transparent`, `nova bar move` and `nova bar set`
do the same; `nova bar put` and `nova bar remove`, or Settings, switch widgets
on and off. A widget switched off keeps its entry in the layout, marked
`"off": true`, which the bar leaves out; switched on again it is where it
was, also after a restart. `nova-toggle-bar` hides the bar and shows it again.

The bar is always at the top. A `position` in an older `shell.json` is
ignored, and dropped at the next write.

Settings → Menu Bar has a switch only for the widgets whose manifest says
`"barWidget": { "switchable": true }`: weather, media, microphone, the
active window, the CPU, Graphics and Memory readouts and Screen Time's total (all but the weather off until switched on, as Nova's `shell.json` names only the weather; Screen Time's shows only while it records). The others are always on the bar, and those that make sense
only on some computers (keyboard layout, mobile data, the update badge) show
only where they apply.

A transparent bar with the weather and the indicators
either side of the clock:

```json
{
  "version": 1,
  "bar": {
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

## The widgets

| Widget | Shows | Pointer |
|---|---|---|
| `nova.menu` | The Nova menu | click = menu · right = terminal |
| `nova.workspaces` | Hyprland's workspaces | click = go to it |
| `nova.clock` | Date and time; a card with the month, ISO weeks, and month steps | click = card · right = next format · middle = time zone |
| `nova.media` | What plays (MPRIS), its title scrolling; a card with the cover | click = play/pause · middle = next · wheel = previous/next · right = card |
| `nova.indicators` | Switches: recording, night light, do not disturb, Caffeine | click = switch it |
| `nova.system-update` | A badge while a Nova or app update waits | click = updates, in Settings |
| `nova.tray` | The system tray: the icon of every app that shows one, in the order of their ids, but those hidden (the `hidden` setting, a list of ids) | click = app · middle = its second action · right = its menu (`tray/TrayMenu.qml`), as tall as its entries up to the screen's room and scrolling past it with a sign at the end that has more, ending with Quit, which ends the app behind the icon for good (`nova-tray-quit`, offered only where it can); Settings → Menu Bar hides an icon and brings it back |
| `nova.weather` | Weather; a card with the forecast | click = card · right = full notification |
| `nova.microphone` | The microphone, lit while recorded | click = mute · middle = audio panel · wheel = its volume |
| `nova.keyboard-layout` | The keyboard layout, while there are two or more | click = next layout |
| `nova.active-window` | The focused window's title | click = focus it · middle or right = close it |
| `nova.spacer` | Empty room, `size` pixels | — |
| `nova.audio` | Volume; a panel with the volume, the outputs and each app's | click = panel · right = mute · middle = panel · wheel = volume |
| `nova.network` | Wi-Fi or Ethernet; a panel with Wi-Fi's switch and the networks to join (the addresses, the band and the DNS are in Settings → Wi-Fi) | click = panel |
| `nova.power` | Battery or AC; a panel with the battery, power modes and the system | click = panel · right = percentage |
| `nova.bluetooth` | Bluetooth; a panel with the devices, to connect, and their batteries | click = panel · right = radio on or off |
| `nova.monitor` | Brightness and the laptop screen | click = panel |
| `nova.batterylife` | The battery and the time it has left, measured | click = its history, in Settings |
| `nova.screentime-today` | Today's screen time, while Screen Time records (off until switched on) | click = the breakdown, in Settings |
| `nova.mobile-data` | The mobile signal, while a modem has a SIM | click = its panel |
| `nova.cpu` | How busy the processor is, a glyph and a percentage (off until turned on) | click = the system monitor (btop) |
| `nova.graphics` | How busy the graphics card that draws the desktop is; the tooltip says whether any other card is on (off until turned on) | click = the system monitor |
| `nova.memory` | The share of memory in use; the tooltip says it in GB (off until turned on) | click = the system monitor |

The three readouts are the widgets of the [Readouts plugin](../readouts/README.md),
which reads for all of them at once and only while one is on a bar.

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

## Size

The bar is 26 px high (the theme can change it), and cards and panels open
below it.

## Your own widgets

An id that is not one of Nova's widgets is the user's own: a command whose
output the bar shows, or a QML file. They go in `bar.layout` like the others.

A command is run with `bash -l` every `interval` seconds (5 when not set),
and once as the bar comes up, once for all the screens:

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
`fontSize` (12), `horizontalMargin` (7.5) and `keepSpace` set its look. With no
`type`, an entry with `exec` is a command and one with `source` a QML file.

A QML file is `~/.config/nova/bar/modules/<id>.qml`, or the file its
`source` names (`~/` and `$HOME/` are the home folder):

```json
{ "id": "notes", "type": "qml", "label": "Notes" }
```

It is an `Item` with an `implicitWidth` and an `implicitHeight`. The bar sets
its `bar`, `widgetId` (its id) and `settings` (the rest of its entry), each
it declares:

```qml
import QtQuick

Item {
  property var bar
  property var settings: ({})

  implicitWidth: label.implicitWidth + 14
  implicitHeight: bar ? bar.thickness : 26

  Text {
    id: label
    anchors.centerIn: parent
    text: settings.label || "Notes"
    color: bar ? bar.textColour : "white"
    font.family: bar ? bar.fontFamily : "monospace"
    font.pixelSize: 12
  }

  TapHandler {
    onTapped: if (bar) bar.run("nova-launch-editor ~/notes.md")
  }
}
```

## What a widget reads on `bar`

The bar sets each widget's `bar`, `widgetId` and `settings`. On `bar`:

- `foreground`, `background`, `urgent`: the theme's colours, kept current;
  `textColour`, the text colour as drawn, which follows the wallpaper while
  the bar is transparent, and `textFades`, whether a change of it may fade;
- `fontFamily`: the monospace font;
- `thickness` (26) and `tucked` (moved off the screen by
  `nova-toggle-bar`);
- `run(command)`: runs a command with bash and does not wait for it (quote
  what goes into it with `Util.shellQuote` from `qs.Commons`);
- `tip.ask(target, text)` and `tip.withdraw(target)`: the bar's one
  tooltip, shown while `target.pointedAt` is true;
- `claimPopup(owner, open)` and `popup`: one card or panel open at a time;
  opening one closes the one open;
- `nextPanel(owner, step)`: the next panel of the same section, or the one
  before;
- `peek`: whether the indicators that are off show, as the pointer is on
  the centre; a widget whose card covers the centre says `hidesPeek`, and
  while that card is open they do not;
- `copiesOf(id)`: every copy of a widget, one on each screen's bar;
- `listButton(button, on)`: the buttons a click on the bar reaches
  (`BarButton` lists itself);
- `shell`: the shell, for `shell.serviceFor(id)` (a binding follows it), as
  `BarWidget`'s `sharedId` uses it to hold a service every screen's copy
  shares;
- `commands`: the user commands' runs (`CommandRuns`), one for each
  command and interval whatever the number of screens, which
  `CommandWidget` reads.

A widget with a panel can ask for its mark, the line on the bar under the
open panel, to be `markLength` long, rather than a little over half its
slot.

Every widget of Nova's is a plugin with a manifest: the small ones beside
their QML in `widgets/`, those with a panel in `../panels/`, and plugins
that have a widget among other things, such as `nova.menu` and `nova.media`,
in their own `manifest.json`. Their ids carry the `nova.` prefix; `nova bar`
puts, moves and takes them off (`nova bar put nova.weather --after
nova.clock`).
