import QtQuick
import qs.Commons
import qs.Ui
import qs.Ui as Ui

// The weather in the bar: the glyph of the weather now, hidden until the
// first answer, and under it a panel with the rest (Panel.qml). A click
// opens the panel, a middle click asks for the weather again, and a right
// click sends it as a notification. The asking is the forecast's
// (Forecast.qml), the plugin's service, one for every screen's copy: every
// refreshMinutes, 15 by default, and twice that on battery.
//
// Ui.Panel by its module: qmllint cannot see qs.Ui, and would take a bare
// Panel for the Panel.qml beside this file.
Ui.Panel {
  id: weather
  widgetId: "nova.weather"
  sharedId: "nova.weather"

  readonly property Forecast forecast: shared

  visible: !!forecast && forecast.glyph !== ""
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- what the bar's IPC asks, beside open, close and the toggle

  // The toggle by its IPC name, which the clock's shares.
  function togglePanel() {
    toggle()
  }

  // The panel, with the field for another place open.
  function edit() {
    open()
    view.item?.edit()
  }

  // ---- the panel

  onForecastChanged: loadView()

  function loadView() {
    if (forecast && !view.item) view.setSource(Qt.resolvedUrl("Panel.qml"), { weather: weather })
  }

  // Its card covers the bar's centre, which keeps the peek shut.
  readonly property bool hidesPeek: true

  // It opens on the place read again and the weather asked for again.
  function open() {
    opened = true
    if (!forecast) return
    forecast.reread()
    forecast.refresh()
  }

  // A field left open goes, and the place being set with it stops waiting.
  function close() {
    if (view.item?.editing) view.item.leave()
    opened = false
  }

  BarIcon {
    id: button
    anchors.fill: parent
    bar: weather.bar
    glyph: weather.forecast ? weather.forecast.glyph : ""
    slot: Style.bar.statusSlot

    onClicked: function (which) {
      if (!weather.bar) return
      if (which === Qt.RightButton) weather.bar.run("nova-notification-send \"$(nova-weather-status)\"")
      else if (which === Qt.MiddleButton) weather.forecast?.refresh()
      else weather.toggle()
    }
  }

  // Over the bar's centre, whichever widget it opens from.
  PanelSurface {
    id: popup
    widget: button
    host: weather
    centred: true
    keys: view.item
    wantWidth: Style.space(480)
    wantHeight: view.item ? view.item.implicitHeight : 0

    // What it shows, and its keys, once there is a forecast to show. Loaded
    // by the file's address: by name, Panel would be qs.Ui's.
    Loader {
      id: view
      anchors.fill: parent
      Component.onCompleted: weather.loadView()
    }
  }
}
