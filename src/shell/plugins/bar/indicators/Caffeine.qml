import QtQuick
import qs.Ui

// Lit while Caffeine is on (nova caffeine): no screensaver, no idle lock, and
// a closed lid only turns the screen off, which is easy to forget with the
// laptop in a bag.
BarIndicator {
  readonly property var idle: bar?.shell?.serviceFor("nova.idle")

  lit: idle ? idle.caffeine : false
  glyph: "󰅶"
  tipLit: "Caffeine: the screen stays on"
  tipDark: "Caffeine"

  onClicked: if (bar) bar.run("nova-caffeine toggle")
}
