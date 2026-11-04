import QtQuick
import qs.Commons
import qs.Commons as Commons

// One glyph, centred by its ink rather than by its advance. Icon fonts draw
// many glyphs off the middle of their cell; the glyph is shifted sideways by
// the difference and left on the line's baseline, so a row of icons keeps
// one baseline. The font size is rounded to a whole pixel, which the ink is
// measured at.
Item {
  id: optical

  property string text: ""
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.body
  property color color: Commons.Color.foreground

  readonly property int renderedFontSize: Math.max(1, Math.round(fontSize))
  // The ink's box, at least a pixel wide, and how far its middle is from
  // the middle of the glyph's advance.
  readonly property real tightWidth: Math.max(1, ink.tightBoundingRect.width)
  readonly property real horizontalCorrection: glyph.implicitWidth / 2 - (ink.tightBoundingRect.x + tightWidth / 2)

  TextMetrics {
    id: ink
    text: optical.text
    font.family: optical.fontFamily
    font.pixelSize: optical.renderedFontSize
  }

  Text {
    id: glyph
    anchors.centerIn: parent
    anchors.horizontalCenterOffset: optical.horizontalCorrection
    textFormat: Text.PlainText
    renderType: Text.NativeRendering
    text: optical.text
    color: optical.color
    font.family: optical.fontFamily
    font.pixelSize: optical.renderedFontSize
  }
}
