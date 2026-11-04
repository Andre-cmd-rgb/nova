import Quickshell
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "BarModel.js" as BarModel

// One widget's place on the bar. It loads the widget (one of the
// registry's, a user's command or QML file, or nothing for an id that is
// none of these), hands it the bar, its id and its settings, and marks it
// while its panel is open. It takes the left button over the widget, to
// tell a drag from a click: a drag moves the widget to another place, a
// click goes on to the button under the pointer.
Item {
  id: slot

  required property Item bar
  required property var entry
  required property string section

  readonly property string moduleName: BarModel.entryId(entry)
  readonly property var widgetSettings: BarModel.entrySettings(entry)
  readonly property string kind: BarModel.customType(entry)
  readonly property Item activeItem: holder.item
  readonly property bool lifted: bar.widgetDrag.slot === slot

  // A user's QML widget, from its file; made once for the slot.
  readonly property var fileComponent: {
    if (kind !== "qml") return null
    var home = Quickshell.env("HOME")
    var path = BarModel.customSource(entry, home, home + "/.config/nova")
    return path ? Qt.createComponent(Util.fileUrl(path)) : null
  }

  // Read through the registry's `widgets`, so that a widget added to it or
  // taken from it loads again here.
  readonly property var widgetComponent: {
    var registered = bar.barWidgetRegistry.widgets[moduleName]
    if (kind === "command") return commandWidget
    if (kind === "qml") return fileComponent
    if (kind === "" && registered) return registered.component
    return nothing
  }

  // How long the mark of an open panel is along the bar: what the widget
  // asks for (a label in a wider slot, a stack on a side bar), or a little
  // over half the slot.
  readonly property real markLength: {
    var asked = activeItem ? activeItem[bar.vertical ? "openPanelIndicatorHeight" : "openPanelIndicatorWidth"] : undefined
    if (asked > 0) return Math.round(asked)
    return Math.max(Style.space(10), Math.round((bar.vertical ? height : width) * 0.55))
  }

  implicitWidth: activeItem && activeItem.visible ? (bar.vertical ? bar.barSize : activeItem.implicitWidth) : 0
  implicitHeight: activeItem && activeItem.visible ? activeItem.implicitHeight : 0
  width: implicitWidth
  height: implicitHeight
  z: pointer.dragging ? 100 : 0

  Component.onCompleted: bar.enlist(slot)
  Component.onDestruction: {
    if (lifted) bar.widgetDrag.clear()
    bar.delist(slot)
  }

  onWidgetSettingsChanged: handOver()

  // As the widget loads, and at once: a hand-off left for later could find
  // the slot gone.
  function handOver() {
    var widget = holder.item
    if (!widget) return
    if ("bar" in widget) widget.bar = bar
    if ("moduleName" in widget) widget.moduleName = moduleName
    if ("settings" in widget) widget.settings = widgetSettings
  }

  // Whether <button> would take a click now.
  function takesClick(button) {
    return !!button && button.visible !== false && button.opacity !== 0 && button.interactive !== false
      && button.pressable !== false && button.concealed !== true && typeof button.triggerPress === "function"
  }

  // The bar's button at <x>, <y> in this slot, the last listed first; else
  // the widget, when it takes a click itself; else null.
  function buttonAt(x, y) {
    for (var i = bar.clickTargets.length - 1; i >= 0; i--) {
      var button = bar.clickTargets[i]
      if (!takesClick(button)) continue
      var point
      try {
        point = slot.mapToItem(button, x, y)
      } catch (e) {
        continue
      }
      if (point.x >= 0 && point.y >= 0 && point.x <= button.width && point.y <= button.height) return button
    }
    return takesClick(activeItem) ? activeItem : null
  }

  Component {
    id: commandWidget
    CommandWidget {
      bar: slot.bar
      entry: slot.entry
    }
  }

  Component {
    id: nothing
    Item { visible: false }
  }

  HoverHandler {
    id: hover
  }

  // Where the dragged widget was.
  BorderSurface {
    visible: slot.lifted
    anchors.fill: parent
    anchors.margins: Style.space(1)
    color: slot.bar.transparent ? "transparent" : slot.bar.background
    borderSpec: Border.flat(slot.bar.barForeground, 1)
    radius: Math.min(Style.cornerRadius, height / 2)
    opacity: slot.bar.transparent ? 0.22 : 0.32
  }

  Loader {
    id: holder
    anchors.fill: parent
    opacity: slot.lifted ? 0.22 : 1.0
    sourceComponent: slot.widgetComponent
    onLoaded: slot.handOver()
  }

  // The mark of an open panel: a short line on the widget's inner edge,
  // pointing at the panel (under it on a top bar, over it on a bottom one,
  // beside it on a side), rounded down as glyphs are drawn.
  Rectangle {
    readonly property int thickness: Style.space(2)
    readonly property int inset: Style.space(2)
    readonly property string edge: slot.bar.position

    visible: opacity > 0
    opacity: !!slot.activeItem && slot.bar.activePopout === slot.activeItem && !slot.lifted ? 0.9 : 0
    color: Commons.Color.accent
    radius: Math.min(width, height) / 2
    width: slot.bar.vertical ? thickness : slot.markLength
    height: slot.bar.vertical ? slot.markLength : thickness
    x: edge === "left" ? parent.width - width - inset : edge === "right" ? inset : Math.floor((parent.width - width) / 2)
    y: edge === "top" ? parent.height - height - inset : edge === "bottom" ? inset : Math.floor((parent.height - height) / 2)
    z: 50

    Behavior on opacity {
      NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
    }
  }

  // The slot stays where its run put it while it is dragged: moved, it
  // would leave the run with a stale offset after a short drag. The drag is
  // drawn by the overlay of the screen it is on (ScreenBar).
  MouseArea {
    id: pointer

    property bool dragging: false
    property bool afterDrag: false
    property point downAt: Qt.point(0, 0)

    anchors.fill: parent
    acceptedButtons: Qt.LeftButton
    enabled: slot.visible && slot.width > 0 && slot.height > 0
    propagateComposedEvents: true
    // Asked only of the slot under the pointer: asking every slot on every
    // screen again at each change of the buttons would be slow.
    cursorShape: hover.hovered && slot.buttonAt(mouseX, mouseY) ? Qt.PointingHandCursor : Qt.ArrowCursor

    onPressed: function(mouse) {
      dragging = false
      afterDrag = false
      downAt = Qt.point(mouse.x, mouse.y)
      slot.bar.widgetDrag.clear()
    }

    onPositionChanged: function(mouse) {
      if (!slot.bar.canSave() || !(mouse.buttons & Qt.LeftButton)) return
      if (Math.abs(mouse.x - downAt.x) + Math.abs(mouse.y - downAt.y) >= Style.space(4)) {
        if (!dragging) slot.bar.widgetDrag.begin(slot, downAt.x, downAt.y)
        dragging = true
        slot.bar.hideTooltip(slot.activeItem)
      }
      if (dragging) slot.bar.widgetDrag.follow(slot, slot.mapToItem(null, mouse.x, mouse.y))
    }

    onReleased: function(mouse) {
      var dropped = dragging
      var target = slot.bar.widgetDrag.target
      var after = slot.bar.widgetDrag.after
      dragging = false
      slot.bar.widgetDrag.clear()
      // Not a drag: the click goes on, to the slot's onClicked or beneath.
      if (!dropped) {
        mouse.accepted = false
        return
      }
      afterDrag = true
      if (!target) return
      slot.bar.widgetDrag.drop(slot, target, after)
      mouse.accepted = true
    }

    onCanceled: {
      dragging = false
      afterDrag = false
      slot.bar.widgetDrag.clear()
    }

    onClicked: function(mouse) {
      if (afterDrag) {
        afterDrag = false
        mouse.accepted = true
        return
      }
      var button = slot.buttonAt(mouse.x, mouse.y)
      if (button) button.triggerPress(mouse.button)
      else mouse.accepted = false
    }
  }
}
