import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import qs.Ui as Ui
import "Model.js" as Model

// The clock in the bar: the date and time in the format kept in shell.json,
// and under it a panel with the month (Panel.qml). A click opens the panel,
// as one clicks a clock to ask the date; a right click goes on to the next
// format, and a middle click asks for a time zone.
//
// Ui.Panel by its module: qmllint cannot see qs.Ui, and would take a bare
// Panel for the Panel.qml beside this file.
Ui.Panel {
  id: clock
  moduleName: "nova.clock"

  // The clock's minute, which the panel follows past midnight, and the one
  // on the label, which refresh() also sets.
  readonly property date now: tick.date
  property date stamp: tick.date

  // The settings holding the format and its alternate: a side bar stacks
  // the label in lines, and has a pair of its own.
  readonly property var formatKeys: vertical ? ["verticalFormat", "verticalFormatAlt"] : ["format", "formatAlt"]
  readonly property string pattern: setting(formatKeys[0], vertical ? "HH\n—\nmm" : "dddd HH:mm")
  readonly property string alternate: setting(formatKeys[1], vertical ? "dd\nMMM\n'W'ww\n''yy" : "d MMMM 'W'ww yyyy")
  readonly property var ring: Model.formatRing(pattern, alternate, Model.formats(vertical))
  readonly property string label: Qt.formatDateTime(stamp, Model.withWeek(pattern, stamp.getFullYear(), stamp.getMonth(), stamp.getDate()))
  readonly property var lines: label.split("\n")

  // The day weeks start on: the setting's, else the locale's.
  readonly property int weekStart: Model.weekStart(setting("weekStartDay", null), Qt.locale().firstDayOfWeek)

  // The mark under the open panel: as wide as the label, or on a side bar
  // as tall as one of its lines, as an icon's would be.
  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // <changes> written into this widget's entry in shell.json. They count at
  // once, on the label and in the panel; the bar's write comes back the
  // same. With no entry (the widget is not in the layout) they last the
  // session.
  function save(changes) {
    const entry = Object.assign({ id: moduleName }, settings, changes)
    entry.id = moduleName
    settings = entry
    bar?.shell?.updateEntryInline(moduleName, entry)
  }

  // ---- what the bar's IPC asks, beside open, close and the toggle

  function refresh() {
    stamp = new Date()
    view.item?.refresh()
  }

  // The format after this one, kept, so the label shown is the one kept.
  function cycleFormat() {
    const next = Model.nextFormat(ring, pattern)
    if (next !== "" && next !== pattern) save({ [formatKeys[0]]: next })
  }

  // Monday and Sunday, either way; from any other day, Monday.
  function toggleWeekStart() {
    save({ weekStartDay: Model.weekStartName(Model.otherWeekStart(weekStart)) })
  }

  function togglePanel() {
    toggle()
  }

  // ---- the panel

  // It opens on today. The bar's centre, which the panel covers, keeps its
  // peek shut while it is open; the hold is taken once the panel shows, as
  // showing it closes the one open before, which lets go of the hold as it
  // closes.
  function open() {
    view.item?.refresh()
    controller.show()
    Qt.callLater(() => {
      if (clock.opened) clock.holdPeek(true)
    })
  }

  // A life's measures half typed are dropped, not kept for the next time.
  function close() {
    holdPeek(false)
    view.item?.dropLife()
    controller.hide()
  }

  // The bar keeps one hold for the clock and the weather, so each lets go
  // only of a hold it took: closing this one while the other is open, by
  // IPC or by the shell, leaves the other's.
  property bool holdsPeek: false

  function holdPeek(held) {
    if (held === holdsPeek) return
    holdsPeek = held
    bar?.setCenterHoverRevealSuppressed(held)
  }

  SystemClock {
    id: tick
    precision: SystemClock.Minutes
    onDateChanged: clock.stamp = date
  }

  // SystemClock waits on the monotonic clock, which stands still while the
  // machine sleeps: after a wake the bar kept the minute it went to sleep
  // with for up to a minute more. A look every ten seconds puts the wall
  // clock's minute back.
  Timer {
    interval: 10000
    repeat: true
    running: true
    onTriggered: {
      const now = new Date()
      if (Math.floor(now.getTime() / 60000) !== Math.floor(clock.stamp.getTime() / 60000)) clock.stamp = now
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: clock.bar
    text: clock.vertical ? "" : clock.label
    labelVisible: !clock.vertical
    hasVisualContent: clock.vertical ? clock.lines.length > 0 : text !== ""
    fixedHeight: clock.vertical ? clock.lines.length * Style.bar.iconSlot : -1
    horizontalMargin: 8.75
    verticalPadding: 8.75

    onPressed: function (which) {
      if (which === Qt.RightButton) clock.cycleFormat()
      else if (which === Qt.MiddleButton) clock.bar?.run("nova-menu-timezone")
      else clock.toggle()
    }

    // On a side bar the label is a stack of its lines, in the button's
    // face and ink.
    Stack {
      visible: clock.vertical
      anchors.fill: parent
      lines: clock.lines
      face: button.fontFamily
      size: button.fontSize
      ink: button.foreground
    }
  }

  // Over the bar's centre, whichever widget it opens from.
  KeyboardPanel {
    id: popup
    anchorItem: button
    owner: clock
    bar: clock.bar
    open: clock.opened
    centerOnBar: true
    focusTarget: view.item
    contentWidth: popup.fittedContentWidth(Style.space(560))
    contentHeight: popup.fittedContentHeight(view.item ? view.item.implicitHeight : 0)

    // What it shows, and its keys. Loaded by the file's address: by name,
    // Panel would be qs.Ui's.
    Loader {
      id: view
      anchors.fill: parent
      Component.onCompleted: setSource(Qt.resolvedUrl("Panel.qml"), { clock: clock })
    }
  }

  // <lines> one under another, each a glyph's height; a line of more than
  // three characters a size smaller, to fit across the bar.
  component Stack: Column {
    id: stack

    property var lines: []
    property string face
    property real size
    property color ink

    Repeater {
      model: stack.lines

      OpticalGlyph {
        required property string modelData

        width: stack.width
        height: Style.bar.iconSlot
        text: modelData
        fontFamily: stack.face
        fontSize: modelData.length > 3 ? stack.size * 0.9 : stack.size
        color: stack.ink
      }
    }
  }
}
