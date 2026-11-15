import QtQuick
import qs.Commons
import qs.Commons as Commons

// A glyph in the middle of its item, centred by its ink. Icon fonts set many
// glyphs off the middle of their cell, so centring the advance leaves them
// leaning; this measures the ink at the size drawn (<fontSize>, to a whole
// pixel) and moves the glyph sideways by the difference, keeping it on the
// line's baseline so that a row of them shares one.
Item {
  id: glyph

  property string text: ""
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.body
  property color color: Commons.Color.foreground

  // The ink's width, a pixel at the least.
  readonly property real inkWidth: Math.max(1, ink.tightBoundingRect.width)
  readonly property int _pixels: Math.max(1, Math.round(fontSize))

  TextMetrics {
    id: ink
    text: glyph.text
    font.family: glyph.fontFamily
    font.pixelSize: glyph._pixels
  }

  Text {
    anchors.centerIn: parent
    // From the advance's middle to the ink's.
    anchors.horizontalCenterOffset: implicitWidth / 2 - ink.tightBoundingRect.x - glyph.inkWidth / 2
    text: glyph.text
    textFormat: Text.PlainText
    renderType: Text.NativeRendering
    color: glyph.color
    font.family: glyph.fontFamily
    font.pixelSize: glyph._pixels
  }
}
