import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Commons as Commons

// A whole number from <from> to <to>, in steps of <stepSize>: a caption over
// a spin box that takes typing, the arrow keys and the wheel. It sends
// modified() with the number when the user changes it, and hovered() as the
// pointer comes and goes. <field> is the spin box itself.
Column {
  id: root

  property string label: ""
  property int value: 0
  property int from: 0
  property int to: 100
  property int stepSize: 1
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.body
  property real fieldWidth: Style.spacing.numberFieldWidth
  property bool hasCursor: false
  property bool _hovered: false
  property alias field: box

  signal modified(int value)
  signal hovered(bool on)

  spacing: Style.spacing.md

  Text {
    visible: root.label !== ""
    textFormat: Text.PlainText
    text: root.label
    color: Qt.darker(root.foreground, 1.4)
    font { family: root.fontFamily; pixelSize: Style.font.bodySmall }
  }

  QQC.SpinBox {
    id: box

    readonly property bool _focused: activeFocus
    readonly property bool _hot: root._hovered || root.hasCursor
    readonly property var _borderSpec: Border.controlSpec(_focused ? "focus" : _hot ? "hover-cursor" : "normal", root.foreground, root.accent)

    width: root.fieldWidth
    implicitHeight: Math.max(Style.spacing.controlHeight, root.fontSize + Style.spacing.controlPaddingY * 2)
    from: root.from
    to: root.to
    stepSize: root.stepSize
    value: root.value
    editable: true
    font { family: root.fontFamily; pixelSize: root.fontSize }

    topPadding: Border.top(_borderSpec)
    rightPadding: Border.right(_borderSpec) + Style.spacing.controlPaddingX
    bottomPadding: Border.bottom(_borderSpec)
    leftPadding: Border.left(_borderSpec) + Style.spacing.controlPaddingX

    onValueModified: root.modified(value)

    background: BorderSurface {
      radius: Style.cornerRadius
      color: Style.controlFill(box._focused, box._hot, root.foreground, root.accent)
      borderSpec: box._borderSpec

      HoverHandler {
        onHoveredChanged: {
          root._hovered = hovered
          root.hovered(hovered)
        }
      }
    }

    contentItem: TextInput {
      text: box.displayText
      font: box.font
      color: root.foreground
      selectionColor: Style.selectionFillFor(root.foreground, root.accent)
      selectedTextColor: root.foreground
      horizontalAlignment: Qt.AlignHCenter
      verticalAlignment: Qt.AlignVCenter
      readOnly: !box.editable
      validator: box.validator
      inputMethodHints: Qt.ImhFormattedNumbersOnly
    }
  }
}
