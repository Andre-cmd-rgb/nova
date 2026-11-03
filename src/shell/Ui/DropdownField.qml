import QtQuick
import qs.Commons

// The closed face of Dropdown: a bold caption over a field that shows
// <text>, with a chevron at its end. The popup, declared inside it, belongs
// to the field (<field>) and is <popupItem>: a click on the field opens or
// closes it, and so do Return, Enter, Space and Down while the field has
// the focus; Escape closes it. The pointer, the focus and the panel cursor
// take the controls' states.
Column {
  id: root

  property string label: ""
  property bool showLabel: true
  property string text: ""
  property color foreground
  property color accent
  property string fontFamily
  property int rowHeight
  property bool hasCursor: false
  property var popupItem: null
  readonly property alias field: field
  default property alias fieldData: field.data

  signal hovered(bool isHovered)

  function togglePopup() {
    if (popupItem.opened) popupItem.close()
    else popupItem.open()
  }

  spacing: Style.spacing.labelGap

  Text {
    visible: root.showLabel && root.label !== ""
    textFormat: Text.PlainText
    text: root.label
    color: Qt.darker(root.foreground, 1.4)
    font { family: root.fontFamily; pixelSize: Style.font.caption; bold: true }
  }

  BorderSurface {
    id: field

    readonly property bool _focused: activeFocus
    readonly property bool _hot: pointer.hovered || root.hasCursor

    width: parent.width
    height: root.rowHeight
    radius: Style.cornerRadius
    color: Style.controlFill(_focused, _hot, root.foreground, root.accent)
    borderSpec: Border.controlSpec(_focused ? "focus" : _hot ? "hover-cursor" : "normal", root.foreground, root.accent)
    activeFocusOnTab: true

    Keys.onPressed: function(event) {
      var key = event.key
      if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Space || key === Qt.Key_Down) {
        root.togglePopup()
        event.accepted = true
      } else if (key === Qt.Key_Escape && root.popupItem.opened) {
        root.popupItem.close()
        event.accepted = true
      }
    }

    HoverHandler {
      id: pointer
      onHoveredChanged: root.hovered(hovered)
    }

    Text {
      anchors.left: parent.left
      anchors.right: chevron.left
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: field.borderLeft + Style.spacing.controlPaddingX
      anchors.rightMargin: field.borderRight + Style.spacing.md
      textFormat: Text.PlainText
      text: root.text
      color: root.foreground
      font { family: root.fontFamily; pixelSize: Style.font.body }
      elide: Text.ElideRight
    }

    Text {
      id: chevron
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.rightMargin: field.borderRight + Style.spacing.controlGap
      text: "󰅀"
      color: Qt.darker(root.foreground, 1.2)
      font { family: root.fontFamily; pixelSize: Style.font.body }
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        field.forceActiveFocus()
        root.togglePopup()
      }
    }
  }
}
