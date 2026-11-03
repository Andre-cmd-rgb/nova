import QtQuick
import qs.Commons
import qs.Commons as Commons

// The one-pixel rule between a panel's sections, as wide as its parent: the
// foreground at <strength>, faint enough to part the sections without
// pulling the eye from the words and borders round it.
Rectangle {
  property color foreground: Commons.Color.foreground
  property real strength: 0.12

  implicitWidth: 100
  implicitHeight: 1
  width: parent ? parent.width : implicitWidth
  height: 1
  color: Util.alpha(foreground, strength)
}
