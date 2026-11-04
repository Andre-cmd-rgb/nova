import QtQuick
import qs.Commons
import qs.Commons as Commons

// One glyph, centred by its ink rather than by its advance. Icon fonts set
// many glyphs off the middle of their cell, so the glyph is moved sideways
// by the distance between the two middles, and kept on the line's baseline
// so that a row of icons shares one. The ink is measured at the size drawn,
// <fontSize> rounded to a whole pixel.
Item {
  id: optical

  property string text: ""
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.body
  property color color: Commons.Color.foreground

  // How wide the ink is, never under a pixel.
  readonly property real inkWidth: Math.max(1, measure.tightBoundingRect.width)
  readonly property int _pixels: Math.max(1, Math.round(fontSize))

  TextMetrics {
    id: measure
    text: optical.text
    font.family: optical.fontFamily
    font.pixelSize: optical._pixels
  }

  Text {
    // Where the ink's middle is, from the start of the advance.
    readonly property real inkMiddle: measure.tightBoundingRect.x + optical.inkWidth / 2

    anchors.centerIn: parent
    anchors.horizontalCenterOffset: implicitWidth / 2 - inkMiddle
    text: optical.text
    textFormat: Text.PlainText
    renderType: Text.NativeRendering
    font.family: optical.fontFamily
    font.pixelSize: optical._pixels
    color: optical.color
  }
}
