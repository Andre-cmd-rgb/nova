import QtQuick
import QtQuick.Shapes
import qs.Commons
import "../Commons/BorderGeometry.js" as Geometry

// A border drawn as a shape over its parent, for what a Rectangle's own
// border cannot do: a gradient, or sides of different widths. The ring is
// one path filled by winding, its corners following <radius>, and is filled
// with the spec's gradient, or its colour from end to end. It draws nothing
// else and takes no input.
Item {
  id: root

  property var borderSpec: Border.none()
  property real radius: 0

  readonly property var _widths: borderSpec && borderSpec.widths ? borderSpec.widths : Geometry.parseWidthSpec(0, 0)
  readonly property bool hasBorder: Geometry.maxWidth(_widths) > 0
  readonly property var _gradient: borderSpec && borderSpec.gradient ? borderSpec.gradient : ({ colors: [], angle: 0, enabled: false })
  readonly property var _colors: _gradient.enabled ? _gradient.colors : [Border.color(borderSpec), Border.color(borderSpec)]
  readonly property var _endpoints: Geometry.gradientEndpoints(width, height, _gradient.angle || 0)
  readonly property string _path: Geometry.ringPath(width, height, radius, _widths)

  // The <index>th of the gradient's colours, at its place along it. A
  // gradient has up to ten; past its last, a stop repeats the last.
  component Stop: GradientStop {
    property int index
    property var colors: []
    position: Geometry.stopPosition(colors, index)
    color: Geometry.stopColor(colors, index)
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
        x1: root._endpoints.x1
        y1: root._endpoints.y1
        x2: root._endpoints.x2
        y2: root._endpoints.y2

        Stop { index: 0; colors: root._colors }
        Stop { index: 1; colors: root._colors }
        Stop { index: 2; colors: root._colors }
        Stop { index: 3; colors: root._colors }
        Stop { index: 4; colors: root._colors }
        Stop { index: 5; colors: root._colors }
        Stop { index: 6; colors: root._colors }
        Stop { index: 7; colors: root._colors }
        Stop { index: 8; colors: root._colors }
        Stop { index: 9; colors: root._colors }
      }

      PathSvg { path: root._path }
    }
  }
}
