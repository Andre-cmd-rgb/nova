import QtQuick
import qs.Commons
import qs.Commons as Commons

// What a plugin's popup panel is built on. A plugin often gives the bar a
// button and a panel from one file; this holds the panel's opening and
// closing, and the plugin its button, its keys and its content.
Item {
  id: root

  property QtObject bar: null
  property string moduleName: ""
  property var settings: ({})
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

  // Closes the panel because another is opening in its place: for that one
  // close, popoutSwitchClosing is set, so the panel can skip its fade.
  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { popoutSwitchClosing = false })
  }

  // Hands over to the bar's next panel in <direction>; false with no bar.
  function switchPanel(direction) {
    return bar && typeof bar.switchPanelFrom === "function" ? bar.switchPanelFrom(root, direction) : false
  }

  // The setting <name> from the panel's entry in shell.json, as BarWidget's.
  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  PanelController {
    id: openState
  }
}
