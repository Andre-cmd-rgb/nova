import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// What the weather's panel shows (the panel is the bar widget's, in
// BarWidget.qml): the weather now, its glyph large, the place, and the next
// three days, all from the widget's forecast (Forecast.qml).
//
// A click on the place, or Enter, puts a field in its place to search for
// another. Down and Up walk the places found, as the pointer does; Enter or
// a click sets one, and an empty field goes back to the address's town. The
// field stays, a spinner in place of its ✕, until the weather for the place
// comes; Escape leaves it.
PanelKeyCatcher {
  id: sheet

  // The bar widget holding the panel: its bar, settings, forecast and
  // opening.
  required property var weather
  readonly property Forecast forecast: weather.forecast

  readonly property color ink: weather.bar ? weather.bar.foreground : Commons.Color.foreground
  readonly property string family: weather.bar ? weather.bar.fontFamily : Style.font.family
  // The two dimmer inks: for names, and for what is said beside them.
  readonly property color soft: Qt.darker(ink, 1.4)
  readonly property color faint: Qt.darker(ink, 1.5)
  readonly property int inset: Style.space(16)

  readonly property bool imperial: Model.imperial(weather.setting("unit", ""), Qt.locale().name, forecast.country)
  readonly property var reading: Model.nowText(forecast.now, imperial)
  readonly property string unit: imperial ? "F" : "C"

  implicitHeight: column.implicitHeight

  // ---- the field for another place

  property bool editing: false
  // The places found for the last search, and the one Enter would set.
  property var found: []
  property int pick: 0
  // The search the field wants and the one running: one runs at a time,
  // and the latest wanted follows when it is done.
  property string wanted: ""
  property string asking: ""

  // The field holds the place's name, chosen whole, to type over.
  function edit() {
    editing = true
    forecast.abandon()
    found = []
    pick = 0
    Qt.callLater(() => {
      field.text = sheet.forecast.place.name
      field.selectAll()
      field.forceActiveFocus()
    })
  }

  // A search not yet asked goes with the field; the place's name is back.
  function leave() {
    editing = false
    forecast.abandon()
    found = []
    wanted = ""
    pause.stop()
    Qt.callLater(() => sheet.forceActiveFocus())
  }

  // Enter: the place picked, else the name typed; nothing typed goes back
  // to the address's town.
  function commit() {
    const chosen = Model.chosenPlace(field.text, found, pick)
    if (chosen.name === "") clear()
    else forecast.choose(chosen)
  }

  function clear() {
    forecast.forget()
    leave()
  }

  // Only within the places found.
  function step(by) {
    const next = pick + by
    if (next >= 0 && next < found.length) pick = next
  }

  // From two letters; fewer want no search, so that one still running, for
  // more letters, shows nothing.
  function search() {
    const typed = field.text.trim()
    wanted = typed.length < 2 ? "" : typed
    if (wanted === "") found = []
    else if (!finder.running) find()
  }

  function find() {
    asking = wanted
    finder.command = ["curl", "-fsS", "--max-time", "5", Model.searchUrl(asking)]
    finder.running = true
  }

  // Shown only while the field still wants a search; then the latest.
  function answer(text) {
    const still = editing && wanted !== ""
    found = still ? Model.suggestions(text) : []
    pick = 0
    if (still && wanted !== asking) Qt.callLater(sheet.find)
  }

  function fieldKey(event) {
    if (event.key === Qt.Key_Escape) leave()
    else if (event.key === Qt.Key_Down) step(1)
    else if (event.key === Qt.Key_Up) step(-1)
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) commit()
    else return
    event.accepted = true
  }

  Process {
    id: finder
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: sheet.answer(text)
    }
  }

  // 300 ms after the last key.
  Timer {
    id: pause
    interval: 300
    onTriggered: sheet.search()
  }

  // The weather for the place set has come, or the tries for it are spent.
  Connections {
    target: sheet.forecast
    function onSettled() {
      sheet.leave()
    }
  }

  // ---- keys

  // The field has every key while it is open.
  blocked: editing

  onReturnRequested: sheet.edit()
  onCloseRequested: sheet.weather.close()
  onTabRequested: direction => sheet.weather.switchPanel(direction)

  Flickable {
    id: scroller
    anchors.fill: parent
    contentWidth: width
    contentHeight: column.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    interactive: contentHeight > height

    Column {
      id: column
      width: scroller.width
      spacing: Style.space(14)

      // The glyph and the temperature at the left; at the right the place,
      // or the field, over the feel, wind and humidity.
      Item {
        width: parent.width
        height: Math.max(figure.height, about.height)

        Row {
          id: figure
          anchors.left: parent.left
          anchors.leftMargin: sheet.inset
          anchors.verticalCenter: parent.verticalCenter
          spacing: sheet.inset

          // Larger than the type scale goes: it is the picture of the
          // weather, not text.
          Label {
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 5
            text: sheet.forecast.glyph || "—"
            font.pixelSize: 64
          }

          Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Label {
              id: number
              text: sheet.reading.temp || "—"
              font.pixelSize: 56
              font.bold: true
            }

            Label {
              anchors.top: number.top
              anchors.topMargin: Style.space(10)
              text: sheet.forecast.now ? "°" + sheet.unit : ""
              font.pixelSize: Style.font.display
            }
          }
        }

        Column {
          id: about
          width: readings.implicitWidth
          anchors.right: parent.right
          anchors.rightMargin: Style.space(20)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(12)

          Row {
            visible: !sheet.editing && sheet.forecast.name !== ""
            spacing: Style.space(6)

            TapHandler { onTapped: sheet.edit() }
            HoverHandler { cursorShape: Qt.PointingHandCursor }

            Label {
              anchors.verticalCenter: parent.verticalCenter
              text: ""
              color: sheet.soft
              font.pixelSize: Style.font.body
            }

            Caption {
              anchors.verticalCenter: parent.verticalCenter
              text: sheet.forecast.name.toUpperCase()
              font.pixelSize: Style.font.body
            }
          }

          Row {
            visible: sheet.editing
            spacing: Style.space(6)

            TextField {
              id: field
              width: Style.space(190)
              enabled: !sheet.forecast.waiting
              placeholderText: "Search city"
              foreground: sheet.ink
              font.family: sheet.family

              onTextChanged: if (sheet.editing && !sheet.forecast.waiting) pause.restart()
              Keys.onPressed: event => sheet.fieldKey(event)
            }

            ClearMark {
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          Row {
            id: readings
            visible: !!sheet.forecast.now
            spacing: Style.space(36)

            Reading { name: "FEELS"; value: sheet.reading.feels }
            Reading { name: "WIND"; value: sheet.reading.wind }
            Reading { name: "HUMID"; value: sheet.reading.humidity }
          }
        }
      }

      Column {
        visible: sheet.editing && !sheet.forecast.waiting && sheet.found.length > 0
        width: parent.width
        spacing: 0

        Repeater {
          model: sheet.found
          Suggestion {}
        }
      }

      Label {
        visible: !sheet.forecast.now
        text: "Fetching forecast…"
        color: sheet.faint
        font.pixelSize: Style.font.bodySmall
        font.italic: true
      }

      Rectangle {
        visible: sheet.forecast.days.length > 0
        width: parent.width
        height: Style.spacing.hairline
        color: sheet.ink
        opacity: 0.12
      }

      Item {
        visible: sheet.forecast.days.length > 0
        width: parent.width
        height: ahead.height

        Row {
          id: ahead
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(44)

          Repeater {
            model: sheet.forecast.days
            Day {}
          }
        }
      }
    }
  }

  // Text in the panel's ink and face.
  component Label: Text {
    textFormat: Text.PlainText
    color: sheet.ink
    font.family: sheet.family
  }

  // A name, spaced and dimmer than what it names.
  component Caption: Label {
    color: sheet.soft
    font.letterSpacing: 1
  }

  // One of the weather now's readings: its name over its value.
  component Reading: Column {
    id: reading

    property string name
    property string value

    spacing: Style.space(5)

    Caption {
      text: reading.name
      color: sheet.faint
      font.pixelSize: Style.font.bodySmall
    }

    Label {
      text: reading.value
      font.pixelSize: Style.font.title
    }
  }

  // Back to the address's town; while a place is being set, the spinner,
  // a glyph of its own so that the ✕ stands upright whenever it stops.
  component ClearMark: Rectangle {
    width: Style.space(18)
    height: Style.space(18)
    radius: Math.min(4, Style.cornerRadius)
    color: !sheet.forecast.waiting && pointer.containsMouse ? Style.hoverFillFor(sheet.ink, Commons.Color.accent) : "transparent"

    Label {
      anchors.centerIn: parent
      visible: !sheet.forecast.waiting
      text: "✕"
      color: sheet.soft
      font.pixelSize: Style.font.bodySmall
    }

    Label {
      anchors.centerIn: parent
      visible: sheet.forecast.waiting
      text: "󰦖"
      color: sheet.soft
      font.pixelSize: Style.font.bodySmall

      RotationAnimator on rotation {
        running: sheet.forecast.waiting
        from: 0
        to: 360
        duration: 800
        loops: Animation.Infinite
      }
    }

    MouseArea {
      id: pointer
      anchors.fill: parent
      enabled: !sheet.forecast.waiting
      hoverEnabled: true
      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: sheet.clear()
    }
  }

  // A place found: its name, and its region and country dimmer. The one
  // picked is lit; the pointer picks as Down and Up do.
  component Suggestion: Rectangle {
    id: suggestion

    required property var modelData
    required property int index
    readonly property bool picked: index === sheet.pick

    width: parent.width
    height: line.implicitHeight + Style.space(12)
    radius: Style.cornerRadius
    color: picked ? Style.hoverFillFor(sheet.ink, Commons.Color.accent) : "transparent"

    Row {
      id: line
      anchors.left: parent.left
      anchors.leftMargin: sheet.inset
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Label {
        text: suggestion.modelData.name
        color: suggestion.picked ? Style.hoverStateColor(sheet.ink, Commons.Color.accent) : sheet.ink
        font.pixelSize: Style.font.body
      }

      Label {
        anchors.verticalCenter: parent.verticalCenter
        visible: text !== ""
        text: suggestion.modelData.description
        color: sheet.faint
        font.pixelSize: Style.font.bodySmall
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onPositionChanged: sheet.pick = suggestion.index
      onClicked: sheet.forecast.choose(suggestion.modelData)
    }
  }

  // A day ahead: its glyph beside its name, high and low, the low dimmer.
  component Day: Row {
    id: day

    required property var modelData

    spacing: Style.space(10)

    Label {
      anchors.verticalCenter: parent.verticalCenter
      text: day.modelData.glyph
      font.pixelSize: Style.font.display
    }

    Column {
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(2)

      Caption {
        text: Model.dayName(day.modelData.date, noon => Qt.formatDate(noon, "dddd")).toUpperCase()
        font.pixelSize: Style.font.caption
      }

      Row {
        spacing: Style.space(6)

        Label {
          text: Model.degrees(sheet.imperial ? day.modelData.highF : day.modelData.highC)
          font.pixelSize: Style.font.body
        }

        Label {
          text: Model.degrees(sheet.imperial ? day.modelData.lowF : day.modelData.lowC)
          color: sheet.faint
          font.pixelSize: Style.font.body
        }
      }
    }
  }
}
