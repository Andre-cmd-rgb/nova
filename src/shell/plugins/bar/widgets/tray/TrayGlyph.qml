import QtQuick
import QtQuick.Effects

// A tray icon as Quickshell hands it over, an image:// URL that already
// finds the icons an app keeps outside an icon theme. A symbolic one, named
// "...-symbolic", is meant to take the colour of what it sits on: drawn as
// it is, its fill, often near white, would vanish on a light bar, so it is
// drawn in <tint> instead.
Item {
  id: glyph

  required property var source
  property color tint

  readonly property string url: String(source || "")
  readonly property bool symbolic: url.split("?")[0].endsWith("-symbolic")
  // Decoded at the screen's pixels: at the logical size a PNG blurs on
  // HiDPI.
  readonly property int pixels: Math.round(Math.min(width, height) * Screen.devicePixelRatio)

  Image {
    id: picture
    anchors.fill: parent
    source: glyph.url
    sourceSize.width: glyph.pixels
    sourceSize.height: glyph.pixels
    fillMode: Image.PreserveAspectFit
    // A symbolic one shows through the effect, which reads it as a layer.
    visible: !glyph.symbolic
    layer.enabled: glyph.symbolic
  }

  MultiEffect {
    anchors.fill: picture
    source: picture
    visible: glyph.symbolic
    colorization: 1.0
    colorizationColor: glyph.tint
  }
}
