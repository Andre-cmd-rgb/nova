import QtQuick
import qs.Commons
import qs.Commons as Commons

// A row that turns one thing on or off: its <label> in bold, a <detail>
// under it when there is one, and at its end a ToggleSwitch that only shows
// <checked>. The row takes the click, and Return, Enter and Space while it
// has the focus, and sends clicked(); the caller flips what <checked> is
// bound to, whatever holds it. Its face is in the focus state with the
// focus, hover-cursor under the pointer, else normal.
ControlFace {
  id: row

  property string label: ""
  property string detail: ""
  property bool checked: false

  readonly property string _state: activeFocus ? "focus" : hand.containsMouse ? "hover-cursor" : "normal"
  readonly property real _pad: Style.spacing.rowPaddingX

  signal clicked()

  fillState: _state
  edgeState: _state
  fade: 100
  radius: Style.cornerRadius
  implicitWidth: Style.space(240)
  implicitHeight: Math.max(54, Math.max(words.implicitHeight, onOff.implicitHeight) + Style.spacing.huge)

  activeFocusOnTab: true
  Keys.onPressed: event => {
    if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter && event.key !== Qt.Key_Space) return
    event.accepted = true
    row.clicked()
  }

  Column {
    id: words
    anchors.verticalCenter: parent.verticalCenter
    x: row.edge.left + row._pad
    width: onOff.x - row._pad - x
    spacing: Style.spacing.xs

    Text {
      width: parent.width
      text: row.label
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }

    Text {
      width: parent.width
      visible: text !== ""
      text: row.detail
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Util.faded(Commons.Color.foreground, 1.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  ToggleSwitch {
    id: onOff
    anchors.verticalCenter: parent.verticalCenter
    x: row.width - row.edge.right - row._pad - width
    pressable: false
    checked: row.checked
  }

  MouseArea {
    id: hand
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: row.clicked()
  }
}
