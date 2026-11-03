import QtQuick
import qs.Commons
import qs.Commons as Commons

// A row that turns one thing on or off: a bold title, a description under it
// if there is one, and a ToggleSwitch at the end that only shows the state.
// The row takes the click, and Return, Enter and Space while it has the
// focus, and sends clicked(); the caller flips <checked>, whatever model is
// behind it. Its face is in the focus state with the focus, in hover-cursor
// under the pointer or the panel's cursor (<hasCursor>), else normal. The
// switch is a pill where the theme's corners are round, unless <rounded> is
// set false.
ControlFace {
  id: toggle

  property string label: ""
  property string description: ""
  property bool checked: false
  property bool hasCursor: false
  property bool rounded: Style.cornerRadius > 0
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family
  property real titleSize: Style.font.subtitle
  property real descriptionSize: Style.font.caption

  readonly property string _state: activeFocus ? "focus" : hasCursor || pointer.containsMouse ? "hover-cursor" : "normal"

  signal clicked()
  signal hovered(bool isHovered)

  tint: foreground
  tintAccent: accent
  fade: 100
  fillState: _state
  edgeState: _state
  radius: Style.cornerRadius
  implicitWidth: Style.space(240)
  implicitHeight: Math.max(54, line.implicitHeight + Style.spacing.huge)

  activeFocusOnTab: true
  Keys.onPressed: function (event) {
    if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter && event.key !== Qt.Key_Space) return
    event.accepted = true
    toggle.clicked()
  }

  Row {
    id: line
    anchors.verticalCenter: parent.verticalCenter
    x: toggle.borderLeft + Style.spacing.rowPaddingX
    width: toggle.width - x - toggle.borderRight - Style.spacing.rowPaddingX
    spacing: Style.spacing.rowPaddingX

    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: line.width - indicator.width - line.spacing
      spacing: Style.spacing.xs

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: toggle.label
        color: toggle.foreground
        font.family: toggle.fontFamily
        font.pixelSize: toggle.titleSize
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: toggle.description !== ""
        textFormat: Text.PlainText
        text: toggle.description
        color: Qt.darker(toggle.foreground, 1.5)
        font.family: toggle.fontFamily
        font.pixelSize: toggle.descriptionSize
        wrapMode: Text.WordWrap
      }
    }

    ToggleSwitch {
      id: indicator
      anchors.verticalCenter: parent.verticalCenter
      interactive: false
      checked: toggle.checked
      rounded: toggle.rounded
      foreground: toggle.foreground
      accent: toggle.accent
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: toggle.clicked()
  }

  HoverHandler {
    onHoveredChanged: toggle.hovered(hovered)
  }
}
