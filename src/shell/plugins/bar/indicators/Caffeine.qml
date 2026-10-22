import QtQuick
import qs.Ui

// On while Caffeine is (nova caffeine): no screensaver, no idle lock, and a
// closed lid only turns the screen off, which is easy to forget with the
// laptop in a bag.
BarIndicator {
  id: root

  readonly property var idleService: bar?.shell?.serviceFor("nova.idle")

  active: idleService ? idleService.caffeine : false
  activeText: "󰅶"
  inactiveText: "󰅶"
  activeTooltipText: "Caffeine: the screen stays on"
  inactiveTooltipText: "Caffeine"

  onPressed: function() {
    if (root.bar) root.bar.run("nova-caffeine toggle")
  }
}
