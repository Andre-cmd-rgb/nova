import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Commons as Commons

// The button, for everything in a panel that is clicked: a label, an icon,
// or both. Its fill and border come from the theme's [controls] states in
// shell.toml, the first that holds of:
//   pressed               the pressed fill
//   focus (focusable)     the focus fill and border
//   hasCursor, or hover   the hover-cursor fill and border
//   selected              the selected fill; the selected border where the
//                         theme gives it a width, else the normal one when
//                         bordered
//   active                the selected fill
//   at rest               <background>, and the normal border when bordered
// It sends hovered() as the pointer comes and goes, for panels that move
// their own cursor with it.
BorderSurface {
  id: root

  property string text: ""
  property string iconText: ""
  property string tooltipText: ""

  property bool selected: false
  property bool active: false
  property bool hasCursor: false
  property bool focusable: false
  property bool bordered: false

  property color foreground: Commons.Color.foreground
  property color background: "transparent"
  property color accent: Commons.Color.accent

  property string fontFamily: Style.font.family
  property real fontSize: Style.font.body
  property real iconSize: Style.font.icon
  property real iconRotation: 0
  property bool iconSpinning: false
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.controlPaddingY
  property bool leftAlign: false

  // The tooltip, shown when <tooltipText> is set, takes [tooltip]'s colours
  // unless the button gives its own.
  property color tooltipBackground: Commons.Color.tooltip.background
  property color tooltipForeground: Commons.Color.tooltip.text
  property color tooltipBorder: Commons.Color.tooltip.border

  readonly property bool hot: mouseArea.containsMouse || hasCursor
  readonly property bool _showFocusRing: focusable && activeFocus
  readonly property color _selectedColor: Style.selectedStateColor(root.foreground, root.accent)
  readonly property var _tooltipBorderSpec: Border.localOrSurfaceSpec("tooltip", "border", root.tooltipBorder, Commons.Color.tooltip.border, Math.max(1, Style.normalBorderWidth))
  readonly property var _focusBorderSpec: Border.controlSpec("focus", root.foreground, root.accent)
  readonly property var _hoverBorderSpec: Border.controlSpec("hover-cursor", root.foreground, root.accent)
  readonly property var _selectedBorderSpec: Border.controlSpec("selected", root.foreground, root.accent)
  readonly property var _normalBorderSpec: Border.controlSpec("normal", root.foreground, root.accent)

  // Room for the widest border any state can draw, on each side, so the
  // button keeps its size as the pointer or the focus comes to it and does
  // not push the controls beside it.
  readonly property real _reservedBorderTop: Math.max(Border.top(_hoverBorderSpec), Border.top(_selectedBorderSpec),
    focusable ? Border.top(_focusBorderSpec) : 0, bordered ? Border.top(_normalBorderSpec) : 0)
  readonly property real _reservedBorderRight: Math.max(Border.right(_hoverBorderSpec), Border.right(_selectedBorderSpec),
    focusable ? Border.right(_focusBorderSpec) : 0, bordered ? Border.right(_normalBorderSpec) : 0)
  readonly property real _reservedBorderBottom: Math.max(Border.bottom(_hoverBorderSpec), Border.bottom(_selectedBorderSpec),
    focusable ? Border.bottom(_focusBorderSpec) : 0, bordered ? Border.bottom(_normalBorderSpec) : 0)
  readonly property real _reservedBorderLeft: Math.max(Border.left(_hoverBorderSpec), Border.left(_selectedBorderSpec),
    focusable ? Border.left(_focusBorderSpec) : 0, bordered ? Border.left(_normalBorderSpec) : 0)
  readonly property real _reservedContentLeftInset: _reservedBorderLeft + leftPadding

  // The border goes with the fill, state for state. The hover-cursor and
  // focus borders always show, so the keyboard's place is always seen; a
  // plain button has none at rest, nor when selected unless the theme gives
  // selected-border a width.
  readonly property var _borderSpec: {
    if (_showFocusRing) return _focusBorderSpec
    if (hot) return _hoverBorderSpec
    if (selected && Border.controlHasWidth("selected")) return _selectedBorderSpec
    return bordered ? _normalBorderSpec : Border.none()
  }

  signal clicked()
  signal rightClicked()
  signal hovered(bool isHovered)

  implicitWidth: row.implicitWidth + horizontalPadding * 2 + _reservedBorderLeft + _reservedBorderRight
  implicitHeight: row.implicitHeight + verticalPadding * 2 + _reservedBorderTop + _reservedBorderBottom
  leftPadding: horizontalPadding
  rightPadding: horizontalPadding
  topPadding: verticalPadding
  bottomPadding: verticalPadding
  radius: Style.cornerRadius

  color: {
    if (mouseArea.pressed) return Style.pressedFillFor(root.foreground, root.accent)
    if (_showFocusRing) return Style.focusFillFor(root.foreground, root.accent)
    if (hot) return Style.hoverFillFor(root.foreground, root.accent)
    if (selected || active) return Style.selectedFillFor(root.foreground, root.accent)
    return background
  }
  borderSpec: _borderSpec

  activeFocusOnTab: focusable
  Keys.onReturnPressed: if (focusable) root.clicked()
  Keys.onEnterPressed: if (focusable) root.clicked()
  Keys.onSpacePressed: if (focusable) root.clicked()

  Behavior on color {
    ColorAnimation { duration: 120 }
  }

  ToolTip {
    visible: root.tooltipText !== "" && mouseArea.containsMouse
    text: root.tooltipText
    delay: 400
    padding: 0
    background: BorderSurface {
      color: root.tooltipBackground
      borderSpec: root._tooltipBorderSpec
      radius: 0
    }
    contentItem: Text {
      textFormat: Text.PlainText
      text: root.tooltipText
      color: root.tooltipForeground
      font { family: root.fontFamily; pixelSize: Style.font.bodySmall }
      topPadding: Border.top(root._tooltipBorderSpec) + Style.spacing.controlPaddingY
      rightPadding: Border.right(root._tooltipBorderSpec) + Style.spacing.controlPaddingX
      bottomPadding: Border.bottom(root._tooltipBorderSpec) + Style.spacing.controlPaddingY
      leftPadding: Border.left(root._tooltipBorderSpec) + Style.spacing.controlPaddingX
    }
  }

  Row {
    id: row
    anchors.verticalCenter: parent.verticalCenter
    anchors.horizontalCenter: root.leftAlign ? undefined : parent.horizontalCenter
    anchors.left: root.leftAlign ? parent.left : undefined
    anchors.leftMargin: root.leftAlign ? root._reservedContentLeftInset : 0
    spacing: Style.spacing.controlGap

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.iconText !== ""
      textFormat: Text.PlainText
      text: root.iconText
      color: root.selected ? root._selectedColor : root.foreground
      font { family: root.fontFamily; pixelSize: root.iconSize }
      transformOrigin: Item.Center
      rotation: root.iconSpinning ? 0 : root.iconRotation

      // A spinning icon turns once in 0.9 s for as long as it spins.
      RotationAnimation on rotation {
        running: root.iconSpinning
        from: 0
        to: 360
        duration: 900
        loops: Animation.Infinite
      }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.text !== ""
      textFormat: Text.PlainText
      text: root.text
      color: root.selected ? root._selectedColor : root.foreground
      font { family: root.fontFamily; pixelSize: root.fontSize; bold: root.selected }
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onClicked: function(mouse) {
      if (root.focusable) root.forceActiveFocus()
      if (mouse.button === Qt.RightButton) root.rightClicked()
      else root.clicked()
    }
  }

  HoverHandler {
    onHoveredChanged: root.hovered(hovered)
  }
}
