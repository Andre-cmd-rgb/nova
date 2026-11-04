import QtQuick
import qs.Commons
import qs.Commons as Commons

// A row that turns one thing on or off: a bold title, a description under it
// if there is one, and a ToggleSwitch at the end that only shows the state.
// The row takes the click, and Return, Enter and Space while it has the
// focus, and sends clicked(); the caller flips <checked>, whatever model is
// behind it. Its face is in the focus state with the focus, in hover-cursor
// under the pointer, else normal.
ControlFace {
  id: toggle

  property string label: ""
  property string description: ""
  property bool checked: false

  readonly property string _look: activeFocus ? "focus" : pointer.containsMouse ? "hover-cursor" : "normal"

  signal clicked()

  fillState: _look
  edgeState: _look
  fade: 100
  radius: Style.cornerRadius
  implicitWidth: Style.space(240)
  implicitHeight: Math.max(54, row.implicitHeight + Style.spacing.huge)

  activeFocusOnTab: true
  Keys.onPressed: function (event) {
    if ([Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space].indexOf(event.key) < 0) return
    event.accepted = true
    toggle.clicked()
  }

  // The words, then the switch, between the borders and the row's padding.
  Row {
    id: row

    readonly property real inset: Style.spacing.rowPaddingX

    anchors.verticalCenter: parent.verticalCenter
    x: toggle.borderLeft + inset
    width: toggle.width - x - toggle.borderRight - inset
    spacing: inset

    Column {
      anchors.verticalCenter: parent.verticalCenter
      width: row.width - onOff.width - row.spacing
      spacing: Style.spacing.xs

      Text {
        width: parent.width
        text: toggle.label
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: Commons.Color.foreground
        font {
          family: Style.font.family
          pixelSize: Style.font.subtitle
          bold: true
        }
      }

      Text {
        width: parent.width
        visible: text !== ""
        text: toggle.description
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Qt.darker(Commons.Color.foreground, 1.5)
        font {
          family: Style.font.family
          pixelSize: Style.font.caption
        }
      }
    }

    ToggleSwitch {
      id: onOff
      anchors.verticalCenter: parent.verticalCenter
      interactive: false
      checked: toggle.checked
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: toggle.clicked()
  }
}
