import QtQuick
import qs.Commons
import qs.Commons as Commons

// The bold caption over a section of a panel ("Wi-Fi networks", "Output
// device"), between a PanelSeparator and the section's rows. Callers only
// set the text, and it can hold a network's or a device's name, so it is
// never read as markup.
Text {
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.caption

  textFormat: Text.PlainText
  color: Qt.darker(foreground, 1.4)
  font.family: fontFamily
  font.pixelSize: fontSize
  font.bold: true

  // A glyph can rise above the line Text keeps room for, the Nerd Font's by
  // a tenth of its size and other fonts' by more. A caption at the top of a
  // list that clips (Bluetooth's devices, the network's stations) would lose
  // the tops of its letters; this much room above keeps them whole.
  topPadding: Math.ceil(fontSize * 0.15)
}
