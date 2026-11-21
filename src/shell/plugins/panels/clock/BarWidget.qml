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
  widgetId: "nova.clock"

  // The clock's minute, which the panel follows past midnight, and the one
  // on the label, which refresh() also sets.
  readonly property date now: tick.date
  property date stamp: tick.date

  // The settings holding the format and its alternate.
  readonly property string pattern: setting("format", "dddd HH:mm")
  readonly property string alternate: setting("formatAlt", "d MMMM 'W'ww yyyy")
  readonly property var ring: Model.formatRing(pattern, alternate, Model.FORMATS)
  readonly property string label: Qt.formatDateTime(stamp, Model.withWeek(pattern, stamp.getFullYear(), stamp.getMonth(), stamp.getDate()))

  // The day weeks start on: the setting's, else the locale's.
  readonly property int weekStart: Model.weekStart(setting("weekStartDay", null), Qt.locale().firstDayOfWeek)

  // The mark under the open panel: as wide as the label.
  readonly property real markLength: button.textWidth
  // Its card covers the bar's centre, which keeps the peek shut.
  readonly property bool hidesPeek: true

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // <changes> written into this widget's entry in shell.json. They count at
  // once, on the label and in the panel; the bar's write comes back the
  // same. With no entry (the widget is not in the layout) they last the
  // session.
  function save(changes) {
    const entry = Object.assign({ id: widgetId }, settings, changes)
    entry.id = widgetId
    settings = entry
    bar?.shell?.updateEntryInline(widgetId, entry)
  }

  // ---- what the bar's IPC asks, beside open, close and the toggle

  function refresh() {
    stamp = new Date()
    view.item?.refresh()
  }

  // The format after this one, kept, so the label shown is the one kept.
  function cycleFormat() {
    const next = Model.nextFormat(ring, pattern)
    if (next !== "" && next !== pattern) save({ format: next })
  }

  // Monday and Sunday, either way; from any other day, Monday.
  function toggleWeekStart() {
    save({ weekStartDay: Model.weekStartName(Model.otherWeekStart(weekStart)) })
  }

  function togglePanel() {
    toggle()
  }

  // ---- the panel

  // It opens on today.
  function open() {
    view.item?.refresh()
    opened = true
  }

  // A life's measures half typed are dropped, not kept for the next time.
  function close() {
    view.item?.dropLife()
    opened = false
  }

  SystemClock {
    id: tick
    precision: SystemClock.Minutes
    onDateChanged: clock.stamp = date
  }

  // SystemClock waits on the monotonic clock, which stands still while the
  // machine sleeps: after a wake the bar kept the minute it went to sleep
  // with for up to a minute more. The shell hears of a wake, a clock set and
  // a new time zone (Wake), and puts its minute back then, in the zone's
  // hours, and again at the next minute: SystemClock's own timer is still
  // the one aimed before the sleep, and may come up to a minute late.
  Connections {
    target: Wake
    function onWoke() {
      clock.stamp = new Date()
      nextMinute.interval = 60000 - Date.now() % 60000 + 50
      nextMinute.restart()
    }
  }

  Timer {
    id: nextMinute
    onTriggered: clock.stamp = new Date()
  }

  BarButton {
    id: button
    anchors.fill: parent
    bar: clock.bar
    text: clock.label
    margin: 8.75

    onClicked: function (which) {
      if (which === Qt.RightButton) clock.cycleFormat()
      else if (which === Qt.MiddleButton) clock.bar?.run("nova-menu-timezone")
      else clock.toggle()
    }
  }

  // Over the bar's centre, whichever widget it opens from.
  PanelSurface {
    id: popup
    widget: button
    host: clock
    centred: true
    keys: view.item
    wantWidth: Style.space(560)
    wantHeight: view.item ? view.item.implicitHeight : 0

    // What it shows, and its keys. Loaded by the file's address: by name,
    // Panel would be qs.Ui's.
    Loader {
      id: view
      anchors.fill: parent
      Component.onCompleted: setSource(Qt.resolvedUrl("Panel.qml"), { clock: clock })
    }
  }
}
