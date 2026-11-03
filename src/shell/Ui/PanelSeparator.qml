import QtQuick
import qs.Commons as Commons

// The one-pixel rule between a panel's sections: the foreground at
// <strength>, faint enough to part the sections without pulling the eye
// from the text and borders round it. It spans its parent.
Rectangle {
  property color foreground: Commons.Color.foreground
  property real strength: 0.12

  implicitWidth: 100
  implicitHeight: 1
  width: parent ? parent.width : implicitWidth
  height: 1
  color: Qt.rgba(foreground.r, foreground.g, foreground.b, strength)
}
