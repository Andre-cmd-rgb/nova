import QtQuick
import qs.Commons
import qs.Commons as Commons

// The rule between a panel's sections: a pixel high and as wide as what
// holds it, in <foreground> faint enough to part the sections without
// pulling the eye from the words and borders round it.
Rectangle {
  property color foreground: Commons.Color.foreground

  // A layout sizes it by these.
  implicitWidth: 100
  implicitHeight: 1
  width: parent ? parent.width : implicitWidth
  height: implicitHeight
  color: Util.alpha(foreground, 0.12)
}
