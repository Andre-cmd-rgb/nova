import QtQuick
import qs.Ui

// Lit while Caffeine is on (nova caffeine): no screensaver, no idle lock, and
// a closed lid only turns the screen off, which is easy to forget with the
// laptop in a bag.
BarIndicator {
  readonly property var idle: bar?.shell?.serviceFor("nova.idle")

  active: idle ? idle.caffeine : false
  activeText: "󰅶"
  activeTooltipText: "Caffeine: the screen stays on"
  inactiveTooltipText: "Caffeine"

  onPressed: if (bar) bar.run("nova-caffeine toggle")
}
