import QtQuick
import qs.Ui

// Lit while the night light warms the screen; a click switches it.
BarIndicator {
  readonly property var service: bar?.shell?.serviceFor("nova.nightlight")

  active: !!service && service.enabled
  activeText: "\u{F050E}"
  activeTooltipText: "Day Light"
  inactiveTooltipText: "Night Light"

  onPressed: if (service) service.setNightlight(!active)
}
