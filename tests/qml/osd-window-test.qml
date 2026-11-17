// platform: wayland
import QtQuick
import Quickshell
import "plugins/osd"

// The OSD's window, the real Osd.qml on a headless compositor: it keeps one
// size whatever it shows, a level, a player's long notice, "Microphone
// muted" and then "Microphone on", and each card sits inside it, at its foot,
// in the middle. A window that took each card's size let Hyprland draw a
// narrower card into the size of the one before, its edge smeared over the
// rest.
ShellRoot {
  id: test

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  Osd { id: osd }

  // The window is no Item: it is among the OSD's data, not its children.
  function windowOf() {
    for (let i = 0; i < osd.data.length; i++) {
      const o = osd.data[i]
      if (o && o.contentItem !== undefined && o.implicitWidth !== undefined) return o
    }
    return null
  }

  readonly property var faces: [
    { value: "40", max: "100", progressText: "40%" },
    { icon: "media-play", message: "A song with a very long name, by a band with a longer one" },
    { icon: "microphone-muted", message: "Microphone muted" },
    { icon: "microphone", message: "Microphone on" },
    { icon: "keyboard", message: "" }
  ]
  property int step: 0
  property var seen: []

  Timer {
    id: next
    interval: 150
    repeat: true
    onTriggered: test.look()
  }

  function look() {
    const window = windowOf()
    if (step > 0 && window) {
      const card = window.contentItem.children[0]
      seen.push({
        width: window.implicitWidth,
        height: window.implicitHeight,
        inside: card.width <= window.implicitWidth && card.height <= window.implicitHeight,
        foot: Math.abs(card.y + card.height - window.implicitHeight) < 0.5,
        // Centred to the whole pixel.
        middle: Math.abs(card.x + card.width / 2 - window.implicitWidth / 2) <= 0.5,
        cardWidth: card.width
      })
    }
    if (step < faces.length) {
      osd.open(JSON.stringify(Object.assign({ duration: "0" }, faces[step])))
      step++
      return
    }
    next.stop()
    const first = seen[0]
    check(window !== null && first.width > 0 && first.height > 0, "the window has a size")
    check(seen.every(s => s.width === first.width && s.height === first.height), "one size for every face")
    check(seen.every(s => s.inside), "every card inside the window")
    check(seen.every(s => s.foot && s.middle), "every card at the window's foot, in the middle")
    check(seen[2].cardWidth > seen[3].cardWidth, "the card itself still takes its words' size")
    console.log("DONE")
    Qt.quit()
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(() => next.start())
}
