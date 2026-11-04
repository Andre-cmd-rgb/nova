import Quickshell
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "BarModel.js" as BarModel

// One screen's bar: its window along the edge, the tooltip that pops out of
// it, and two overlays over the whole screen, drawn while something is
// dragged on it: the picture of a widget and the place it would land, and
// the edge the bar would go to.
Scope {
  id: screenBar

  required property var modelData
  required property Item bar

  readonly property var screen: modelData

  PanelWindow {
    id: strip

    readonly property string edge: screenBar.bar.position
    // A hidden bar is moved past its edge rather than unmapped (Bar.qml).
    readonly property int tucked: screenBar.bar.barHidden ? -screenBar.bar.barSize : 0

    screen: screenBar.screen
    visible: !remap.remapping
    color: screenBar.bar.transparent ? "transparent" : screenBar.bar.background
    surfaceFormat.opaque: false
    exclusionMode: screenBar.bar.barHidden ? ExclusionMode.Ignore : ExclusionMode.Auto
    implicitWidth: screenBar.bar.vertical ? screenBar.bar.barSize : 0
    implicitHeight: screenBar.bar.vertical ? 0 : screenBar.bar.barSize
    WlrLayershell.namespace: "nova-bar"
    WlrLayershell.layer: WlrLayer.Top

    anchors.top: edge !== "bottom"
    anchors.bottom: edge !== "top"
    anchors.left: edge !== "right"
    anchors.right: edge !== "left"
    margins.top: edge === "top" ? tucked : 0
    margins.bottom: edge === "bottom" ? tucked : 0
    margins.left: edge === "left" ? tucked : 0
    margins.right: edge === "right" ? tucked : 0

    ScreenMoveRemap {
      id: remap
      window: strip
    }

    // The sections, made anew when the bar turns on its side. The pointer
    // is watched here rather than on them: an ancestor of a widget stays
    // hovered while the pointer is on the widget, a sibling would not.
    Item {
      anchors.fill: parent

      HoverHandler {
        onHoveredChanged: screenBar.bar.pointerOnBar(hovered)
        // A screen unplugged takes its bar with it, with no leave.
        Component.onDestruction: if (hovered) screenBar.bar.pointerOnBar(false)
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

    PopupWindow {
      id: bubbleWindow

      readonly property Tip tip: screenBar.bar.tip

      visible: tip.shown && tip.target !== null && tip.text !== "" && screenBar.bar.targetBelongsToWindow(tip.target, strip)
      color: "transparent"
      implicitWidth: Math.ceil(bubble.implicitWidth)
      implicitHeight: Math.ceil(bubble.implicitHeight)

      // 6 px off the widget, on its side away from the edge.
      anchor {
        id: bubbleAnchor

        window: strip
        adjustment: PopupAdjustment.Slide
        edges: Edges.Top | Edges.Left
        gravity: Edges.Bottom | Edges.Right
        rect.width: 1
        rect.height: 1

        onAnchoring: {
          var widget = bubbleWindow.tip.target
          if (!screenBar.bar.targetBelongsToWindow(widget, strip)) return
          var corner = BarModel.tipCorner(strip.edge, widget.width, widget.height, bubbleWindow.implicitWidth, bubbleWindow.implicitHeight, 6)
          var point = strip.contentItem.mapFromItem(widget, corner.x, corner.y)
          bubbleAnchor.rect.x = Math.round(point.x)
          bubbleAnchor.rect.y = Math.round(point.y)
        }
      }

      BorderSurface {
        id: bubble

        implicitWidth: words.implicitWidth + 20
        implicitHeight: words.implicitHeight + 14
        color: Commons.Color.tooltip.background
        borderSpec: Border.surfaceSpec("tooltip", "border", Commons.Color.tooltip.border, 1)
        radius: Style.cornerRadius

        Text {
          id: words

          anchors.centerIn: parent
          text: bubbleWindow.tip.text
          textFormat: Text.PlainText
          color: Commons.Color.tooltip.text
          font.family: screenBar.bar.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }
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
    readonly property Item widget: drag.slot ? drag.slot.activeItem : null
    readonly property int pad: Style.space(1)

    visible: here && widget !== null
    WlrLayershell.namespace: "nova-bar-drag-ghost"

    Item {
      visible: dragLayer.visible
      x: Math.round(dragLayer.drag.pointer.x - dragLayer.drag.grip.x - dragLayer.pad)
      y: Math.round(dragLayer.drag.pointer.y - dragLayer.drag.grip.y - dragLayer.pad)
      width: (dragLayer.widget ? Math.max(1, Math.ceil(dragLayer.widget.width)) : 1) + dragLayer.pad * 2
      height: (dragLayer.widget ? Math.max(1, Math.ceil(dragLayer.widget.height)) : 1) + dragLayer.pad * 2

      BorderSurface {
        anchors.fill: parent
        color: screenBar.bar.transparent ? "transparent" : screenBar.bar.background
        borderSpec: Border.flat(screenBar.bar.barForeground, 1)
        radius: Math.min(Style.cornerRadius, height / 2)
        opacity: screenBar.bar.transparent ? 0.45 : 0.94
      }

      Image {
        anchors.fill: parent
        anchors.margins: dragLayer.pad
        source: dragLayer.drag.picture
        fillMode: Image.Stretch
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
      radius: Math.min(width, height) / 2
    }
  }

  // The bar being dragged: a slab on the edge it would go to. One slab for
  // each edge, faded in and out, as one slab moved from edge to edge is
  // drawn halfway there and flickers.
  Overlay {
    id: edgeLayer

    readonly property BarDrag drag: screenBar.bar.barDrag

    visible: drag.active && BarModel.sameScreen(drag.screen, screenBar.screen)
    WlrLayershell.namespace: "nova-bar-move-ghost"

    Repeater {
      model: BarModel.EDGES

      BorderSurface {
        required property string modelData
        readonly property bool side: modelData === "left" || modelData === "right"
        readonly property int depth: side ? Style.bar.sizeVertical : Style.bar.sizeHorizontal

        x: modelData === "right" ? parent.width - depth : 0
        y: modelData === "bottom" ? parent.height - depth : 0
        width: side ? depth : parent.width
        height: side ? parent.height : depth
        color: screenBar.bar.transparent ? "transparent" : screenBar.bar.background
        borderSpec: Border.flat(screenBar.bar.barForeground, 1)
        visible: opacity > 0
        opacity: edgeLayer.drag.edge === modelData ? (screenBar.bar.transparent ? 0.45 : 0.7) : 0

        Behavior on opacity {
          NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
        }
      }
    }
  }
}
