import QtQuick
import qs.Commons

// A bar button that shows an icon instead of a label: a glyph of the icon
// font centred by its ink in a square canvas <opticalSize> across, or
// <iconComponent> drawn in that canvas instead. Along the bar it takes a
// slot <slotSize> long.
WidgetButton {
  id: iconButton

  property Component iconComponent: null
  property real slotSize: Style.bar.iconSlot
  property real opticalSize: Style.bar.iconCanvas

  // How wide the glyph's ink is, for chrome lined up with it; 0 when the
  // icon is a component.
  readonly property real glyphPaintedWidth: glyph.visible ? glyph.tightWidth : 0

  labelVisible: false
  hasVisualContent: text !== "" || iconComponent !== null
  fontSize: Style.bar.iconFont
  fixedWidth: vertical ? -1 : slotSize
  fixedHeight: vertical ? slotSize : -1

  Item {
    anchors.centerIn: parent
    width: iconButton.opticalSize
    height: iconButton.opticalSize

    OpticalGlyph {
      id: glyph
      anchors.fill: parent
      visible: iconButton.iconComponent === null
      rotation: iconButton.textRotation
      text: iconButton.text
      fontFamily: iconButton.fontFamily
      fontSize: iconButton.fontSize
      color: iconButton._ink
    }

    Loader {
      anchors.fill: parent
      visible: iconButton.iconComponent !== null
      sourceComponent: iconButton.iconComponent
    }
  }
}
