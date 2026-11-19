// platform: wayland
// stub: bin/nova-battery-info record
// stub: bin/nova-power-profile record
// stub: bin/nova-bluetooth-power record
// stub: bin/rfkill rfkill
// stub: bin/nova-monitor-state monitor-state
// stub: bin/nova-brightness-display record
// stub: bin/nova-display-text-size record
// stub: bin/nova-hyprland-monitor-scaling record
// stub: bin/curl record
// stub: bin/nova-weather-location record
// stub: bin/gdbus gdbus
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "plugins/panels/power" as Power
import "plugins/batterylife" as Batterylife
import "plugins/panels/audio" as Audio
import "plugins/panels/network" as Network
import "plugins/panels/bluetooth" as Bluetooth
import "plugins/panels/clock" as Clock
import "plugins/panels/weather" as Weather
import "plugins/panels/monitor" as Monitor
import "plugins/services/media" as MediaWidget

// Every bar panel's card reads, in every theme: the text on a card is drawn
// in the card's own colours, not the bar's. Over a see-through bar the bar's
// text colour is picked for the wallpaper behind it (white over a dark one),
// while the card is drawn on the popups' background, cream under a light
// theme, so a panel that took the bar's colour drew white on cream.
//
// The test is that mistake made on purpose: the fake bar's text colour and
// foreground are the extreme that is WRONG for the card (white under a light
// theme, black under a dark one), each panel is built with that bar, and every
// Text and field under its card is blended over the card's background and
// measured. A text that took the bar's colour comes out at 1:1.
//
// The card's content exists while the card is closed (the card creates it with
// itself), so the panels are not opened; the texts of sections that show only
// with data (a device, a forecast, a player) are measured all the same, which
// is stricter, for they show once there is data. The media card is given a
// fake service with two players, so that its track and player list exist.
//
// 3.0:1 is the least WCAG asks of large text and of marks, and the floor for
// the quietest text here (dates out of the month, notes): below it the text is
// there to the eye of a tester but not to a reader. Body text is held to the
// same number rather than 4.5:1, as the faded lines are made by dimming
// (Util.faded), which on a light theme cannot be steered to a fixed ratio.
//
// What it cannot reach: the tray's menu, which is a QsMenuOpener on a real
// tray item that Quickshell makes only from a StatusNotifier on the bus; and
// what is painted on a fill other than the card's (a selected row's tint, a
// button's face), which is measured against the card.
ShellRoot {
  id: test

  readonly property real floor: 3.0
  readonly property var themes: [
    { name: "rose-pine", light: true },
    { name: "catppuccin-latte", light: true },
    { name: "flexoki-light", light: true },
    { name: "white", light: true },
    { name: "tokyo-night", light: false }
  ]

  // The colour that is wrong for the card of the theme under test.
  property color wrong: "white"
  property Item stage: Item {}

  property QtObject fakeBar: QtObject {
    readonly property int thickness: 30
    readonly property string fontFamily: "monospace"
    readonly property color foreground: test.wrong
    readonly property color background: "black"
    readonly property color textColour: test.wrong
    readonly property color urgent: "red"
    readonly property bool textFades: false
    readonly property bool peek: false
    readonly property bool tucked: false
    property var popup: null
    property var buttons: []
    property var summoned: []
    property QtObject tip: QtObject {
      function ask(button, text) {}
      function withdraw(button) {}
    }
    property QtObject shell: QtObject {
      function serviceFor(id) { return id === "nova.media" ? test.mediaService : null }
      function summon(id, argument) {}
      function updateEntryInline(id, entry) {}
    }
    function listButton(button, on) {}
    function copiesOf(id) { return [] }
    function claimPopup(key, open) { popup = open ? key : null }
    function inWindow(item, window) { return false }
    function nextPanel(owner, step) { return false }
    function run(command) {}
  }

  // Two players, one playing, as the media service would list them.
  property QtObject mediaService: QtObject {
    readonly property var first: ({
      trackTitle: "A long title of a track", trackArtist: "An artist", trackAlbum: "An album", trackArtUrl: "",
      isPlaying: true, identity: "Player one", dbusName: "org.mpris.MediaPlayer2.one", desktopEntry: "one",
      canGoNext: true, canGoPrevious: true, canPlay: true, canPause: true, canTogglePlaying: true })
    readonly property var second: ({
      trackTitle: "Another track", trackArtist: "Another artist", trackAlbum: "", trackArtUrl: "",
      isPlaying: false, identity: "Player two", dbusName: "org.mpris.MediaPlayer2.two", desktopEntry: "two",
      canGoNext: true, canGoPrevious: true, canPlay: true, canPause: true, canTogglePlaying: true })
    readonly property var activePlayer: first
    readonly property var listed: [first, second]
    function press(action, osd, key) {}
    function choose(player) {}
  }

  Instantiator {
    id: files
    model: test.themes
    delegate: FileView {
      required property var modelData
      path: Quickshell.env("TEST_PLUGINS") + "/../../themes/" + modelData.name + "/colors.toml"
      blockLoading: true
    }
  }

  Component { id: power; Power.Panel { bar: test.fakeBar } }
  Component { id: batterylife; Batterylife.BarWidget { bar: test.fakeBar } }
  // Its directory has a hyphen, which an import cannot name.
  property var mobileData: Qt.createComponent("file://" + Quickshell.env("TEST_PLUGINS") + "/mobile-data/BarWidget.qml")
  Component { id: audio; Audio.Panel { bar: test.fakeBar } }
  Component { id: network; Network.Panel { bar: test.fakeBar } }
  Component { id: bluetooth; Bluetooth.Panel { bar: test.fakeBar } }
  Component { id: clock; Clock.BarWidget { bar: test.fakeBar } }
  Component { id: weather; Weather.BarWidget { bar: test.fakeBar } }
  Component { id: monitor; Monitor.Panel { bar: test.fakeBar } }
  Component { id: media; MediaWidget.BarWidget { bar: test.fakeBar } }

  readonly property var panels: [
    { name: "power", made: power }, { name: "batterylife", made: batterylife },
    { name: "mobile-data", made: mobileData }, { name: "audio", made: audio },
    { name: "network", made: network }, { name: "bluetooth", made: bluetooth },
    { name: "clock", made: clock }, { name: "weather", made: weather },
    { name: "monitor", made: monitor }, { name: "media", made: media }
  ]

  // ------------------------------------------------------------ measuring

  // WCAG's relative luminance of an opaque colour.
  function luminance(c) {
    const lin = v => v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
  }

  // <ink> at <opacity> laid over the opaque <face>, and its contrast with it.
  function contrast(ink, opacity, face) {
    const a = ink.a * opacity
    const seen = Qt.rgba(face.r * (1 - a) + ink.r * a, face.g * (1 - a) + ink.g * a, face.b * (1 - a) + ink.b * a, 1)
    const one = luminance(seen), other = luminance(face)
    return (Math.max(one, other) + 0.05) / (Math.min(one, other) + 0.05)
  }

  // The card (the PopupFace of a PanelSurface or a BarPopup) among <object>'s
  // descendants, which are its data and, for a window, its content item.
  function cardOf(object, seen) {
    if (seen.has(object)) return null
    seen.add(object)
    if (object.contentShown !== undefined && object.edgeColor !== undefined) return object
    const below = object.data ? Array.from(object.data) : []
    if (object.contentItem) below.push(object.contentItem)
    for (const child of below) {
      const found = cardOf(child, seen)
      if (found) return found
    }
    return null
  }

  // Every text under <object> as { text, colour, ratio }: what it says, and
  // how it reads on <face> at its own colour and opacity and its ancestors',
  // up to the card.
  function measure(object, opacity, face, seen, found) {
    if (seen.has(object)) return
    seen.add(object)
    const here = opacity * (typeof object.opacity === "number" ? object.opacity : 1)
    if (here > 0 && typeof object.text === "string" && object.text.trim() !== "" && object.font !== undefined && object.wrapMode !== undefined) {
      found.push({ text: object.text.trim().slice(0, 30), colour: String(object.color), ratio: contrast(object.color, here, face) })
    }
    if (here > 0 && typeof object.placeholderText === "string" && object.placeholderText !== "" && object.placeholderTextColor !== undefined) {
      found.push({ text: object.placeholderText.slice(0, 30), colour: String(object.placeholderTextColor), ratio: contrast(object.placeholderTextColor, here, face) })
    }
    const below = object.data ? Array.from(object.data) : []
    if (object.contentItem) below.push(object.contentItem)
    for (const child of below) measure(child, here, face, seen, found)
  }

  function audit(theme, panel) {
    const widget = panel.made.createObject(stage)
    const card = cardOf(widget, new Set())
    if (!card) {
      console.log("FAIL " + panel.name + " under " + theme.name + ": no card found")
      return
    }
    const found = []
    const seen = new Set()
    for (const child of Array.from(card.data)) measure(child, 1, Commons.Color.popups.background, seen, found)
    found.sort((a, b) => a.ratio - b.ratio)
    const bad = found.filter(t => t.ratio < floor)
    const lowest = found.length ? found[0].ratio : 0
    if (found.length === 0) {
      console.log("FAIL " + panel.name + " under " + theme.name + ": no text found on the card")
    } else if (bad.length === 0) {
      console.log("ok   " + panel.name + " under " + theme.name + ": " + found.length + " texts, lowest " + lowest.toFixed(2) + ":1")
    } else {
      console.log("FAIL " + panel.name + " under " + theme.name + ": " + bad.length + " of " + found.length + " texts under " + floor.toFixed(1) + ":1, worst "
        + bad.slice(0, 4).map(t => JSON.stringify(t.text) + " " + t.colour + " " + t.ratio.toFixed(2) + ":1").join("; "))
    }
    widget.destroy()
  }

  Component.onCompleted: Qt.callLater(run)

  function run() {
    for (let i = 0; i < themes.length; i++) {
      const theme = themes[i]
      Commons.Color.loadColors(files.objectAt(i).text())
      wrong = theme.light ? "white" : "black"
      for (const panel of panels) audit(theme, panel)
    }
    console.log("DONE")
    Qt.quit()
  }
}
