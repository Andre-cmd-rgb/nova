import QtQuick
import qs.Commons
import qs.Commons as Commons

// Small, dimmed text under a setting: what it does, or why it is off.
Text {
  color: Commons.Color.foreground
  opacity: 0.6
  font.family: Style.font.family
  font.pixelSize: Style.font.bodySmall
  wrapMode: Text.WordWrap
  textFormat: Text.PlainText
}
