import QtQuick
import qs.Commons
import qs.Commons as Commons

// A row that turns something on or off: a title, a description under it if
// there is one, and a ToggleSwitch at the end. A click anywhere on the row,
// or Return, Enter or Space with the focus on it, sends clicked(); the
// caller changes <checked>, so the row works with any model behind it.
// The cursor (<hasCursor> or the pointer) and the focus take the
// hover-cursor and focus states, as every other control does; the switch is
// a pill when the theme's corners are round, unless <rounded> says not.
BorderSurface {
  id: root

  property string label: ""
  property string description: ""
  property bool checked: false
  // The panel cursor is on it, as Button's <hasCursor>.
  property bool hasCursor: false
  property bool rounded: Style.cornerRadius > 0
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family
  property real titleSize: Style.font.subtitle
  property real descriptionSize: Style.font.caption

  readonly property bool _hot: hasCursor || pointer.containsMouse
  readonly property var _borderSpec: Border.controlSpec(activeFocus ? "focus" : _hot ? "hover-cursor" : "normal", foreground, accent)

  signal clicked()
  signal hovered(bool isHovered)

  implicitWidth: Style.space(240)
  implicitHeight: Math.max(54, content.implicitHeight + Style.spacing.huge)
  radius: Style.cornerRadius
  color: Style.controlFill(activeFocus, _hot, foreground, accent)
  borderSpec: _borderSpec

  activeFocusOnTab: true
  Keys.onReturnPressed: root.clicked()
  Keys.onEnterPressed: root.clicked()
  Keys.onSpacePressed: root.clicked()

  Behavior on color {
    ColorAnimation { duration: 100 }
  }

  Row {
    id: content
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: root.borderLeft + Style.spacing.rowPaddingX
    anchors.rightMargin: root.borderRight + Style.spacing.rowPaddingX
    spacing: Style.spacing.rowPaddingX

    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: parent.width - knob.width - parent.spacing
      spacing: Style.spacing.xs

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.label
        color: root.foreground
        font { family: root.fontFamily; pixelSize: root.titleSize; bold: true }
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        visible: root.description !== ""
        textFormat: Text.PlainText
        text: root.description
        color: Qt.darker(root.foreground, 1.5)
        font { family: root.fontFamily; pixelSize: root.descriptionSize }
        wrapMode: Text.WordWrap
      }
    }

    // Only shown: the row takes the click.
    ToggleSwitch {
      id: knob
      anchors.verticalCenter: parent.verticalCenter
      interactive: false
      checked: root.checked
      rounded: root.rounded
      foreground: root.foreground
      accent: root.accent
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: root.clicked()
  }

  HoverHandler {
    onHoveredChanged: root.hovered(hovered)
  }
}
