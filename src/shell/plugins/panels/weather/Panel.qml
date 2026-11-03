import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import qs.Ui as Ui
import "Model.js" as Model

// The weather's panel, under its bar widget (BarWidget.qml): the weather now
// with its glyph, the place, and the next three days. A click on the place,
// or Enter, opens a field to search for another; Enter or a click on a
// suggestion sets it with nova-weather-location, and an empty field goes
// back to the address's town.
//
// wttr.in and Open-Meteo are asked again every refreshMinutes (15 by
// default), and three more times 2.5 s apart when one does not answer; the
// last answers stay on show meanwhile. The rules are in Model.js.
//
// Ui.Panel is named with its module: qmllint cannot see qs.Ui, so a bare
// Panel would be read as this file, which then holds itself through its
// inline components without end.
Ui.Panel {
  id: root
  moduleName: "nova.weather"
  ipcTarget: "nova.weather"

  // Lent by the widget: the button the panel opens under, and the widget
  // itself. The bar knows a panel by the widget in its slot, so the widget
  // is who this panel is to the bar: the popout it holds, the dot under the
  // widget, and the switch to the next panel.
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ------------------------------------------------------- open and close

  // A click on the widget and the IPC open it this way: the bar's centre,
  // which the panel sits over, keeps its peek shut while it is open. The
  // hold is taken after the panel shows, because showing it closes the panel
  // that was open, and that one lets go of the hold as it closes.
  function summon() {
    controller.show()
    placeFile.reload()
    refresh()
    Qt.callLater(function() { if (root.opened) root.holdPeek(true) })
  }

  function open() {
    holdPeek(false)
    controller.show()
    placeFile.reload()
    refresh()
  }

  function close() {
    holdPeek(false)
    if (editing) cancelEditing()
    controller.hide()
  }

  function toggle() {
    if (opened) close()
    else summon()
  }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function holdPeek(shut) {
    if (bar && typeof bar.setCenterHoverRevealSuppressed === "function") bar.setCenterHoverRevealSuppressed(shut)
  }

  // --------------------------------------------------------------- the place

  // The place set, from weather.json ({ name, latitude, longitude }), which
  // nova-weather-location writes; watched, so that an edit by hand counts.
  property var place: ({ name: "", latitude: null, longitude: null })
  readonly property bool hasCoordinates: Model.hasCoordinates(place)
  readonly property string query: Model.wttrQuery(place)
  // The town wttr.in places the address in, while no place is set.
  property string detectedPlace: ""

  // A new place is fetched at once, from scratch; the last weather stays on
  // show meanwhile, and the field, its spinner turning, until it comes.
  onQueryChanged: {
    if (saving) savedFetchStarted = true
    restartFetches()
  }

  FileView {
    id: placeFile
    path: Commons.Color.stateHome + "/nova/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.place = Model.readPlace(text())
    onLoadFailed: root.place = Model.readPlace("")
  }

  // The first read can come too early in the shell's start and miss the
  // file; a second, a moment later, changes nothing when the first was right.
  Timer {
    interval: 1500
    running: true
    onTriggered: placeFile.reload()
  }

  // ------------------------------------------------------------- the weather

  // The services' last answers, kept when a fetch fails.
  property var wttr: null
  property var meteo: null
  // The glyph of the weather now, which is also the widget's.
  property string glyph: ""

  // With a place's coordinates, Open-Meteo's weather now; else wttr.in's,
  // and Open-Meteo's until wttr.in, the slower, answers.
  readonly property var meteoNow: Model.meteoNow(meteo)
  readonly property var now: (hasCoordinates && meteoNow) || Model.wttrNow(wttr) || meteoNow
  readonly property var area: wttr && wttr.nearest_area && wttr.nearest_area[0] ? wttr.nearest_area[0] : null
  readonly property var days: Model.forecastDays(wttr, meteo, Qt.formatDate(new Date(), "yyyy-MM-dd"))
  readonly property string country: area && area.country && area.country[0] ? area.country[0].value : ""
  readonly property bool imperial: Model.imperial(setting("unit", ""), Qt.locale().name, country)
  readonly property var nowText: Model.nowText(now, imperial)
  readonly property string placeName: place.name || detectedPlace || (area && area.areaName && area.areaName[0] ? area.areaName[0].value : "")
  readonly property int refreshMinutes: Math.max(1, parseInt(setting("refreshMinutes", 15), 10) || 15)

  // Each refresh starts with three tries for each service, so that a round
  // that used them up (waking with the network still down) does not leave
  // the next without.
  property int wttrTries: 0
  property int meteoTries: 0

  function refresh() {
    wttrTries = 0
    meteoTries = 0
    if (!wttrFetch.running) wttrFetch.running = true
    if (query === "" && !townFetch.running) townFetch.running = true
    // With the place's coordinates Open-Meteo is asked now, without waiting
    // for wttr.in; without them, once wttr.in has found the area.
    fetchMeteo(null)
  }

  function restartFetches() {
    wttrTries = 0
    meteoTries = 0
    wttrFetch.running = false
    meteoFetch.running = false
    Qt.callLater(refresh)
  }

  // `answer` is wttr.in's latest, for its area; null takes the last one's.
  function fetchMeteo(answer) {
    if (meteoFetch.running) return
    var point = Model.meteoPoint(place, answer && answer.nearest_area && answer.nearest_area[0] ? answer.nearest_area[0] : area)
    if (!point) return
    meteoFetch.command = ["curl", "-fsS", "--max-time", "5", Model.meteoUrl(point)]
    meteoFetch.running = true
  }

  // wttr.in can be slow, above all for a place it has not been asked about
  // before: three more tries before the refresh timer's turn. A place being
  // set without coordinates waits for wttr.in's answer until they are spent.
  function retryWttr() {
    if (wttrTries >= 3) {
      if (!hasCoordinates) savedFetched()
      return
    }
    wttrTries++
    wttrRetry.restart()
  }

  // With the place's coordinates, Open-Meteo alone sets the glyph, so an
  // answer lost (waking before the network) tries again rather than leave
  // an old glyph until the next refresh. A place being set with coordinates
  // waits for Open-Meteo's answer until they are spent.
  function retryMeteo() {
    if (meteoTries >= 3) {
      if (hasCoordinates) savedFetched()
      return
    }
    meteoTries++
    meteoRetry.restart()
  }

  Process {
    id: wttrFetch
    command: ["curl", "-fsS", "--max-time", "10", Model.wttrUrl(root.query)]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.readWttr(text)
    }
  }

  function readWttr(text) {
    var raw = String(text || "").trim()
    var answer
    try {
      answer = JSON.parse(raw)
    } catch (unreadable) {
      retryWttr()
      return
    }
    wttr = answer
    // Without coordinates, wttr.in's answer gives the glyph until
    // Open-Meteo's comes, and a null one is no answer.
    if (!hasCoordinates) {
      if (answer === null) {
        retryWttr()
        return
      }
      if (!glyph) glyph = Model.nowGlyph(Model.wttrNow(answer), "")
    }
    wttrTries = 0
    if (hasCoordinates) return
    savedFetched()
    fetchMeteo(answer)
  }

  Process {
    id: meteoFetch
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.readMeteo(text)
    }
  }

  function readMeteo(text) {
    var answer
    try {
      answer = JSON.parse(String(text || "").trim())
    } catch (unreadable) {
      retryMeteo()
      return
    }
    meteo = answer
    glyph = Model.nowGlyph(Model.meteoNow(answer), glyph)
    meteoTries = 0
    if (hasCoordinates) savedFetched()
  }

  // wttr.in's town for the address, asked while no place is set.
  Process {
    id: townFetch
    command: ["curl", "-fsS", "--max-time", "4", "https://wttr.in/?format=%l"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var town = Model.detectedTown(text)
        if (town !== null) root.detectedPlace = town
      }
    }
  }

  Timer {
    id: wttrRetry
    interval: 2500
    onTriggered: if (!wttrFetch.running) wttrFetch.running = true
  }

  Timer {
    id: meteoRetry
    interval: 2500
    onTriggered: root.fetchMeteo(null)
  }

  Timer {
    interval: root.refreshMinutes * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // ------------------------------------------------------- setting the place

  // The search field in place of the place's name. While a place is being
  // set (`saving`), the field waits, a spinner in place of its clear mark,
  // until the weather for it comes: Open-Meteo's for a place with
  // coordinates, else wttr.in's.
  property bool editing: false
  property bool saving: false
  property bool savedFetchStarted: false
  property var suggestions: []
  property int suggestionIndex: 0
  // The search wanted and the one running: one runs at a time, and the
  // latest wanted follows when it is done.
  property string searchWanted: ""
  property string searchRunning: ""

  function startEditing() {
    editing = true
    saving = false
    savedFetchStarted = false
    suggestions = []
    suggestionIndex = 0
    Qt.callLater(function() {
      placeField.text = root.place.name
      placeField.selectAll()
      placeField.forceActiveFocus()
    })
  }

  function cancelEditing() {
    editing = false
    saving = false
    savedFetchStarted = false
    suggestions = []
    searchWanted = ""
    searchDelay.stop()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  // Enter: the suggestion picked, else the name typed; nothing typed goes
  // back to the address's town.
  function commit() {
    var chosen = Model.chosenPlace(placeField.text, suggestions, suggestionIndex)
    if (chosen.name === "") clearPlace()
    else setPlace(chosen)
  }

  function setPlace(chosen) {
    if (!chosen) return
    saving = true
    savedFetchStarted = false
    place = { name: chosen.name, latitude: chosen.latitude, longitude: chosen.longitude }
    savePlace(chosen.name, chosen.latitude, chosen.longitude)
  }

  function clearPlace() {
    savePlace("", null, null)
    detectedPlace = ""
    cancelEditing()
  }

  // The weather for the place being set has come, or the tries for it are
  // spent: the field closes, the place set, the last weather kept.
  function savedFetched() {
    if (saving && savedFetchStarted) cancelEditing()
  }

  function savePlace(name, latitude, longitude) {
    if (name && latitude !== null && longitude !== null)
      placeSave.command = ["nova-weather-location", "--set", name, latitude + "," + longitude]
    else if (name)
      placeSave.command = ["nova-weather-location", "--set", name]
    else
      placeSave.command = ["nova-weather-location", "--clear"]
    placeSave.running = true
  }

  // The file's watch picks the new place up. A place set again, the same
  // as before, changes no query, so the fetch is started here too, or the
  // spinner would turn for ever.
  Process {
    id: placeSave
    onExited: function(exitCode) {
      if (exitCode !== 0 || !root.saving) return
      placeFile.reload()
      if (root.savedFetchStarted) return
      root.savedFetchStarted = true
      root.restartFetches()
    }
  }

  // Searches 300 ms after the last key, from two letters. Fewer wants no
  // search, so that one still running, for more letters, shows nothing.
  function search() {
    var typed = placeField.text.trim()
    searchWanted = typed.length < 2 ? "" : typed
    if (searchWanted === "") suggestions = []
    else if (!searchFetch.running) startSearch()
  }

  function startSearch() {
    searchRunning = searchWanted
    searchFetch.command = ["curl", "-fsS", "--max-time", "5", Model.searchUrl(searchRunning)]
    searchFetch.running = true
  }

  Process {
    id: searchFetch
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var wanted = root.editing && root.searchWanted !== ""
        root.suggestions = wanted ? Model.suggestions(text) : []
        root.suggestionIndex = 0
        if (wanted && root.searchWanted !== root.searchRunning) Qt.callLater(root.startSearch)
      }
    }
  }

  Timer {
    id: searchDelay
    interval: 300
    onTriggered: root.search()
  }

  // ------------------------------------------------------------- the panel

  // Over the bar's centre. Enter opens the field; while it is open, it
  // takes the keys.
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editing
      onReturnRequested: root.startEditing()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: content
          width: scroller.width
          spacing: Style.space(14)

          // The glyph and the temperature at the left; the place over the
          // feel, wind and humidity at the right.
          Item {
            width: parent.width
            height: Math.max(heroLeft.height, heroRight.height)

            Row {
              id: heroLeft
              anchors.left: parent.left
              anchors.leftMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(16)

              // Drawn larger than the type scale goes: it is the picture of
              // the weather, not text.
              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.verticalCenterOffset: 5
                textFormat: Text.PlainText
                text: root.glyph || "—"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: 64
              }

              Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  id: temperature
                  textFormat: Text.PlainText
                  text: root.nowText.temp || "—"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: 56
                  font.bold: true
                }

                Text {
                  anchors.top: temperature.top
                  anchors.topMargin: Style.space(10)
                  textFormat: Text.PlainText
                  text: root.now ? "°" + (root.imperial ? "F" : "C") : ""
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }

            Column {
              id: heroRight
              width: readings.implicitWidth
              anchors.right: parent.right
              anchors.rightMargin: Style.space(20)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(12)

              Row {
                visible: !root.editing && root.placeName !== ""
                spacing: Style.space(6)

                TapHandler { onTapped: root.startEditing() }
                HoverHandler { cursorShape: Qt.PointingHandCursor }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: ""
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: root.placeName.toUpperCase()
                  color: Qt.darker(root.bar.foreground, 1.4)
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.letterSpacing: 1
                }
              }

              // Down and Up walk the suggestions, Enter sets, Escape leaves.
              Row {
                visible: root.editing
                spacing: Style.space(6)

                TextField {
                  id: placeField
                  width: Style.space(190)
                  enabled: !root.saving
                  placeholderText: "Search city"
                  foreground: root.bar.foreground
                  font.family: root.bar.fontFamily

                  onTextChanged: if (root.editing && !root.saving) searchDelay.restart()

                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) {
                      root.cancelEditing()
                    } else if (event.key === Qt.Key_Down) {
                      if (root.suggestionIndex < root.suggestions.length - 1) root.suggestionIndex++
                    } else if (event.key === Qt.Key_Up) {
                      if (root.suggestionIndex > 0) root.suggestionIndex--
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                      root.commit()
                    } else {
                      return
                    }
                    event.accepted = true
                  }
                }

                // Back to the address's town; while a place is being set,
                // the spinner.
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(18)
                  height: Style.space(18)
                  radius: Math.min(4, Style.cornerRadius)
                  color: !root.saving && clearMouse.containsMouse ? Style.hoverFillFor(root.bar.foreground, Commons.Color.accent) : "transparent"

                  // Two glyphs, so that the ✕ stands upright: the spinner is
                  // stopped wherever its turn is when the place is set.
                  Text {
                    anchors.centerIn: parent
                    visible: !root.saving
                    textFormat: Text.PlainText
                    text: "✕"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    anchors.centerIn: parent
                    visible: root.saving
                    textFormat: Text.PlainText
                    text: "󰦖"
                    color: Qt.darker(root.bar.foreground, 1.4)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall

                    RotationAnimator on rotation {
                      running: root.saving
                      from: 0
                      to: 360
                      duration: 800
                      loops: Animation.Infinite
                    }
                  }

                  MouseArea {
                    id: clearMouse
                    anchors.fill: parent
                    enabled: !root.saving
                    hoverEnabled: true
                    cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                    onClicked: root.clearPlace()
                  }
                }
              }

              Row {
                id: readings
                visible: !!root.now
                spacing: Style.space(36)

                Reading { name: "FEELS"; value: root.nowText.feels }
                Reading { name: "WIND"; value: root.nowText.wind }
                Reading { name: "HUMID"; value: root.nowText.humidity }
              }
            }
          }

          // The places found for the search; the pointer picks as Down and
          // Up do.
          Column {
            visible: root.editing && !root.saving && root.suggestions.length > 0
            width: parent.width
            spacing: 0

            Repeater {
              model: root.suggestions

              Rectangle {
                id: suggestion
                required property var modelData
                required property int index
                readonly property bool picked: index === root.suggestionIndex
                width: parent.width
                height: suggestionText.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: picked ? Style.hoverFillFor(root.bar.foreground, Commons.Color.accent) : "transparent"

                Row {
                  id: suggestionText
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(16)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: suggestion.modelData.name
                    color: suggestion.picked ? Style.hoverStateColor(root.bar.foreground, Commons.Color.accent) : root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: text !== ""
                    textFormat: Text.PlainText
                    text: suggestion.modelData.description
                    color: Qt.darker(root.bar.foreground, 1.5)
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: root.suggestionIndex = suggestion.index
                  onClicked: root.setPlace(suggestion.modelData)
                }
              }
            }
          }

          Text {
            visible: !root.now
            textFormat: Text.PlainText
            text: "Fetching forecast…"
            color: Qt.darker(root.bar.foreground, 1.5)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          Rectangle {
            visible: root.days.length > 0
            width: parent.width
            height: Style.spacing.hairline
            color: root.bar.foreground
            opacity: 0.12
          }

          // The days ahead, centred: each one's glyph beside its name, high
          // and low.
          Item {
            visible: root.days.length > 0
            width: parent.width
            height: daysRow.height

            Row {
              id: daysRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(44)

              Repeater {
                model: root.days

                Row {
                  id: day
                  required property var modelData
                  spacing: Style.space(10)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: day.modelData.glyph
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.display
                  }

                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)

                    Text {
                      textFormat: Text.PlainText
                      text: Model.dayName(day.modelData.date, function(date) { return Qt.formatDate(date, "dddd") }).toUpperCase()
                      color: Qt.darker(root.bar.foreground, 1.4)
                      font.family: root.bar.fontFamily
                      font.pixelSize: Style.font.caption
                      font.letterSpacing: 1
                    }

                    Row {
                      spacing: Style.space(6)

                      Text {
                        textFormat: Text.PlainText
                        text: Model.degrees(root.imperial ? day.modelData.highF : day.modelData.highC)
                        color: root.bar.foreground
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.body
                      }

                      Text {
                        textFormat: Text.PlainText
                        text: Model.degrees(root.imperial ? day.modelData.lowF : day.modelData.lowC)
                        color: Qt.darker(root.bar.foreground, 1.5)
                        font.family: root.bar.fontFamily
                        font.pixelSize: Style.font.body
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  // One of the weather now's readings: its name over its value.
  component Reading: Column {
    id: reading
    property string name
    property string value

    spacing: Style.space(5)

    Text {
      textFormat: Text.PlainText
      text: reading.name
      color: Qt.darker(root.bar.foreground, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.letterSpacing: 1
    }

    Text {
      textFormat: Text.PlainText
      text: reading.value
      color: root.bar.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.title
    }
  }
}
