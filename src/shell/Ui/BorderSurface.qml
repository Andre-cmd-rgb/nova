import QtQuick
import QtQuick.Shapes
import qs.Commons
import "../Commons/Ring.js" as Ring

// A Rectangle with a border from a Border spec ({ color, widths, gradient }).
// One colour at one width all round is the Rectangle's own border, which
// costs nothing. A gradient, or sides of different widths, is a ring filled
// over the Rectangle with a Shape, made only for a spec that needs one and
// drawn under whatever the surface holds. Content goes inside the content
// insets: each side's border and its padding, <horizontalPadding> at the
// sides and <verticalPadding> at the top and bottom, both <padding> unless
// set.
Rectangle {
  id: surface

  property var borderSpec: Border.none()
  property real padding: 0
  property real horizontalPadding: padding
  property real verticalPadding: padding

  readonly property real borderTop: Border.top(borderSpec)
  readonly property real borderRight: Border.right(borderSpec)
  readonly property real borderBottom: Border.bottom(borderSpec)
  readonly property real borderLeft: Border.left(borderSpec)

  readonly property real contentTopInset: borderTop + verticalPadding
  readonly property real contentRightInset: borderRight + horizontalPadding
  readonly property real contentBottomInset: borderBottom + verticalPadding
  readonly property real contentLeftInset: borderLeft + horizontalPadding

  // Who draws the border: "rectangle", "ring", or nobody ("") when it has
  // no width.
  readonly property string _drawnBy: Border.drawnBy(borderSpec)

  border.width: _drawnBy === "rectangle" ? borderTop : 0
  border.color: _drawnBy === "rectangle" ? Border.color(borderSpec) : "transparent"

  // One of the ring's gradient stops: its place and colour from <stops>.
  component RingStop: GradientStop {
    required property var stops
    required property int step
    position: stops[step].position
    color: stops[step].color
  }

  // The ring: the outline round the surface's corners less the same outline
  // moved in by each side's width, filled along the gradient's angle with
  // its colours, or with the one colour at both ends.
  Loader {
    anchors.fill: parent
    active: surface._drawnBy === "ring"
    sourceComponent: Shape {
      id: ring

      readonly property var spec: surface.borderSpec
      readonly property var gradient: spec ? spec.gradient : null
      readonly property var colors: gradient && gradient.enabled ? gradient.colors : [Border.color(spec), Border.color(spec)]
      readonly property var axis: Ring.axis(width, height, gradient ? gradient.angle || 0 : 0)
      // Ten stops; those past the last colour repeat it.
      readonly property var stops: Ring.stops(colors, 10)

      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        fillRule: ShapePath.WindingFill
        strokeWidth: 0
        fillGradient: LinearGradient {
          x1: ring.axis.x1
          y1: ring.axis.y1
          x2: ring.axis.x2
          y2: ring.axis.y2

          RingStop { stops: ring.stops; step: 0 }
          RingStop { stops: ring.stops; step: 1 }
          RingStop { stops: ring.stops; step: 2 }
          RingStop { stops: ring.stops; step: 3 }
          RingStop { stops: ring.stops; step: 4 }
          RingStop { stops: ring.stops; step: 5 }
          RingStop { stops: ring.stops; step: 6 }
          RingStop { stops: ring.stops; step: 7 }
          RingStop { stops: ring.stops; step: 8 }
          RingStop { stops: ring.stops; step: 9 }
        }

        PathSvg {
          path: Ring.path(ring.width, ring.height, surface.radius, ring.spec ? ring.spec.widths : null)
        }
      }
    }
  }
}
