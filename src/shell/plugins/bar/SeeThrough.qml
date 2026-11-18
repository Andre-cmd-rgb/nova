import QtQuick
import Quickshell.Io
import qs.Commons as Commons
import "BarModel.js" as BarModel

// What a see-through bar is read by. `nova-theme bar` looks at the
// background where the bar is, and picks the ink (of the theme's text colour
// and its background colour, the one that reads there) and the shade behind
// it: the other colour, as strong as that part of the background needs, and
// not at all over one the ink reads on as it is (src/theme/src/bar.rs).
// Until it answers, the bar keeps the theme's solid look; it is asked again
// when the bar's depth, the screen, the theme or the background changes. Its answer
// is drawn at once, as is the way back to the theme's colour: <fades> is off
// until the change has been drawn.
Item {
  id: seeThrough

  // What the bar asks with.
  property bool wanted: false
  property int thickness: 0
  // The size of the screen the background is measured on, in the units of
  // <thickness>.
  property int screenWidth: 0
  property int screenHeight: 0
  property color text
  property color backdrop

  // What the bar draws: whether it is see-through, the colour of its text
  // then, the shade behind it (its colour, and its opacity at the screen's
  // edge, 0 for none), and whether a change of colour may fade.
  property bool shown: false
  property color colour: text
  property color shade: backdrop
  property real strength: 0
  property bool fades: true

  // What picks them; tests/qml/see-through-test.qml sets its own.
  property var pickCommand: ["nova-theme", "bar"]
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
    strength = 0
    fadeAgainSoon()
  }

  function ask() {
    if (wanted) soon.restart()
    else colour = text
  }

  // "<#ink> <#shade> <strength>"; anything else is not an answer.
  function answered(line) {
    if (stale) return
    var picked = /^(#[0-9A-Fa-f]{6}) (#[0-9A-Fa-f]{6}) ([0-9]+(?:\.[0-9]+)?)$/.exec(String(line || "").trim())
    if (!picked) return
    fades = false
    colour = picked[1]
    shade = picked[2]
    strength = Math.max(0, Math.min(1, Number(picked[3])))
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
  onThicknessChanged: ask()
  onScreenWidthChanged: ask()
  onScreenHeightChanged: ask()
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
      picker.command = seeThrough.pickCommand.concat(["top", String(seeThrough.thickness),
        seeThrough.screenWidth + "x" + seeThrough.screenHeight,
        BarModel.hex(seeThrough.text.r, seeThrough.text.g, seeThrough.text.b),
        BarModel.hex(seeThrough.backdrop.r, seeThrough.backdrop.g, seeThrough.backdrop.b)])
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

  // A new theme or background.
  FileView {
    path: Commons.Color.stateHome + "/nova/current"
    watchChanges: true
    printErrors: false
    onFileChanged: seeThrough.ask()
  }
}
