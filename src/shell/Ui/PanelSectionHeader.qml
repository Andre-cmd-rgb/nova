import QtQuick
import qs.Commons
import qs.Commons as Commons

// The bold caption over a section of a panel ("Wi-Fi networks", "Output
// device"), between a PanelSeparator and the section's rows: the caption
// size, a shade darker than <foreground>. It can hold a network's or a
// device's name, so it is never read as markup.
Text {
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family

  font {
    family: fontFamily
    pixelSize: Style.font.caption
    bold: true
  }
  color: Qt.darker(foreground, 1.4)
  textFormat: Text.PlainText

  // A glyph can rise above the line Text keeps room for, the Nerd Font's by
  // a tenth of its size and other fonts' by more. A caption at the top of a
  // list that clips (Bluetooth's devices, the network's stations) would lose
  // the tops of its letters; this much room above keeps them whole.
  topPadding: Math.ceil(font.pixelSize * 0.15)
}
