import QtQuick
import qs.Commons

// A bar button with an icon for its label: a glyph of the icon font, centred
// by its ink, or <iconComponent> drawn instead. The icon sits in a square of
// the bar's icon size in the middle of the button, the same square on every
// button so that their icons line up; along the bar the button is
// <slotSize> long.
WidgetButton {
  id: iconButton

  property Component iconComponent: null
  property real slotSize: Style.bar.iconSlot

  // How wide the glyph's ink is, for chrome lined up with the icon rather
  // than the slot; 0 while no glyph shows.
  readonly property real glyphPaintedWidth: glyph.visible ? glyph.inkWidth : 0

  hasVisualContent: text !== "" || iconComponent !== null
  labelVisible: false
  fontSize: Style.bar.iconFont
  fixedWidth: vertical ? -1 : slotSize
  fixedHeight: vertical ? slotSize : -1

  Item {
    anchors.centerIn: parent
    width: Style.bar.iconCanvas
    height: width

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
      active: iconButton.iconComponent !== null
      sourceComponent: iconButton.iconComponent
    }
  }
}
