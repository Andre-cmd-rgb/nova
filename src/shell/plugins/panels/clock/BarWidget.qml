import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The clock in the bar: the date and time, in the format kept in shell.json,
// and its panel (Panel.qml), the calendar. A click opens the panel, as a
// clock is clicked to ask the date; a right click steps to the next format,
// and a middle click asks for a timezone.
BarWidget {
  id: root
  moduleName: "nova.clock"

  readonly property var panel: panelLoader.item

  // The minute shown, which the bar's refresh sets at once.
  property date displayDate: clock.date

  // On a side bar the label is a stack of lines, with formats of its own.
  readonly property string formatKey: vertical ? "verticalFormat" : "format"
  readonly property string format: vertical ? setting("verticalFormat", "HH\n—\nmm") : setting("format", "dddd HH:mm")
  readonly property string alternate: vertical ? setting("verticalFormatAlt", "dd\nMMM\n'W'ww\n''yy") : setting("formatAlt", "d MMMM 'W'ww yyyy")
  readonly property var formats: Model.formatRing(format, alternate, Model.formats(vertical))

  readonly property string label: Qt.formatDateTime(displayDate, Model.withWeek(format, displayDate.getFullYear(), displayDate.getMonth(), displayDate.getDate()))
  readonly property var lines: label.split("\n")

  function refresh() {
    displayDate = new Date()
    if (panel) panel.refresh()
  }

  // The next format is written to shell.json, so that the label shown is the
  // one kept. It counts at once; the write comes back from the bar the same.
  function cycleFormat() {
    var next = Model.nextFormat(formats, format)
    if (next === "" || next === format) return
    var entry = { id: moduleName }
    for (var key in settings) if (key !== "id") entry[key] = settings[key]
    entry[formatKey] = next
    settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function") bar.shell.updateEntryInline(moduleName, entry)
  }

  // What the bar calls, through IPC and its popout switching, on the widget
  // in its slot.
  readonly property bool opened: panel ? panel.opened === true : false
  readonly property bool popoutSwitchClosing: panel ? panel.popoutSwitchClosing === true : false

  function open() {
    if (panel) panel.open()
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

  function toggleWeekStart() {
    if (panel) panel.toggleWeekStart()
  }

  // The mark under an open panel: as wide as the label, or on a side bar as
  // tall as one line, as an icon's is, not the whole stack.
  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

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

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: root.displayDate = date
  }

  // Loaded by its file's address: by name, Panel would be qs.Ui's.
  Loader {
    id: panelLoader
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: root.lend()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.label
    labelVisible: !root.vertical
    hasVisualContent: root.vertical ? root.lines.length > 0 : text !== ""
    fixedHeight: root.vertical ? root.lines.length * Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function(which) {
      if (which === Qt.RightButton) root.cycleFormat()
      else if (which === Qt.MiddleButton) { if (root.bar) root.bar.run("nova-menu-timezone") }
      else root.togglePanel()
    }

    // A line a glyph's height each; one longer than three characters a size
    // smaller, to fit the bar's width.
    Column {
      visible: root.vertical
      anchors.fill: parent

      Repeater {
        model: root.lines

        OpticalGlyph {
          required property string modelData
          width: button.width
          height: Style.bar.iconSlot
          text: modelData
          fontFamily: button.fontFamily
          fontSize: modelData.length > 3 ? button.fontSize * 0.9 : button.fontSize
          color: button.foreground
        }
      }
    }
  }
}
