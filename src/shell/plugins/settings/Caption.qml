import QtQuick
import qs.Commons
import qs.Commons as Commons

// Small, dimmed text under a setting: a few words of live status (a network,
// a time, a count), or an error and what to do. Never what the setting does:
// its label says that.
Text {
  color: Commons.Color.foreground
  opacity: 0.6
  font.family: Style.font.family
  font.pixelSize: Style.font.bodySmall
  wrapMode: Text.WordWrap
  textFormat: Text.PlainText
}
