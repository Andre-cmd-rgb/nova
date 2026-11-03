import QtQuick
import qs.Ui

// The night light, lit while the screen is warmed, and its switch.
BarIndicator {
  readonly property var nightlight: bar?.shell?.serviceFor("nova.nightlight")

  active: nightlight ? nightlight.enabled : false
  activeText: "󰔎"
  activeTooltipText: "Day Light"
  inactiveTooltipText: "Night Light"

  onPressed: if (nightlight) nightlight.setNightlight(!active)
}
