import QtQuick
import qs.Ui

// Lit while the night light warms the screen; a click switches it.
BarIndicator {
  readonly property var service: bar?.shell?.serviceFor("nova.nightlight")

  lit: !!service && service.enabled
  glyph: "\u{F050E}"
  tipLit: "Day Light"
  tipDark: "Night Light"

  onClicked: if (service) service.setNightlight(!active)
}
