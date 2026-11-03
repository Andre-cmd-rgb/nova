import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import qs.Ui as Ui
import "Model.js" as Model

// The clock's panel, under its bar widget (BarWidget.qml): today's date,
// the share of the year gone, and a month with its ISO week numbers. The
// chevrons, the wheel and the keys step through the months, and a click on
// the date, or t, comes back to today's. The W heading switches the day
// weeks start on.
//
// With Nova's calendar on (plugins/calendar), a day with something on it has
// a dot, and under the month is what the day picked has, today's until a
// click picks another: a task's box ticks the task, and a row, a double
// click on a day, Open Calendar or c opens the calendar on the day.
//
// A double click on the year's rail asks for a year of birth and the years
// to measure a life by; a second rail then shows the share lived, until a
// double click on it puts it away. The rules are in Model.js.
//
// Ui.Panel is named with its module: qmllint cannot see qs.Ui, so a bare
// Panel would be read as this file, which then holds itself through its
// inline components without end.
Ui.Panel {
  id: root
  moduleName: "nova.clock"
  ipcTarget: "nova.clock"

  // Lent by the widget: the button the panel opens under, and the widget
  // itself. The bar knows a panel by the widget in its slot, so the widget
  // is who this panel is to the bar: the popout it holds, the dot under the
  // widget, and the switch to the next panel.
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // The panel is made before the widget lends it the bar.
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int cellWidth: Style.space(52)
  readonly property int cellHeight: Style.space(34)
  readonly property int cellGap: Style.space(2)
  readonly property int weekWidth: Style.space(32)
  readonly property int gutterWidth: Style.space(14)

  // ------------------------------------------------------- open and close

  // Opening comes back to today. The bar's centre, which the panel sits
  // over, keeps its peek shut while it is open; the hold is taken after the
  // panel shows, because showing it closes the panel that was open, and
  // that one lets go of the hold as it closes.
  function open() {
    refresh()
    controller.show()
    Qt.callLater(function() { if (root.opened) root.holdPeek(true) })
  }

  // An edit left open would be waiting, still open, the next time.
  function close() {
    holdPeek(false)
    if (editingLife) stopEditingLife()
    controller.hide()
  }

  function toggle() {
    if (opened) close()
    else open()
  }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function holdPeek(shut) {
    if (bar && typeof bar.setCenterHoverRevealSuppressed === "function") bar.setCenterHoverRevealSuppressed(shut)
  }

  // Today, the month on show, and the calendar, looked up again: a call,
  // which a binding would not follow.
  function refresh() {
    today = new Date()
    showToday()
    pickedKey = todayKey
    if (bar && bar.shell && typeof bar.shell.serviceFor === "function") calendar = bar.shell.serviceFor("nova.calendar")
  }

  // The panel's settings, written to its entry in shell.json. They count at
  // once, here and in the widget, whose own writes (the label's format) start
  // from its copy; the write comes back from the bar the same. Without an
  // entry to write (the widget is not in the layout) they last the session.
  function saveSettings(values) {
    var entry = { id: moduleName }
    for (var kept in settings) if (kept !== "id") entry[kept] = settings[kept]
    for (var key in values) entry[key] = values[key]
    settings = entry
    if (hostWidget && "settings" in hostWidget) hostWidget.settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function") bar.shell.updateEntryInline(moduleName, entry)
  }

  // ------------------------------------------------------------------ today

  property date today: new Date()
  readonly property string todayKey: Model.keyOf(today)

  // Past midnight, the outline moves to the new day, and a month on show
  // because it was today's moves with it.
  SystemClock {
    id: clock
    precision: SystemClock.Minutes
    onDateChanged: {
      if (Model.keyOf(clock.date) === root.todayKey) return
      var following = root.onThisMonth
      root.today = clock.date
      if (following) root.showToday()
    }
  }

  // How much of the year is gone, by today: the month on show is not today.
  readonly property real yearShare: Model.yearShare(today.getFullYear(), today.getMonth(), today.getDate())

  // ------------------------------------------------------------ the month

  property int shownYear: today.getFullYear()
  property int shownMonth: today.getMonth()
  // At noon: a 1st of the month without a midnight (Havana, April 2012) is
  // still named for its month.
  readonly property date shownFirst: new Date(shownYear, shownMonth, 1, 12)
  readonly property bool onThisMonth: shownYear === today.getFullYear() && shownMonth === today.getMonth()

  // The day weeks start on: the setting, else the locale's. Names of days are
  // English, as all of Nova's text is; the first day is the region's custom,
  // not a word.
  readonly property int weekStart: Model.weekStart(setting("weekStartDay", null), Qt.locale().firstDayOfWeek)
  readonly property var english: Qt.locale("en_US")
  readonly property var weekdays: Model.weekdayOrder(weekStart)
  readonly property var weeks: Model.monthGrid(shownYear, shownMonth, weekStart, todayKey)

  function showToday() {
    shownYear = today.getFullYear()
    shownMonth = today.getMonth()
  }

  function stepMonths(delta) {
    var next = Model.stepMonth(shownYear, shownMonth, delta)
    shownYear = next.year
    shownMonth = next.month
  }

  function stepYears(delta) {
    stepMonths(delta * 12)
  }

  // Between Monday and Sunday; from any other start, to Monday.
  function toggleWeekStart() {
    saveSettings({ weekStartDay: Model.weekStartName(Model.otherWeekStart(weekStart)) })
  }

  function weekdayName(day) {
    return String(english.dayName(day, Locale.ShortFormat)).toUpperCase()
  }

  // --------------------------------------------------------- memento mori

  readonly property int born: Model.birthYear(setting("birthYear", 0), today.getFullYear())
  readonly property int lifeSpan: Model.lifeSpan(setting("lifeExpectancy", 0))
  readonly property real lifeShare: Model.lifeShare(Model.age(born, today.getFullYear()), lifeSpan)
  property bool editingLife: false

  function editLife() {
    editingLife = true
    Qt.callLater(function() {
      bornField.text = root.born > 0 ? String(root.born) : ""
      spanField.text = String(root.lifeSpan)
      bornField.selectAll()
      bornField.forceActiveFocus()
    })
  }

  function stopEditingLife() {
    editingLife = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // A year that is not one is no year: the rail goes.
  function saveLife() {
    var year = Model.birthYear(bornField.text, today.getFullYear())
    var span = Model.lifeSpan(spanField.text)
    if (year !== born || span !== lifeSpan) saveSettings({ birthYear: year, lifeExpectancy: span })
    stopEditingLife()
  }

  // The span stays in shell.json, for the next year of birth.
  function forgetLife() {
    if (born > 0) saveSettings({ birthYear: 0 })
  }

  // In either field: Tab goes to the other, Enter saves both, Escape
  // neither.
  function lifeKey(event, other) {
    if (event.key === Qt.Key_Escape) stopEditingLife()
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) saveLife()
    else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
      other.selectAll()
      other.forceActiveFocus()
    } else return
    event.accepted = true
  }

  // ---------------------------------------------------------- the calendar

  property var calendar: null
  // The day whose things are under the month, as its key.
  property string pickedKey: todayKey
  readonly property real pickedDay: dayStart(pickedKey)
  // Read through `items`, so that they follow the calendar's changes.
  readonly property var busy: calendar && calendar.items ? calendar.busyDays(dayStart(weeks[0].days[0].key), dayStart(weeks[5].days[6].key, 1)) : ({})
  readonly property var agenda: calendar && calendar.items ? calendar.agenda(pickedDay) : []
  // The rows shown at most; past them, the last says how many more.
  readonly property int agendaRows: 6

  // The local midnight of a day by its key, or of the day `after` days on.
  function dayStart(key, after) {
    var part = String(key).split("-")
    return new Date(Number(part[0]), Number(part[1]) - 1, Number(part[2]) + (after || 0)).getTime()
  }

  function openCalendar(day) {
    if (!calendar) return
    close()
    calendar.show(day)
  }

  // What a row starts with: a task's time when it has one; an event's
  // start, or "All day", or the end of one from the day before.
  function lead(occurrence) {
    if (occurrence.item.kind === "task") return occurrence.item.dueTime ? calendar.clock(occurrence.start) : ""
    if (occurrence.item.allDay) return "All day"
    return occurrence.start < pickedDay ? "…" + calendar.clock(occurrence.end) : calendar.clock(occurrence.start)
  }

  // ------------------------------------------------------------- the panel

  // Over the bar's centre. The arrows step a month left and right and a
  // year up and down, as do [ ] { }; Enter or t comes back to today.
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingLife
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.stepMonths(dx)
        if (dy !== 0) root.stepYears(dy)
      }
      onActivateRequested: root.showToday()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(key) {
        switch (key.toLowerCase()) {
        case "[": root.stepMonths(-1); break
        case "]": root.stepMonths(1); break
        case "{": root.stepYears(-1); break
        case "}": root.stepYears(1); break
        case "t": root.showToday(); break
        case "c": root.openCalendar(root.pickedDay); break
        case "w": root.toggleWeekStart(); break
        }
      }

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: content.width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height || contentWidth > width

        Column {
          id: content
          // As wide as the month at the least: on a narrow screen the panel
          // scrolls rather than cut off the last days.
          width: Math.max(scroller.width, month.width)
          spacing: Style.space(8)

          // Today, centred; a click on it comes back from another month.
          Item {
            width: parent.width
            height: hero.height

            Row {
              id: hero
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(22)

              // On the date's baseline: centred, it would sit low beside a
              // date with a descender. Larger than the type scale goes, to
              // stand as tall as the date's capitals.
              Text {
                anchors.baseline: heroDate.baseline
                text: "󰃭"
                color: heroMouse.containsMouse ? Style.hoverStateColor(root.foreground, Commons.Color.accent) : root.foreground
                font.family: root.fontFamily
                font.pixelSize: 48
              }

              Text {
                id: heroDate
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: Qt.formatDate(root.today, "MMMM d")
                color: heroMouse.containsMouse ? Style.hoverStateColor(root.foreground, Commons.Color.accent) : root.foreground
                font.family: root.fontFamily
                font.pixelSize: 52
                font.bold: true
              }
            }

            MouseArea {
              id: heroMouse
              x: hero.x
              y: hero.y
              width: hero.width
              height: hero.height
              enabled: !root.onThisMonth
              hoverEnabled: enabled
              cursorShape: Qt.PointingHandCursor
              onClicked: root.showToday()

              PanelToolTip {
                visible: heroMouse.containsMouse
                text: "Back to today"
                fontFamily: root.fontFamily
              }
            }
          }

          // The year's rail, which is also the rule under today. A double
          // click asks for the life's, in its place.
          Item {
            width: parent.width
            height: yearBlock.y + yearBlock.height

            Item {
              id: yearBlock
              y: Style.space(6)
              anchors.horizontalCenter: parent.horizontalCenter
              width: month.width
              height: yearRail.implicitHeight

              TapHandler {
                enabled: !root.editingLife
                onDoubleTapped: root.editLife()
              }

              Row {
                visible: root.editingLife
                anchors.centerIn: parent
                spacing: Style.space(10)

                Caption {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "BORN"
                }

                TextField {
                  id: bornField
                  width: Style.space(70)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "year"
                  foreground: root.foreground
                  font.family: root.fontFamily
                  inputMethodHints: Qt.ImhDigitsOnly
                  Keys.onPressed: function(event) { root.lifeKey(event, spanField) }
                }

                Caption {
                  anchors.verticalCenter: parent.verticalCenter
                  leftPadding: Style.space(6)
                  text: "LIVE TO"
                }

                TextField {
                  id: spanField
                  width: Style.space(60)
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "90"
                  foreground: root.foreground
                  font.family: root.fontFamily
                  inputMethodHints: Qt.ImhDigitsOnly
                  Keys.onPressed: function(event) { root.lifeKey(event, bornField) }
                }
              }

              Rail {
                id: yearRail
                anchors.fill: parent
                visible: !root.editingLife
                name: String(root.today.getFullYear())
                share: root.yearShare
              }
            }
          }

          // The life's rail, once there is a year of birth.
          Item {
            visible: root.born > 0
            width: parent.width
            height: visible ? lifeRail.height : 0

            Rail {
              id: lifeRail
              anchors.horizontalCenter: parent.horizontalCenter
              width: month.width
              height: implicitHeight
              name: "LIFE"
              share: root.lifeShare

              TapHandler {
                onDoubleTapped: root.forgetLife()
              }

              MouseArea {
                id: lifeMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton

                PanelToolTip {
                  visible: lifeMouse.containsMouse
                  text: "Memento Mori"
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          // The month: six weeks, so that the panel is as tall in any month,
          // each with its ISO week at the left, past a gutter. The wheel
          // steps a month.
          Item {
            width: parent.width
            height: month.y + month.height

            WheelHandler {
              onWheel: function(event) {
                // A sideways scroll has no y: it would step forward.
                if (event.angleDelta.y !== 0) root.stepMonths(event.angleDelta.y > 0 ? -1 : 1)
              }
            }

            Column {
              id: month
              // Apart from the rail above, which is solid.
              y: Style.space(18)
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(3)

              Row {
                id: headings
                spacing: root.cellGap

                // The W of the week numbers switches the week's start; its
                // tooltip names the day it switches to, as nothing else says
                // what it does.
                Rectangle {
                  width: root.weekWidth
                  height: Style.space(16)
                  radius: Style.cornerRadius
                  color: weekStartMouse.containsMouse ? Style.hoverFillFor(root.foreground, Commons.Color.accent) : "transparent"

                  Heading {
                    anchors.centerIn: parent
                    text: "W"
                    color: weekStartMouse.containsMouse ? Style.hoverStateColor(root.foreground, Commons.Color.accent) : Qt.darker(root.foreground, 1.9)
                  }

                  MouseArea {
                    id: weekStartMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleWeekStart()
                  }

                  PanelToolTip {
                    visible: weekStartMouse.containsMouse
                    text: "Start weeks on " + root.english.dayName(Model.otherWeekStart(root.weekStart), Locale.LongFormat)
                    fontFamily: root.fontFamily
                  }
                }

                Item {
                  width: root.gutterWidth
                  height: Style.space(16)
                }

                Repeater {
                  model: root.weekdays

                  Heading {
                    required property var modelData
                    width: root.cellWidth
                    height: Style.space(16)
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: root.weekdayName(modelData)
                    color: Qt.darker(root.foreground, 1.5)
                  }
                }
              }

              Repeater {
                model: root.weeks

                Row {
                  id: week
                  required property var modelData
                  spacing: root.cellGap

                  Text {
                    textFormat: Text.PlainText
                    width: root.weekWidth
                    height: root.cellHeight
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    text: week.modelData.week
                    color: Qt.darker(root.foreground, 1.9)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Item {
                    width: root.gutterWidth
                    height: root.cellHeight
                  }

                  Repeater {
                    model: week.modelData.days

                    // Today outlined, as a filled cell would shout in so
                    // quiet a grid; the day picked tinted.
                    Rectangle {
                      id: cell
                      required property var modelData
                      width: root.cellWidth
                      height: root.cellHeight
                      radius: Style.cornerRadius
                      color: modelData.key === root.pickedKey && !modelData.today ? Style.hoverFillFor(root.foreground, Commons.Color.accent) : "transparent"
                      border.width: modelData.today ? Style.spacing.hairline : 0
                      border.color: Style.normalBorderFor(root.foreground, Commons.Color.accent)

                      // Something on the day.
                      Rectangle {
                        visible: root.busy[cell.modelData.key] === true
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.bottom: parent.bottom
                        anchors.bottomMargin: Style.space(4)
                        width: Style.space(4)
                        height: width
                        radius: width / 2
                        color: Style.selectedStateColor(root.foreground, Commons.Color.accent)
                      }

                      TapHandler {
                        enabled: root.calendar !== null
                        onTapped: root.pickedKey = cell.modelData.key
                        onDoubleTapped: root.openCalendar(root.dayStart(cell.modelData.key))
                      }

                      Text {
                        textFormat: Text.PlainText
                        anchors.centerIn: parent
                        text: cell.modelData.day
                        color: !cell.modelData.inMonth ? Qt.darker(root.foreground, 2.2)
                          : cell.modelData.weekend ? Qt.darker(root.foreground, 1.45)
                          : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        font.bold: cell.modelData.today
                      }
                    }
                  }
                }
              }
            }

            // The gutter's hairline, beside the weeks and not the headings.
            Rectangle {
              x: month.x + root.weekWidth + root.cellGap + Math.round((root.gutterWidth - width) / 2)
              y: month.y + headings.height + month.spacing
              width: Style.spacing.hairline
              height: month.height - headings.height - month.spacing
              color: root.foreground
              opacity: 0.1
            }
          }

          // The month's name between the chevrons, which stand at the month's
          // edges, as the rails do. Its width is fixed, so that the chevrons
          // stay put from MAY to SEPTEMBER.
          Item {
            width: parent.width
            height: monthBar.height

            Item {
              id: monthBar
              anchors.horizontalCenter: parent.horizontalCenter
              width: month.width
              height: monthName.implicitHeight + Style.space(10)

              Text {
                id: monthName
                textFormat: Text.PlainText
                anchors.centerIn: parent
                width: Style.space(130)
                horizontalAlignment: Text.AlignHCenter
                text: Qt.formatDate(root.shownFirst, "MMMM yyyy").toUpperCase()
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.letterSpacing: 1
              }

              // Moved out by their padding, so that the glyphs, not the
              // buttons, line up with the rails' ends.
              PanelActionButton {
                anchors.left: parent.left
                anchors.leftMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅁"
                tooltipText: "Previous month"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.stepMonths(-1)
              }

              PanelActionButton {
                anchors.right: parent.right
                anchors.rightMargin: -Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                iconText: "󰅂"
                tooltipText: "Next month"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.stepMonths(1)
              }
            }
          }

          // The day picked, from Nova's calendar: its all-day events, the
          // others by their start, then its tasks.
          Item {
            visible: root.calendar !== null
            width: parent.width
            height: visible ? agendaColumn.height : 0

            Column {
              id: agendaColumn
              anchors.horizontalCenter: parent.horizontalCenter
              width: month.width
              spacing: Style.space(2)

              Rectangle {
                width: parent.width
                height: Style.spacing.hairline
                color: root.foreground
                opacity: 0.1
              }

              Item {
                width: parent.width
                height: openButton.implicitHeight + Style.space(8)

                Caption {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.pickedKey === root.todayKey ? "TODAY" : Qt.formatDate(new Date(root.pickedDay), "ddd d MMMM").toUpperCase()
                  color: Qt.darker(root.foreground, 1.4)
                }

                Button {
                  id: openButton
                  anchors.right: parent.right
                  anchors.rightMargin: -Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Open Calendar"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  onClicked: root.openCalendar(root.pickedDay)
                }
              }

              Text {
                visible: root.agenda.length === 0
                textFormat: Text.PlainText
                height: Style.space(24)
                verticalAlignment: Text.AlignVCenter
                text: "Nothing on this day"
                color: Qt.darker(root.foreground, 1.9)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Repeater {
                model: root.agenda.length > root.agendaRows ? root.agenda.slice(0, root.agendaRows - 1) : root.agenda

                AgendaRow {}
              }

              Text {
                visible: root.agenda.length > root.agendaRows
                textFormat: Text.PlainText
                height: Style.space(22)
                leftPadding: Style.space(6)
                verticalAlignment: Text.AlignVCenter
                text: "+" + (root.agenda.length - root.agendaRows + 1) + " more"
                color: Qt.darker(root.foreground, 1.6)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                TapHandler { onTapped: root.openCalendar(root.pickedDay) }
              }
            }
          }
        }
      }
    }
  }

  // A label in small capitals, dimmer than what it labels.
  component Caption: Text {
    textFormat: Text.PlainText
    color: Qt.darker(root.foreground, 1.5)
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    font.letterSpacing: 1
  }

  // A heading over the month's columns.
  component Heading: Text {
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.letterSpacing: 1
    font.bold: true
  }

  // A share as a rail: its name at the left, its percentage at the right,
  // and between them a track, filled as far as the share goes.
  component Rail: Item {
    id: rail
    property string name
    property real share

    implicitHeight: Math.max(railName.implicitHeight, Style.space(10))

    Caption {
      id: railName
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: rail.name
    }

    Text {
      id: railPercent
      textFormat: Text.PlainText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: Model.percent(rail.share) + "%"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Rectangle {
      anchors.left: railName.right
      anchors.right: railPercent.left
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      height: Style.space(6)
      radius: Style.cornerRadius > 0 ? height / 2 : 0
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

      Rectangle {
        width: Math.round(parent.width * rail.share)
        height: parent.height
        radius: parent.radius
        color: Style.selectedStateColor(root.foreground, Commons.Color.accent)

        Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      }
    }
  }

  // A thing the day picked has: its time, or a task's box, which ticks the
  // task, then its title and place. A click elsewhere on it opens the
  // calendar on the day.
  component AgendaRow: Rectangle {
    id: row
    required property var modelData
    readonly property var item: modelData.item
    readonly property bool task: item.kind === "task"
    readonly property bool done: task && item.done

    width: parent.width
    height: Style.space(26)
    radius: Style.cornerRadius
    color: rowHover.hovered ? Style.hoverFillFor(root.foreground, Commons.Color.accent) : "transparent"

    HoverHandler { id: rowHover }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openCalendar(root.pickedDay)
    }

    Row {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(10)

      Item {
        width: Style.space(64)
        height: Style.space(20)

        Text {
          visible: !row.task || row.item.dueTime
          anchors.left: parent.left
          anchors.leftMargin: row.task ? Style.space(24) : 0
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: root.lead(row.modelData)
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          visible: row.task
          anchors.verticalCenter: parent.verticalCenter
          text: row.done ? "󰄵" : "󰄱"
          color: row.done ? Qt.darker(root.foreground, 1.9) : Style.selectedStateColor(root.foreground, Commons.Color.accent)
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon

          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.space(4)
            cursorShape: Qt.PointingHandCursor
            onClicked: root.calendar.toggleTask(row.modelData.uid)
          }
        }
      }

      Text {
        width: parent.width - x
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: (row.item.title || (row.task ? "Task" : "Event")) + (row.item.location ? "  ·  " + row.item.location : "")
        color: row.done ? Qt.darker(root.foreground, 1.9) : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.strikeout: row.done
        elide: Text.ElideRight
      }
    }
  }
}
