import QtQuick
import qs.Ui

// Do not disturb: lit while notifications are held back, and the switch.
BarIndicator {
  readonly property var notifications: bar?.shell?.serviceFor("nova.notifications")

  active: notifications ? notifications.doNotDisturb : false
  activeText: "󰂛"
  activeTooltipText: "Allow Notifications"
  inactiveTooltipText: "Silence Notifications"

  onPressed: if (notifications) notifications.setDoNotDisturb(!notifications.doNotDisturb)
}
