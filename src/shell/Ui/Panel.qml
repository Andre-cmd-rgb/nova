import QtQuick
import qs.Commons as Commons

// A bar widget with a popup panel, for the plugins that give the bar a
// button and a panel from one file: this holds whether the panel is open,
// and the plugin brings its button, its keys and its content. A plugin may
// give open() and close() of its own; toggle() and closeForPopoutSwitch()
// go through them.
BarWidget {
  id: panel

  property string ipcTarget: ""
  property alias controller: openState
  property bool popoutSwitching: false
  property bool popoutSwitchClosing: false

  readonly property bool opened: openState.open
  readonly property color barForeground: bar ? bar.barForeground : Commons.Color.foreground

  function open() { openState.show() }
  function close() { openState.hide() }

  function toggle() {
    if (opened) close()
    else open()
  }

  // Closes for another panel opening in this one's place. For that one
  // close <popoutSwitchClosing> holds, so the panel can skip its fade.
  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function () { panel.popoutSwitchClosing = false })
  }

  // Hands over to the bar's next panel in <direction>; false with no bar.
  function switchPanel(direction) {
    if (!bar || typeof bar.switchPanelFrom !== "function") return false
    return bar.switchPanelFrom(panel, direction)
  }

  PanelController {
    id: openState
  }
}
