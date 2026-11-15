import QtQuick
import qs.Ui

// Lit while notifications are held back (do not disturb); a click switches
// that.
BarIndicator {
  readonly property var service: bar?.shell?.serviceFor("nova.notifications")

  lit: !!service && service.doNotDisturb
  glyph: "\u{F009B}"
  tipLit: "Allow Notifications"
  tipDark: "Silence Notifications"

  onClicked: if (service) service.setDoNotDisturb(!service.doNotDisturb)
}
