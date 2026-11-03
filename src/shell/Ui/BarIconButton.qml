import QtQuick
import Quickshell
import qs.Commons

// A bar button that shows an icon: a glyph of the icon font, centred by its
// ink in a square canvas, or <iconComponent> drawn in that canvas instead.
// The slot it sits in is <slotSize> along the bar. NOVA_DEBUG_BAR_ICONS=1
// outlines the slot in red and the canvas in blue, to line icons up by eye.
WidgetButton {
  id: root

  property Component iconComponent: null
  property real slotSize: Style.bar.iconSlot
  property real opticalSize: Style.bar.iconCanvas
  property bool debugOpticalBounds: Quickshell.env("NOVA_DEBUG_BAR_ICONS") === "1"

  // How the glyph sits, for tests and for the debug outlines; all 0 when
  // the icon is a component.
  readonly property real opticalCenterErrorX: glyph.visible ? glyph.paintedCenterX - canvas.width / 2 : 0
  readonly property real glyphPaintedWidth: glyph.visible ? glyph.tightWidth : 0
  readonly property real glyphBaselineY: glyph.visible ? glyph.baselineY : 0
  readonly property int glyphFontSize: glyph.visible ? glyph.renderedFontSize : 0

  labelVisible: false
  hasVisualContent: text !== "" || iconComponent !== null
  fontSize: Style.bar.iconFont
  fixedWidth: vertical ? -1 : slotSize
  fixedHeight: vertical ? slotSize : -1

  Item {
    id: canvas
    anchors.centerIn: parent
    width: root.opticalSize
    height: root.opticalSize

    OpticalGlyph {
      id: glyph
      anchors.fill: parent
      visible: root.iconComponent === null
      rotation: root.textRotation
      text: root.text
      fontFamily: root.fontFamily
      fontSize: root.fontSize
      color: root.active && root.useActiveColor ? root.activeColor : root.foreground
      debugBounds: root.debugOpticalBounds
    }

    Loader {
      anchors.fill: parent
      visible: root.iconComponent !== null
      sourceComponent: root.iconComponent
    }

    Rectangle {
      anchors.fill: parent
      visible: root.debugOpticalBounds && root.iconComponent !== null
      color: "transparent"
      border { width: 1; color: "#4488ff" }
    }
  }

  Rectangle {
    anchors.fill: parent
    visible: root.debugOpticalBounds
    color: "transparent"
    border { width: 1; color: "#ff4455" }
  }
}
