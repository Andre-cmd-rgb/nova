import QtQuick
import qs.Commons

// A bar button that is an icon: <glyph>, a character of the icon font,
// centred by its ink. Every icon sits in a square of the bar's icon size in
// the middle of its button, so that icons side by side line up, and the
// button is <slot> long along the bar whatever the glyph.
BarButton {
  id: icon

  property string glyph: ""
  property real slot: Style.bar.iconSlot

  // The ink's width, for marks lined up with the glyph rather than the slot.
  readonly property real inkWidth: glyph !== "" ? mark.inkWidth : 0

  hasContent: glyph !== ""
  fontSize: Style.bar.iconFont
  implicitWidth: slot
  implicitHeight: thickness

  CentredGlyph {
    id: mark
    anchors.centerIn: parent
    width: Style.bar.iconCanvas
    height: Style.bar.iconCanvas
    text: icon.glyph
    fontFamily: icon.fontFamily
    fontSize: icon.fontSize
    color: icon.ink
  }
}
