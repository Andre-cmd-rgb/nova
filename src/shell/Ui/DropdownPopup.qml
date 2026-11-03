import QtQuick
import QtQuick.Controls
import qs.Commons

// The open list of a Dropdown: its options in rows, in a popup in the
// dropdown's background with its popup border, a hairline inside the border.
// Eight rows show at most; past that the list scrolls. It opens on the
// chosen option and takes the keys: Up and Down (k and j) move the lit row,
// Return and Enter choose it, Escape closes. The pointer lights the row it
// moves over, and a click chooses the row clicked.
Popup {
  id: popup

  required property Item owner

  readonly property int _count: owner.options.length
  readonly property int _gap: Style.spacing.labelGap

  function _rowsHeight(count) {
    return count * owner.popupRowHeight + Math.max(0, count - 1) * _gap + Style.spacing.xxs
  }

  implicitHeight: Math.min(_rowsHeight(_count), _rowsHeight(8))
  topPadding: Border.top(owner.popupBorderSpec) + Style.spacing.hairline
  rightPadding: Border.right(owner.popupBorderSpec) + Style.spacing.hairline
  bottomPadding: Border.bottom(owner.popupBorderSpec) + Style.spacing.hairline
  leftPadding: Border.left(owner.popupBorderSpec) + Style.spacing.hairline
  focus: true

  onOpened: {
    rows.currentIndex = Math.max(0, owner.indexOf(owner.value))
    rows.forceActiveFocus()
  }

  background: BorderSurface {
    radius: Style.cornerRadius
    color: popup.owner.background
    borderSpec: popup.owner.popupBorderSpec
  }

  contentItem: ListView {
    id: rows

    implicitHeight: contentHeight
    spacing: popup._gap
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    model: popup.owner.options
    currentIndex: -1

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function (event) {
      var last = popup._count - 1
      if (event.key === Qt.Key_Escape) popup.close()
      else if (event.key === Qt.Key_Down || event.text === "j") rows.currentIndex = Math.min(last, rows.currentIndex + 1)
      else if (event.key === Qt.Key_Up || event.text === "k") rows.currentIndex = Math.max(0, rows.currentIndex - 1)
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) popup.owner.choose(rows.currentIndex)
      else return
      event.accepted = true
    }

    // The lit row is drawn as a control under the cursor.
    delegate: Rectangle {
      id: option

      required property var modelData
      required property int index
      readonly property bool lit: index === rows.currentIndex
      readonly property color _fg: popup.owner.foreground
      readonly property color _accent: popup.owner.accent

      width: rows.width
      height: popup.owner.popupRowHeight
      color: lit ? Style.hoverFillFor(_fg, _accent) : "transparent"

      Text {
        anchors.verticalCenter: parent.verticalCenter
        x: Style.spacing.controlPaddingX
        width: option.width - 2 * Style.spacing.controlPaddingX
        textFormat: Text.PlainText
        text: popup.owner.optionLabel(option.modelData)
        color: option.lit ? Style.hoverStateColor(option._fg, option._accent) : option._fg
        font.family: popup.owner.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onPositionChanged: rows.currentIndex = option.index
        onClicked: popup.owner.choose(option.index)
      }
    }
  }
}
