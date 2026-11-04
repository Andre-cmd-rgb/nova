import QtQuick
import Quickshell.Io
import qs.Commons as Commons
import "BarModel.js" as BarModel

// The text colour of a see-through bar. nova-bar-text-color picks, of the
// theme's text colour and its background colour, the one that reads better
// on the wallpaper where the bar is. Until it answers, the bar keeps the
// theme's solid look; it is asked again when the edge, the theme or the
// wallpaper changes. Its answer is drawn at once, as is the way back to the
// theme's colour: <fades> is off until the change has been drawn.
Item {
  id: seeThrough

  // What the bar asks with.
  property bool wanted: false
  property string edge: "top"
  property int thickness: 0
  property color text
  property color backdrop

  // What the bar draws: whether it is see-through, the colour of its text
  // then, and whether a change of that colour may fade.
  property bool shown: false
  property color colour: text
  property bool fades: true

  // What picks the colour; tests/qml/see-through-test.qml sets its own.
  property string pickCommand: "nova-bar-text-color"
  // Asked again while the picker runs: what it is measuring may be gone by
  // the time it answers, so that answer is dropped and it is asked again
  // once it ends.
  property bool stale: false

  visible: false

  // The bar's config says whether it is see-through: wanted, the colour is
  // asked for again; not, the bar is solid at once.
  function want(on) {
    wanted = on
    if (on) {
      ask()
      return
    }
    fades = false
    shown = false
    colour = text
    fadeAgainSoon()
  }

  function ask() {
    if (wanted) soon.restart()
    else colour = text
  }

  function answered(line) {
    if (stale) return
    var picked = String(line || "").trim()
    if (!/^#[0-9A-Fa-f]{6}$/.test(picked)) return
    fades = false
    colour = picked
    if (wanted) shown = true
    fadeAgainSoon()
  }

  // Two turns on, once the change has been drawn.
  function fadeAgainSoon() {
    Qt.callLater(function() {
      Qt.callLater(function() { seeThrough.fades = true })
    })
  }

  onWantedChanged: ask()
  onEdgeChanged: ask()
  onTextChanged: ask()
  onBackdropChanged: ask()

  // One ask for a burst of changes.
  Timer {
    id: soon
    interval: 120
    onTriggered: {
      if (!seeThrough.wanted) return
      if (picker.running) {
        seeThrough.stale = true
        return
      }
      picker.command = [seeThrough.pickCommand, seeThrough.edge, String(seeThrough.thickness),
        BarModel.hex(seeThrough.text.r, seeThrough.text.g, seeThrough.text.b),
        BarModel.hex(seeThrough.backdrop.r, seeThrough.backdrop.g, seeThrough.backdrop.b)]
      picker.running = true
    }
  }

  Process {
    id: picker
    onExited: {
      if (!seeThrough.stale) return
      seeThrough.stale = false
      soon.restart()
    }
    stdout: SplitParser {
      onRead: function(line) { seeThrough.answered(line) }
    }
  }

  // A new theme or wallpaper.
  FileView {
    path: Commons.Color.stateHome + "/nova/current"
    watchChanges: true
    printErrors: false
    onFileChanged: seeThrough.ask()
  }
}
