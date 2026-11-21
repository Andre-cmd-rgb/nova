import Quickshell
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "BarModel.js" as BarModel

// One screen's bar: its window along the top of the screen, the shade under
// a see-through one, the tooltip that pops out of it, and an overlay over the
// whole screen, drawn while a widget is dragged on it: the picture of the
// widget and the place it would land.
Scope {
  id: screenBar

  required property var modelData
  required property Item bar

  readonly property var screen: modelData

  // A layer window along the top of the screen, as deep as <depth>, drawn
  // over whatever the screen shows there.
  component TopWindow: PanelWindow {
    property int depth: screenBar.bar.thickness

    screen: screenBar.screen
    surfaceFormat.opaque: false
    implicitHeight: depth
    anchors.top: true
    anchors.left: true
    anchors.right: true
  }

  TopWindow {
    id: strip

    // A tucked bar is moved past the top rather than unmapped (Bar.qml).
    readonly property int offset: screenBar.bar.tucked ? -depth : 0

    // Not before the boot's lock is up (Commons/BootLock.qml).
    visible: !BootLock.pending && !remap.remapping
    color: screenBar.bar.transparent ? "transparent" : screenBar.bar.background
    exclusionMode: screenBar.bar.tucked ? ExclusionMode.Ignore : ExclusionMode.Auto
    WlrLayershell.namespace: "nova-bar"
    WlrLayershell.layer: WlrLayer.Top
    margins.top: offset

    Remap {
      id: remap
      window: strip
    }

    // The pointer is watched here rather than on the sections: an ancestor
    // of a widget stays hovered while the pointer is on the widget, a
    // sibling would not.
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

      Sections {
        bar: screenBar.bar
      }
    }

    // The tooltip, for a widget on this screen's bar: 6 px below it, slid
    // along to stay on the screen.
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
          const corner = BarModel.tipCorner(widget.width, widget.height, bubbleWindow.implicitWidth, 6)
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
  // needs one (SeeThrough): strongest at the top of the screen and gone twice
  // the bar's depth in. It is a window of its own, under the windows and
  // over the background, as the bar's is only as deep as the bar: drawn
  // there it would end in a line. So the bar has no surface and no edge, and
  // its text still reads on a pale sky.
  TopWindow {
    id: shade

    readonly property color colour: screenBar.bar.shadeColour
    readonly property real strength: screenBar.bar.shadeStrength

    // The shade's colour at <share> of its strength.
    function at(share) {
      return Qt.rgba(colour.r, colour.g, colour.b, strength * share)
    }

    depth: screenBar.bar.thickness * 2
    visible: strength > 0 && !screenBar.bar.tucked && !BootLock.pending && !remap.remapping
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
        orientation: Gradient.Vertical
        GradientStop { position: 0; color: shade.at(1) }
        GradientStop { position: 0.5; color: shade.at(0.55) }
        GradientStop { position: 1; color: shade.at(0) }
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
}
