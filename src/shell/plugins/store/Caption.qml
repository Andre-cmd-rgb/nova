import QtQuick
import qs.Commons
import qs.Commons as Commons

// Small, dimmed text: a summary under a name, a few words of status.
Text {
  color: Commons.Color.foreground
  opacity: 0.6
  font.family: Style.font.family
  font.pixelSize: Style.font.bodySmall
  wrapMode: Text.WordWrap
  textFormat: Text.PlainText
}
