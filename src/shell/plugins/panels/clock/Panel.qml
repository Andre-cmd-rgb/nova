import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// What the clock's panel shows (the panel is the bar widget's, in
// BarWidget.qml): today's date, the share of the year gone, and a month
// with its ISO weeks (MonthGrid.qml). The chevrons, the wheel and the keys
// turn the month; a click on the date comes back to today's.
//
// With Nova's calendar on (plugins/calendar), a day with something on it
// has a dot, and under the month is what the day chosen holds
// (DayAgenda.qml): today's, until a click chooses another.
//
// A double click on the year's rail asks for a year of birth and a span of
// years to measure a life by; a second rail then shows the share lived,
// until a double click on it puts it away. The rules are in Model.js.
//
// The keys: the arrows, [ ] and { } turn a month or a year; t, Enter and
// Space come back to today; c opens the calendar on the day chosen; w
// switches the day weeks start on.
PanelKeyCatcher {
  id: sheet

  // The bar widget holding the panel: its bar, settings and opening.
  required property var clock

  readonly property color ink: clock.bar ? clock.bar.foreground : Commons.Color.foreground
  readonly property string family: clock.bar ? clock.bar.fontFamily : Style.font.family

  implicitHeight: column.implicitHeight

  // ---- the day, and the month on show

  property date day: new Date()
  readonly property string dayKey: Model.keyOf(day)
  readonly property int year: day.getFullYear()
  readonly property int todayMonth: Model.monthCount(year, day.getMonth())

  // As one number (Model.monthCount), so a turn is a sum.
  property int shown: todayMonth
  readonly property var shownAt: Model.monthAt(shown)
  readonly property bool onToday: shown === todayMonth
  readonly property var weeks: Model.monthGrid(shownAt.year, shownAt.month, clock.weekStart, dayKey)
  readonly property var days: weeks.reduce((all, week) => all.concat(week.days), [])

  // Past midnight the outline goes to the new day, and a month on show
  // because it was today's goes with it.
  readonly property string clockDay: Model.keyOf(clock.now)
  onClockDayChanged: {
    if (clockDay === dayKey) return
    const following = onToday
    day = clock.now
    if (following) backToToday()
  }

  function turn(months) {
    shown += months
  }

  function backToToday() {
    shown = todayMonth
  }

  // On opening: today, its month, its day chosen, and the calendar looked
  // up again, as serviceFor is a call a binding would not follow.
  function refresh() {
    day = new Date()
    backToToday()
    chosen = dayKey
    const shell = clock.bar ? clock.bar.shell : null
    if (shell) calendar = shell.serviceFor("nova.calendar")
  }

  // ---- Nova's calendar, when it is on

  property var calendar: null
  property string chosen: dayKey
  // Read through `items`, so that they follow the calendar's changes.
  readonly property var busy: calendar && calendar.items ? calendar.busyDays(dayStart(days[0].key), dayStart(days[days.length - 1].key, 1)) : ({})
  readonly property var agenda: calendar && calendar.items ? calendar.agenda(dayStart(chosen)) : []

  // The first moment of the day <key>, or of the day <after> days on, as
  // the calendar counts days; NaN with no calendar.
  function dayStart(key, after) {
    return calendar ? calendar.dayStart(key, after) : NaN
  }

  function choose(key) {
    chosen = key
  }

  function openCalendar(key) {
    if (!calendar) return
    clock.close()
    calendar.show(Model.noonOf(key).getTime())
  }

  // ---- a life's measures

  readonly property int born: Model.birthYear(clock.setting("birthYear", 0), year)
  readonly property int span: Model.lifeSpan(clock.setting("lifeExpectancy", 0))
  readonly property real lived: Model.lifeShare(Model.age(born, year), span)
  property bool askingLife: false

  function askLife() {
    askingLife = true
    Qt.callLater(() => lifeForm.begin(sheet.born > 0 ? String(sheet.born) : "", String(sheet.span)))
  }

  function leaveLife() {
    askingLife = false
    Qt.callLater(() => sheet.forceActiveFocus())
  }

  function dropLife() {
    if (askingLife) leaveLife()
  }

  // A year that is no year of birth is none, and the rail goes.
  function keepLife(bornText, spanText) {
    const bornYear = Model.birthYear(bornText, year)
    const years = Model.lifeSpan(spanText)
    if (bornYear !== born || years !== span) clock.save({ birthYear: bornYear, lifeExpectancy: years })
    leaveLife()
  }

  // The span stays in shell.json, for the next year of birth.
  function forgetLife() {
    if (born > 0) clock.save({ birthYear: 0 })
  }

  // ---- keys

  // The fields have every key while a life's measures are asked for.
  blocked: askingLife

  readonly property var turns: ({ "[": -1, "]": 1, "{": -12, "}": 12 })

  function letter(key) {
    if (turns[key]) turn(turns[key])
    else if (key === "t") backToToday()
    else if (key === "c") openCalendar(chosen)
    else if (key === "w") clock.toggleWeekStart()
  }

  onMoveRequested: (dx, dy) => sheet.turn(dx + 12 * dy)
  onActivateRequested: sheet.backToToday()
  onCloseRequested: sheet.clock.close()
  onTabRequested: direction => sheet.clock.switchPanel(direction)
  onTextKey: text => sheet.letter(text.toLowerCase())

  Flickable {
    id: scroller
    anchors.fill: parent
    contentWidth: column.width
    contentHeight: column.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    // Only a screen too small for all of it scrolls.
    interactive: column.implicitHeight > height || grid.width > width

    Column {
      id: column
      // The month's width at the least: on a narrow screen the panel
      // scrolls rather than cut the last days off.
      width: Math.max(scroller.width, grid.width)
      spacing: Style.space(8)

      // Today's date, centred; from another month, a click comes back.
      Item {
        id: hero
        readonly property color shade: heroPointer.containsMouse ? Style.hoverStateColor(sheet.ink, Commons.Color.accent) : sheet.ink

        anchors.horizontalCenter: parent.horizontalCenter
        width: dateLine.width
        height: dateLine.height

        Row {
          id: dateLine
          spacing: Style.space(22)

          // On the date's baseline: centred, it would sit low beside a
          // date with a descender. Larger than the type scale goes, to
          // stand as tall as the date's capitals.
          Text {
            anchors.baseline: dateText.baseline
            text: "󰃭"
            color: hero.shade
            font.family: sheet.family
            font.pixelSize: 48
          }

          Text {
            id: dateText
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: Qt.formatDate(sheet.day, "MMMM d")
            color: hero.shade
            font.family: sheet.family
            font.pixelSize: 52
            font.bold: true
          }
        }

        MouseArea {
          id: heroPointer
          anchors.fill: parent
          enabled: !sheet.onToday
          hoverEnabled: enabled
          cursorShape: Qt.PointingHandCursor
          onClicked: sheet.backToToday()

          PanelToolTip {
            visible: heroPointer.containsMouse
            text: "Back to today"
            fontFamily: sheet.family
          }
        }
      }

      // The year's rail, the rule under today. A double click asks for a
      // life's measures in its place.
      Item {
        anchors.horizontalCenter: parent.horizontalCenter
        width: grid.width
        height: yearLine.y + yearLine.height

        Item {
          id: yearLine
          y: Style.space(6)
          width: parent.width
          height: yearRail.implicitHeight

          TapHandler {
            enabled: !sheet.askingLife
            onDoubleTapped: sheet.askLife()
          }

          LifeForm {
            id: lifeForm
            anchors.centerIn: parent
            visible: sheet.askingLife
            onKept: (bornText, spanText) => sheet.keepLife(bornText, spanText)
            onDropped: sheet.leaveLife()
          }

          Rail {
            id: yearRail
            anchors.fill: parent
            visible: !sheet.askingLife
            name: String(sheet.year)
            share: Model.yearShare(sheet.year, sheet.day.getMonth(), sheet.day.getDate())
          }
        }
      }

      // The life's rail, once there is a year of birth.
      Rail {
        visible: sheet.born > 0
        anchors.horizontalCenter: parent.horizontalCenter
        width: grid.width
        name: "LIFE"
        share: sheet.lived

        TapHandler {
          onDoubleTapped: sheet.forgetLife()
        }

        MouseArea {
          id: lifePointer
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton

          PanelToolTip {
            visible: lifePointer.containsMouse
            text: "Memento Mori"
            fontFamily: sheet.family
          }
        }
      }

      // The month, apart from the solid rail above. The wheel turns it,
      // anywhere across the panel.
      Item {
        width: parent.width
        height: grid.y + grid.height

        WheelHandler {
          onWheel: event => sheet.turn(-Math.sign(event.angleDelta.y))
        }

        MonthGrid {
          id: grid
          y: Style.space(18)
          anchors.horizontalCenter: parent.horizontalCenter
          panel: sheet
        }
      }

      // The month's name between its chevrons, which stand at the month's
      // edges as the rails' ends do. The name is a fixed width, so the
      // chevrons stay put from MAY to SEPTEMBER.
      Item {
        anchors.horizontalCenter: parent.horizontalCenter
        width: grid.width
        height: monthName.implicitHeight + Style.space(10)

        // At noon: a 1st of the month with no midnight (Havana, April 2012)
        // is still named for its month.
        Text {
          id: monthName
          anchors.centerIn: parent
          width: Style.space(130)
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: Qt.formatDate(new Date(sheet.shownAt.year, sheet.shownAt.month, 1, 12), "MMMM yyyy").toUpperCase()
          color: Qt.darker(sheet.ink, 1.4)
          font.family: sheet.family
          font.pixelSize: Style.font.body
          font.letterSpacing: 1
        }

        Chevron {
          anchors.left: parent.left
          months: -1
        }

        Chevron {
          anchors.right: parent.right
          months: 1
        }
      }

      DayAgenda {
        visible: sheet.calendar !== null
        anchors.horizontalCenter: parent.horizontalCenter
        width: grid.width
        panel: sheet
      }
    }
  }

  // A label in small capitals, dimmer than what it names.
  component Caption: Text {
    textFormat: Text.PlainText
    color: Qt.darker(sheet.ink, 1.5)
    font.family: sheet.family
    font.pixelSize: Style.font.bodySmall
    font.letterSpacing: 1
  }

  // A month back (-1) or on (1), whose glyph and tooltip follow. It stands
  // out past the month's edge by its padding, so that the glyph, not the
  // button, lines up with the rails' ends.
  component Chevron: PanelActionButton {
    property int months

    anchors.verticalCenter: parent.verticalCenter
    anchors.margins: -Style.space(8)
    iconText: months < 0 ? "󰅁" : "󰅂"
    tooltipText: months < 0 ? "Previous month" : "Next month"
    foreground: sheet.ink
    fontFamily: sheet.family
    onClicked: sheet.turn(months)
  }

  // A share as a rail: its name at the left, its percentage at the right,
  // and between them a track filled as far as the share goes.
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
      id: railFigure
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: Model.percent(rail.share) + "%"
      color: sheet.ink
      font.family: sheet.family
      font.pixelSize: Style.font.bodySmall
    }

    Rectangle {
      anchors.left: railName.right
      anchors.right: railFigure.left
      anchors.margins: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      height: Style.space(6)
      radius: Style.cornerRadius > 0 ? height / 2 : 0
      color: Qt.alpha(sheet.ink, 0.12)

      Rectangle {
        width: Math.round(parent.width * rail.share)
        height: parent.height
        radius: parent.radius
        color: Style.selectedStateColor(sheet.ink, Commons.Color.accent)

        Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      }
    }
  }

  // A life's measures, asked for in the year rail's place: the year of
  // birth and the age to live to. Tab goes from one to the other, Enter
  // keeps both, Escape neither.
  component LifeForm: Row {
    id: form

    signal kept(string bornText, string spanText)
    signal dropped()

    spacing: Style.space(10)

    function begin(bornText, spanText) {
      birth.input.text = bornText
      reach.input.text = spanText
      birth.take()
    }

    function answer(event, onward) {
      switch (event.key) {
      case Qt.Key_Escape:
        dropped()
        break
      case Qt.Key_Return:
      case Qt.Key_Enter:
        kept(birth.input.text, reach.input.text)
        break
      case Qt.Key_Tab:
      case Qt.Key_Backtab:
        onward.take()
        break
      default:
        return
      }
      event.accepted = true
    }

    Measure {
      id: birth
      caption: "BORN"
      hint: "year"
      fieldWidth: Style.space(70)
      onKey: event => form.answer(event, reach)
    }

    Measure {
      id: reach
      caption: "LIVE TO"
      captionInset: Style.space(6)
      hint: "90"
      fieldWidth: Style.space(60)
      onKey: event => form.answer(event, birth)
    }
  }

  // A caption and the field for a number it names. The field takes its keys
  // before typing them, and has all its text chosen as it takes the focus.
  component Measure: Row {
    id: measure

    property alias caption: label.text
    property alias captionInset: label.leftPadding
    property alias hint: input.placeholderText
    property alias fieldWidth: input.width
    readonly property alias input: input

    signal key(var event)

    spacing: Style.space(10)

    function take() {
      input.selectAll()
      input.forceActiveFocus()
    }

    Caption {
      id: label
      anchors.verticalCenter: parent.verticalCenter
    }

    TextField {
      id: input
      anchors.verticalCenter: parent.verticalCenter
      foreground: sheet.ink
      font.family: sheet.family
      inputMethodHints: Qt.ImhDigitsOnly
      Keys.onPressed: event => measure.key(event)
    }
  }
}
