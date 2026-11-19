import QtQuick
import qs.Commons
import qs.Commons as Commons

// A key of the Calculator: a digit faint, a function a little stronger, an
// operator and = in the theme's accent, each lit by the pointer and the
// press as the theme's controls are. <flashed> is the keyboard pressing it,
// shown as a press; <lit> a switch that is on (2nd).
Rectangle {
  id: key

  required property string label
  required property string kind
  property bool lit: false
  property bool flashed: false
  property real fontSize: Style.font.heading

  signal activated()

  readonly property bool strong: kind === "operator" || kind === "equals"
  readonly property color ink: strong ? Commons.Color.background : Commons.Color.foreground

  radius: Style.cornerRadius
  color: strong ? Commons.Color.accent
    : lit ? Style.selectedFillFor(Commons.Color.foreground, Commons.Color.accent)
    : Util.alpha(Commons.Color.foreground, kind === "digit" ? 0.06 : 0.12)

  // The pointer's and the press's light over the key's own colour.
  Rectangle {
    anchors.fill: parent
    radius: parent.radius
    color: pointer.pressed || key.flashed ? Style.pressedFillFor(key.ink, Commons.Color.accent)
      : pointer.containsMouse ? Style.hoverFillFor(key.ink, Commons.Color.accent)
      : "transparent"

    Behavior on color {
      ColorAnimation { duration: 90 }
    }
  }

  Text {
    anchors.centerIn: parent
    text: key.label
    color: key.ink
    font.family: Style.font.family
    font.pixelSize: key.fontSize
    textFormat: Text.PlainText
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: key.activated()
  }
}
