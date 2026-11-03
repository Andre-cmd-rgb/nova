import QtQuick
import qs.Commons
import qs.Commons as Commons

// The bold caption over a panel's section ("Wi-Fi networks", "Output
// device"), between a PanelSeparator and the section's rows.
Text {
  property color foreground: Commons.Color.foreground
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.caption

  // A caption can carry a network's or a device's name, which must not be
  // read as markup; callers only set the text, so it is plain text here.
  textFormat: Text.PlainText
  color: Qt.darker(foreground, 1.4)
  font { family: fontFamily; pixelSize: fontSize; bold: true }

  // A glyph can rise above the line Text makes room for: the Nerd Font's by
  // a tenth of its size, other fonts by more. A caption at the top of a list
  // that clips (bluetooth's devices, network's stations) would lose the tops
  // of its letters; this room above keeps them whole.
  topPadding: Math.ceil(fontSize * 0.15)
}
