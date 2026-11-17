import QtQuick
import qs.Commons
import qs.Commons as Commons

// How far an install is: the track, filled to <fraction> (0 to 1); while
// that is not known (the password asked for, an app building), a short
// piece of it going to and fro.
Item {
  id: line

  property real fraction: -1

  implicitHeight: Style.space(4)

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius > 0 ? height / 2 : 0
    color: Commons.Color.foreground
    opacity: 0.12
  }

  Rectangle {
    visible: line.fraction > 0
    width: line.width * Math.min(1, line.fraction)
    height: line.height
    radius: Style.cornerRadius > 0 ? height / 2 : 0
    color: Commons.Color.accent
    Behavior on width {
      NumberAnimation { duration: 200 }
    }
  }

  Rectangle {
    id: piece
    visible: line.fraction < 0
    width: line.width / 4
    height: line.height
    radius: Style.cornerRadius > 0 ? height / 2 : 0
    color: Commons.Color.accent
    opacity: 0.7

    SequentialAnimation on x {
      running: piece.visible && line.visible && line.width > 0
      loops: Animation.Infinite
      NumberAnimation { from: 0; to: line.width - piece.width; duration: 900; easing.type: Easing.InOutQuad }
      NumberAnimation { from: line.width - piece.width; to: 0; duration: 900; easing.type: Easing.InOutQuad }
    }
  }
}
