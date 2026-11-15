import QtQuick
import QtQuick.Shapes
import qs.Commons
import "../Commons/Ring.js" as Ring

// A Rectangle framed by a Border spec, <frame>. A frame of one colour and one
// width is the Rectangle's own border; a gradient, or sides of unequal
// widths, needs a Shape, which is made only then and lies under whatever the
// surface holds.
//
// <edge> is the frame's width on each side ({ top, right, bottom, left }),
// and <inset> that plus the padding: <padX> left and right, <padY> above and
// below, both <padding> unless set. Content anchored by <inset> sits clear of
// both.
Rectangle {
  id: surface

  property var frame: Border.none()
  property real padding: 0
  property real padX: padding
  property real padY: padding

  readonly property var edge: frame && frame.widths ? frame.widths : ({ top: 0, right: 0, bottom: 0, left: 0 })
  readonly property var inset: ({
    top: edge.top + padY,
    right: edge.right + padX,
    bottom: edge.bottom + padY,
    left: edge.left + padX
  })

  // One of the ring's ten gradient stops.
  component Stop: GradientStop {
    required property var of
    required property int at
    position: of[at].position
    color: of[at].color
  }

  // "rectangle", "ring", or "" with nothing to draw.
  readonly property string _drawing: Border.drawnBy(frame)

  border.width: _drawing === "rectangle" ? edge.top : 0
  border.color: _drawing === "rectangle" ? Border.color(frame) : "transparent"

  // The ring: the outline of the rounded surface, less the outline moved in
  // by each side's width, filled along the gradient's angle; one colour is a
  // gradient that starts and ends in it.
  Loader {
    anchors.fill: parent
    active: surface._drawing === "ring"
    sourceComponent: Shape {
      id: ring

      readonly property var gradient: surface.frame ? surface.frame.gradient : null
      readonly property var colors: gradient && gradient.enabled ? gradient.colors : [Border.color(surface.frame), Border.color(surface.frame)]
      readonly property var line: Ring.axis(width, height, gradient ? gradient.angle || 0 : 0)
      // A gradient holds a fixed set of stops; ten, the last colour
      // repeated over those it does not fill.
      readonly property var stops: Ring.stops(colors, 10)

      preferredRendererType: Shape.CurveRenderer

      ShapePath {
        strokeWidth: 0
        fillRule: ShapePath.WindingFill
        fillGradient: LinearGradient {
          x1: ring.line.x1
          y1: ring.line.y1
          x2: ring.line.x2
          y2: ring.line.y2

          Stop { of: ring.stops; at: 0 }
          Stop { of: ring.stops; at: 1 }
          Stop { of: ring.stops; at: 2 }
          Stop { of: ring.stops; at: 3 }
          Stop { of: ring.stops; at: 4 }
          Stop { of: ring.stops; at: 5 }
          Stop { of: ring.stops; at: 6 }
          Stop { of: ring.stops; at: 7 }
          Stop { of: ring.stops; at: 8 }
          Stop { of: ring.stops; at: 9 }
        }

        PathSvg {
          path: Ring.path(ring.width, ring.height, surface.radius, surface.frame ? surface.frame.widths : null)
        }
      }
    }
  }
}
