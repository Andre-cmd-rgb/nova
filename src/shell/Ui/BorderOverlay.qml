import QtQuick
import QtQuick.Shapes
import qs.Commons
import "../Commons/BorderGeometry.js" as Geometry

// The border BorderSurface cannot draw with its Rectangle: a gradient, or
// sides of different widths. It lies over its parent and fills one ring, the
// outline with its corners rounded by <radius> less the same outline moved
// in by each side's width, with the spec's gradient or its one colour. It
// draws nothing else and takes no input.
Item {
  id: overlay

  property var borderSpec: Border.none()
  property real radius: 0

  readonly property bool hasBorder: Geometry.maxWidth(_sides) > 0

  readonly property var _sides: borderSpec && borderSpec.widths ? borderSpec.widths : Geometry.parseWidthSpec(0, 0)
  // The colours the ring runs through: a gradient's own, or the one colour
  // at both ends; and the angle it runs at.
  readonly property var _ramp: {
    var gradient = borderSpec && borderSpec.gradient
    if (gradient && gradient.enabled) return gradient.colors
    var only = Border.color(borderSpec)
    return [only, only]
  }
  readonly property real _angle: borderSpec && borderSpec.gradient ? borderSpec.gradient.angle || 0 : 0
  readonly property var _axis: Geometry.gradientEndpoints(width, height, _angle)

  // A gradient carries ten stops; one past the ramp's last colour repeats it.
  component RampStop: GradientStop {
    required property int step
    position: Geometry.stopPosition(overlay._ramp, step)
    color: Geometry.stopColor(overlay._ramp, step)
  }

  anchors.fill: parent
  visible: hasBorder && width > 0 && height > 0
  z: 100000

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      fillRule: ShapePath.WindingFill
      strokeWidth: 0
      fillGradient: LinearGradient {
        x1: overlay._axis.x1
        y1: overlay._axis.y1
        x2: overlay._axis.x2
        y2: overlay._axis.y2

        RampStop { step: 0 }
        RampStop { step: 1 }
        RampStop { step: 2 }
        RampStop { step: 3 }
        RampStop { step: 4 }
        RampStop { step: 5 }
        RampStop { step: 6 }
        RampStop { step: 7 }
        RampStop { step: 8 }
        RampStop { step: 9 }
      }

      PathSvg {
        path: Geometry.ringPath(overlay.width, overlay.height, overlay.radius, overlay._sides)
      }
    }
  }
}
