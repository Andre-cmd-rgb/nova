import QtQuick
import qs.Commons
import qs.Commons as Commons

// One glyph centred by its ink rather than its advance. Icon fonts draw
// many glyphs off the middle of their cell; the glyph is moved sideways by
// the difference, and left on the line's baseline, so a row of icons keeps
// one baseline. <debugBounds> outlines the box and marks the baseline.
Item {
  id: root

  property string text: ""
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.body
  property color color: Commons.Color.foreground
  property bool debugBounds: false

  readonly property int renderedFontSize: Math.max(1, Math.round(fontSize))
  readonly property real tightWidth: Math.max(1, ink.tightBoundingRect.width)
  readonly property real horizontalCorrection: glyph.implicitWidth / 2 - (ink.tightBoundingRect.x + tightWidth / 2)
  readonly property real paintedCenterX: glyph.x + ink.tightBoundingRect.x + tightWidth / 2
  readonly property real baselineY: glyph.y + glyph.baselineOffset

  TextMetrics {
    id: ink
    text: root.text
    font { family: root.fontFamily; pixelSize: root.renderedFontSize }
  }

  Text {
    id: glyph
    anchors.centerIn: parent
    anchors.horizontalCenterOffset: root.horizontalCorrection
    textFormat: Text.PlainText
    renderType: Text.NativeRendering
    text: root.text
    color: root.color
    font { family: root.fontFamily; pixelSize: root.renderedFontSize }
  }

  Rectangle {
    anchors.fill: parent
    visible: root.debugBounds
    color: "transparent"
    border { width: 1; color: "#4488ff" }
  }

  Rectangle {
    visible: root.debugBounds
    y: Math.round(root.baselineY)
    width: parent.width
    height: 1
    color: "#44ff88"
  }
}
