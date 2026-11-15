import Quickshell
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "BarModel.js" as BarModel

// One screen's bar: its window along the edge, the shade under a see-through
// one, the tooltip that pops out of it, and two overlays over the whole
// screen, drawn while something is dragged on it: the picture of a widget
// and the place it would land, and the edge the bar would go to.
Scope {
  id: screenBar

  required property var modelData
  required property Item bar

  readonly property var screen: modelData

  // A layer window along the bar's edge, as deep as <depth>, drawn over
  // whatever the screen shows there.
  component EdgeWindow: PanelWindow {
    readonly property string edge: screenBar.bar.position
    property int depth: screenBar.bar.thickness

    screen: screenBar.screen
    surfaceFormat.opaque: false
    implicitWidth: screenBar.bar.vertical ? depth : 0
    implicitHeight: screenBar.bar.vertical ? 0 : depth
    anchors.top: edge !== "bottom"
    anchors.bottom: edge !== "top"
    anchors.left: edge !== "right"
    anchors.right: edge !== "left"
  }

  EdgeWindow {
    id: strip

    // A tucked bar is moved past its edge rather than unmapped (Bar.qml).
    readonly property int offset: screenBar.bar.tucked ? -depth : 0

    visible: !remap.remapping
    color: screenBar.bar.transparent ? "transparent" : screenBar.bar.background
    exclusionMode: screenBar.bar.tucked ? ExclusionMode.Ignore : ExclusionMode.Auto
    WlrLayershell.namespace: "nova-bar"
    WlrLayershell.layer: WlrLayer.Top
    margins.top: edge === "top" ? offset : 0
    margins.bottom: edge === "bottom" ? offset : 0
    margins.left: edge === "left" ? offset : 0
    margins.right: edge === "right" ? offset : 0

    Remap {
      id: remap
      window: strip
    }

    // The sections, made anew when the bar turns on its side. The pointer
    // is watched here rather than on them: an ancestor of a widget stays
    // hovered while the pointer is on the widget, a sibling would not.
    Item {
      anchors.fill: parent

      // The bar counts the pointer on each screen's strip once, on and off:
      // a strip unmapped while it is on it (a move between screens) gets
      // no leave, and its count stayed, holding the centre's peek for good.
      HoverHandler {
        id: hover

        property bool counted: false

        function count(on) {
          if (on === counted) return
          counted = on
          screenBar.bar.pointerOnBar(on)
        }

        onHoveredChanged: count(hovered && strip.visible)
        // A screen unplugged takes its bar with it, with no leave.
        Component.onDestruction: count(false)
      }

      Connections {
        target: strip
        function onVisibleChanged() { hover.count(hover.hovered && strip.visible) }
      }

      Repeater {
        model: [screenBar.bar.vertical]

        Sections {
          required property bool modelData

          bar: screenBar.bar
          standing: modelData
        }
      }
    }

    // The tooltip, for a widget on this screen's bar: 6 px off it, on its
    // side away from the edge, slid along to stay on the screen.
    PopupWindow {
      id: bubbleWindow

      readonly property Tip tip: screenBar.bar.tip
      readonly property Item widget: screenBar.bar.inWindow(tip.target, strip) ? tip.target : null

      visible: tip.shown && widget !== null && tip.text !== ""
      color: "transparent"
      implicitWidth: Math.ceil(bubble.implicitWidth)
      implicitHeight: Math.ceil(bubble.implicitHeight)

      anchor {
        id: bubbleAnchor

        window: strip
        adjustment: PopupAdjustment.Slide
        edges: Edges.Top | Edges.Left
        gravity: Edges.Bottom | Edges.Right
        rect.width: 1
        rect.height: 1

        onAnchoring: {
          const widget = bubbleWindow.widget
          if (!widget) return
          const corner = BarModel.tipCorner(strip.edge, widget.width, widget.height, bubbleWindow.implicitWidth, bubbleWindow.implicitHeight, 6)
          const at = strip.contentItem.mapFromItem(widget, corner.x, corner.y)
          bubbleAnchor.rect.x = Math.round(at.x)
          bubbleAnchor.rect.y = Math.round(at.y)
        }
      }

      BorderSurface {
        id: bubble

        readonly property QtObject ink: Commons.Color.tooltip

        implicitWidth: words.implicitWidth + 20
        implicitHeight: words.implicitHeight + 14
        color: ink.background
        frame: Border.surfaceSpec("tooltip", "border", ink.border, 1)
        radius: Style.cornerRadius

        Text {
          id: words

          anchors.centerIn: parent
          text: bubbleWindow.tip.text
          textFormat: Text.PlainText
          color: bubble.ink.text
          font.family: screenBar.bar.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }
      }
    }
  }

  // The shade behind a see-through bar's text, where the background there
  // needs one (SeeThrough): strongest at the screen's edge and gone twice
  // the bar's depth in. It is a window of its own, under the windows and
  // over the background, as the bar's is only as deep as the bar: drawn
  // there it would end in a line. So the bar has no surface and no edge, and
  // its text still reads on a pale sky.
  EdgeWindow {
    id: shade

    // The gradient runs from the screen's edge inwards.
    readonly property bool fromFarSide: edge === "bottom" || edge === "right"
    readonly property color colour: screenBar.bar.shadeColour
    readonly property real strength: screenBar.bar.shadeStrength

    // The shade's colour at <share> of its strength.
    function at(share) {
      return Qt.rgba(colour.r, colour.g, colour.b, strength * share)
    }

    depth: screenBar.bar.thickness * 2
    visible: strength > 0 && !screenBar.bar.tucked && !remap.remapping
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "nova-bar-shade"
    WlrLayershell.layer: WlrLayer.Bottom
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region {}

    // Three stops: it falls away faster past the bar than under it, where
    // the text is (the engine's AT_THE_TEXT is its strength there).
    Rectangle {
      anchors.fill: parent
      gradient: Gradient {
        orientation: screenBar.bar.vertical ? Gradient.Horizontal : Gradient.Vertical
        GradientStop { position: shade.fromFarSide ? 1 : 0; color: shade.at(1) }
        GradientStop { position: 0.5; color: shade.at(0.55) }
        GradientStop { position: shade.fromFarSide ? 0 : 1; color: shade.at(0) }
      }
    }
  }

  // A window over the whole screen, drawn over everything, that takes no
  // input: the pointer stays with what is being dragged.
  component Overlay: PanelWindow {
    screen: screenBar.screen
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    anchors.top: true
    anchors.bottom: true
    anchors.left: true
    anchors.right: true
    mask: Region {}
  }

  // A widget being dragged: its picture under the pointer, framed, and a
  // line where it would land.
  Overlay {
    id: dragLayer

    readonly property WidgetDrag drag: screenBar.bar.widgetDrag
    readonly property bool here: !!drag.slot && BarModel.sameScreen(drag.screen, screenBar.screen)
    readonly property Item widget: drag.slot ? drag.slot.widget : null
    readonly property int pad: Style.space(1)

    visible: here && widget !== null
    WlrLayershell.namespace: "nova-bar-widget-drag"

    Item {
      visible: dragLayer.visible
      x: Math.round(dragLayer.drag.pointer.x - dragLayer.drag.grip.x - dragLayer.pad)
      y: Math.round(dragLayer.drag.pointer.y - dragLayer.drag.grip.y - dragLayer.pad)
      width: (dragLayer.widget ? Math.max(1, Math.ceil(dragLayer.widget.width)) : 1) + dragLayer.pad * 2
      height: (dragLayer.widget ? Math.max(1, Math.ceil(dragLayer.widget.height)) : 1) + dragLayer.pad * 2

      BarFrame {
        bar: screenBar.bar
        rounded: true
        anchors.fill: parent
        opacity: screenBar.bar.transparent ? 0.45 : 0.94
      }

      // The picture, a little faded, inside the frame.
      Image {
        anchors.fill: parent
        anchors.margins: dragLayer.pad
        source: dragLayer.drag.picture
        smooth: true
        opacity: 0.84
      }
    }

    Rectangle {
      readonly property var line: dragLayer.drag.line

      visible: dragLayer.here && line !== null
      x: line ? Math.round(line.x) : 0
      y: line ? Math.round(line.y) : 0
      width: line ? line.width : 0
      height: line ? line.height : 0
      color: Commons.Color.accent
      radius: dragLayer.drag.lineWidth / 2
    }
  }

  // The bar being dragged: a slab on the edge it would go to. One slab for
  // each edge, faded in and out, as one slab moved from edge to edge is
  // drawn halfway there and flickers.
  Overlay {
    id: edgeLayer

    readonly property BarDrag drag: screenBar.bar.barDrag

    visible: drag.active && BarModel.sameScreen(drag.screen, screenBar.screen)
    WlrLayershell.namespace: "nova-bar-edge-drag"

    Repeater {
      model: BarModel.EDGES

      BarFrame {
        required property string modelData
        readonly property bool side: BarModel.onSide(modelData)
        readonly property int depth: side ? Style.bar.sizeVertical : Style.bar.sizeHorizontal
        readonly property bool target: edgeLayer.drag.edge === modelData

        bar: screenBar.bar
        x: modelData === "right" ? parent.width - depth : 0
        y: modelData === "bottom" ? parent.height - depth : 0
        width: side ? depth : parent.width
        height: side ? parent.height : depth
        opacity: !target ? 0 : screenBar.bar.transparent ? 0.45 : 0.7
        visible: opacity > 0

        Behavior on opacity {
          NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
        }
      }
    }
  }
}
