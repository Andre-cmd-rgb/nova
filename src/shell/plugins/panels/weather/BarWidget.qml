import QtQuick
import qs.Commons
import qs.Ui
import qs.Ui as Ui
import "Model.js" as Model

// The weather in the bar: the glyph of the weather now, hidden until the
// first answer, and under it a panel with the rest (Panel.qml). A click
// opens the panel, a middle click asks for the weather again, and a right
// click sends it as a notification. The asking is the forecast's
// (Forecast.qml), every refreshMinutes, 15 by default.
//
// Ui.Panel by its module: qmllint cannot see qs.Ui, and would take a bare
// Panel for the Panel.qml beside this file.
Ui.Panel {
  id: weather
  moduleName: "nova.weather"

  readonly property Forecast forecast: Forecast {
    minutes: Model.refreshMinutes(weather.setting("refreshMinutes", 15))
  }

  visible: forecast.glyph !== ""
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

  // It opens on the place read again and the weather asked for again. The
  // bar's centre, which the panel covers, keeps its peek shut while it is
  // open; the hold is taken once the panel shows, as showing it closes the
  // one open before, which lets go of the hold as it closes.
  function open() {
    controller.show()
    forecast.reread()
    forecast.refresh()
    Qt.callLater(() => {
      if (weather.opened) weather.holdPeek(true)
    })
  }

  // A field left open goes, and the place being set with it stops waiting.
  function close() {
    holdPeek(false)
    if (view.item?.editing) view.item.leave()
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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: weather.bar
    text: weather.forecast.glyph
    slotSize: Style.bar.statusSlot

    onPressed: function (which) {
      if (!weather.bar) return
      if (which === Qt.RightButton) weather.bar.run("nova-notification-send \"$(nova-weather-status)\"")
      else if (which === Qt.MiddleButton) weather.forecast.refresh()
      else weather.toggle()
    }
  }

  // Over the bar's centre, whichever widget it opens from.
  KeyboardPanel {
    id: popup
    anchorItem: button
    owner: weather
    bar: weather.bar
    open: weather.opened
    centerOnBar: true
    focusTarget: view.item
    contentWidth: popup.fittedContentWidth(Style.space(480))
    contentHeight: popup.fittedContentHeight(view.item ? view.item.implicitHeight : 0)

    // What it shows, and its keys. Loaded by the file's address: by name,
    // Panel would be qs.Ui's.
    Loader {
      id: view
      anchors.fill: parent
      Component.onCompleted: setSource(Qt.resolvedUrl("Panel.qml"), { weather: weather })
    }
  }
}
