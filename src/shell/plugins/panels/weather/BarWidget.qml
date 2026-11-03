import QtQuick
import qs.Commons
import qs.Ui

// The weather's bar widget: the glyph of the weather now, hidden until the
// first answer, and its panel (Panel.qml). A click opens the panel, a middle
// click asks for the weather again, and a right click sends it as a
// notification.
BarWidget {
  id: root
  moduleName: "nova.weather"

  readonly property var panel: panelLoader.item

  visible: panel && panel.glyph !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // What the bar calls, through IPC and its popout switching, on the widget
  // in its slot. Opening takes the panel's summon, so that the bar's centre
  // keeps its peek shut, as it does for a click.
  readonly property bool opened: panel ? panel.opened === true : false
  readonly property bool popoutSwitchClosing: panel ? panel.popoutSwitchClosing === true : false

  function open() {
    if (panel) panel.summon()
  }

  function close() {
    if (panel) panel.close()
  }

  function togglePanel() {
    if (panel) panel.toggle()
  }

  function closeForPopoutSwitch() {
    if (panel) panel.closeForPopoutSwitch()
  }

  function refresh() {
    if (panel) panel.refresh()
  }

  // The IPC's edit: the panel, with the field for the place open.
  function edit() {
    if (!panel) return
    panel.summon()
    panel.startEditing()
  }

  // The panel takes the bar, its settings and its place from this widget.
  function lend() {
    if (!panel) return
    panel.bar = bar
    panel.settings = settings
    panel.anchorItem = button
    panel.hostWidget = root
  }

  onBarChanged: lend()
  onSettingsChanged: lend()

  // Loaded by its file's address: by name, Panel would be qs.Ui's.
  Loader {
    id: panelLoader
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: root.lend()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.panel ? root.panel.glyph : ""
    slotSize: Style.bar.statusSlot
    // The panel is the detail; a tooltip would only repeat the glyph.
    tooltipText: ""

    onPressed: function(which) {
      if (!root.bar) return
      if (which === Qt.RightButton) root.bar.run("nova-notification-send \"$(nova-weather-status)\"")
      else if (which === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
