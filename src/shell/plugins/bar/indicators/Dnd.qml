import QtQuick
import qs.Ui

// Lit while notifications are held back (do not disturb); a click switches
// that.
BarIndicator {
  readonly property var service: bar?.shell?.serviceFor("nova.notifications")

  active: !!service && service.doNotDisturb
  activeText: "\u{F009B}"
  activeTooltipText: "Allow Notifications"
  inactiveTooltipText: "Silence Notifications"

  onPressed: if (service) service.setDoNotDisturb(!service.doNotDisturb)
}
