import QtQuick
import qs.Ui
import qs.Commons

// The keyboard's layout as a short code (EN, DE), shown while it has more
// than one layout to go round; a click moves it on to the next. The reading
// is the plugin's service's (KeyboardLayoutSeat.qml), one for every
// screen's copy: it reads the seat when Hyprland says a layout changed or
// its config was reloaded, after a click, when an input device comes or
// goes, and every ten seconds only until it has a keymap to show. Nothing
// runs while the seat sits still.
BarWidget {
  id: widget
  widgetId: "nova.keyboard-layout"
  sharedId: "nova.keyboard-layout"

  readonly property string code: shared ? shared.code : ""
  readonly property string keymap: shared ? shared.keymap : ""
  readonly property bool several: !shared || shared.several

  visible: code !== "" && several
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function next() {
    shared?.next()
  }

  BarButton {
    id: button
    anchors.fill: parent
    bar: widget.bar
    text: widget.code
    tip: widget.keymap
    fontSize: Style.font.caption
    margin: 6
    onClicked: widget.next()
  }
}
