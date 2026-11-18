import Quickshell
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "BarModel.js" as BarModel

// One widget's place on the bar. It loads the widget (one of the plugins',
// a user's command or QML file, or nothing for an id that is none of
// these), hands it the bar, its id and its settings, and marks it while its
// panel is open. It takes the left button over the widget, to tell a drag
// from a click: a drag moves the widget to another place, a click goes on to
// the button under the pointer.
Item {
  id: slot

  required property Item bar
  required property var entry
  required property string section

  readonly property string widgetId: BarModel.entryId(entry)
  readonly property var settings: BarModel.entrySettings(entry)
  readonly property string kind: BarModel.customType(entry)
  readonly property Item widget: holder.item
  readonly property bool lifted: bar.widgetDrag.slot === slot
  // Whether the card or panel open is this widget's.
  readonly property bool shown: !!widget && bar.popup === widget

  // What the slot loads: Nova's widget of that id, read through the bar's
  // `widgets` so that a plugin switched on or off loads here again; a
  // user's command or file; or nothing.
  readonly property Component source: {
    if (kind === "command") return commandWidget
    if (kind === "qml") return userFile
    const made = kind === "" ? bar.widgets[widgetId] : null
    return made ? made.component : nothing
  }

  // A user's QML widget, from its file; made once for the slot, and the
  // slot's, so that the garbage collector leaves it (BarWidgets.make).
  readonly property Component userFile: {
    if (kind !== "qml") return null
    const home = Quickshell.env("HOME")
    const file = BarModel.customSource(entry, home, home + "/.config/nova")
    return file ? Qt.createComponent(Util.fileUrl(file), Component.PreferSynchronous, slot) : null
  }

  // How long the mark of an open panel is along the bar: what the widget
  // asks for with <markLength> (its label in a wider slot), or a little over
  // half the slot.
  readonly property real markLength: {
    const asked = widget ? Number(widget.markLength) : 0
    return asked > 0 ? Math.round(asked) : Math.max(Style.space(10), Math.round(width * 0.55))
  }

  readonly property bool shows: !!widget && widget.visible

  implicitWidth: shows ? widget.implicitWidth : 0
  implicitHeight: shows ? widget.implicitHeight : 0
  width: implicitWidth
  height: implicitHeight
  z: pointer.phase === "moving" ? 100 : 0

  Component.onCompleted: bar.listSlot(slot, true)
  Component.onDestruction: {
    if (lifted) bar.widgetDrag.clear()
    bar.listSlot(slot, false)
  }

  onSettingsChanged: handOver()

  // As the widget loads, and at once: a hand-off left for later could find
  // the slot gone. A widget takes what it declares of the three.
  function handOver() {
    if (!widget) return
    const given = { bar: bar, widgetId: widgetId, settings: settings }
    for (const name in given) {
      if (name in widget) widget[name] = given[name]
    }
  }

  // Whether <button> would take a click now.
  function takesClick(button) {
    return !!button && button.visible !== false && button.opacity !== 0
      && button.pressable !== false && button.veiled !== true && typeof button.click === "function"
  }

  // The bar's button at <x>, <y> in this slot, the last listed first; else
  // the widget, when it takes a click itself; else null.
  function buttonAt(x, y) {
    const under = bar.buttons.filter(button => {
      if (!takesClick(button)) return false
      try {
        const at = slot.mapToItem(button, x, y)
        return at.x >= 0 && at.y >= 0 && at.x <= button.width && at.y <= button.height
      } catch (e) {
        return false
      }
    })
    if (under.length > 0) return under[under.length - 1]
    return takesClick(widget) ? widget : null
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
  BarFrame {
    bar: slot.bar
    rounded: true
    visible: slot.lifted
    anchors.fill: parent
    anchors.margins: Style.space(1)
    opacity: slot.bar.transparent ? 0.22 : 0.32
  }

  Loader {
    id: holder
    anchors.fill: parent
    opacity: slot.lifted ? 0.22 : 1.0
    sourceComponent: slot.source
    onLoaded: slot.handOver()
  }

  // The mark of an open panel: a short line on the widget's lower edge,
  // pointing at the panel under it, rounded down as glyphs are drawn.
  Rectangle {
    readonly property int across: Style.space(2)
    readonly property int fromEdge: Style.space(2)

    visible: opacity > 0
    opacity: slot.shown && !slot.lifted ? 0.9 : 0
    color: Commons.Color.accent
    radius: across / 2
    width: slot.markLength
    height: across
    x: Math.floor((parent.width - width) / 2)
    y: parent.height - height - fromEdge
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

    // "down" from a press, "moving" once it has gone 4 px on a bar that
    // can save, "moved" from the release that drops it to the click that
    // follows, which is not a click; "" otherwise.
    property string phase: ""
    property point downAt

    anchors.fill: parent
    acceptedButtons: Qt.LeftButton
    enabled: BarModel.isDrawn(slot)
    propagateComposedEvents: true
    // Asked only of the slot under the pointer: asking every slot on every
    // screen again at each change of the buttons would be slow.
    cursorShape: hover.hovered && slot.buttonAt(mouseX, mouseY) ? Qt.PointingHandCursor : Qt.ArrowCursor

    onPressed: mouse => {
      phase = "down"
      downAt = Qt.point(mouse.x, mouse.y)
      slot.bar.widgetDrag.clear()
    }

    onPositionChanged: mouse => {
      if (!slot.bar.saves || !(mouse.buttons & Qt.LeftButton)) return
      if (phase === "down" && BarModel.travelled(downAt, mouse) >= Style.space(4)) {
        slot.bar.widgetDrag.begin(slot, downAt.x, downAt.y)
        phase = "moving"
        slot.bar.tip.withdraw(slot.widget)
      }
      if (phase === "moving") slot.bar.widgetDrag.follow(slot, slot.mapToItem(null, mouse.x, mouse.y))
    }

    // Not a drag, the click goes on, to onClicked below or beneath.
    onReleased: mouse => {
      const drag = slot.bar.widgetDrag
      const landing = phase === "moving" ? { target: drag.target, after: drag.after } : null
      phase = landing ? "moved" : ""
      drag.clear()
      if (!landing) mouse.accepted = false
      else if (landing.target) drag.drop(slot, landing.target, landing.after)
    }

    onCanceled: {
      phase = ""
      slot.bar.widgetDrag.clear()
    }

    onClicked: mouse => {
      if (phase === "moved") {
        phase = ""
        return
      }
      const button = slot.buttonAt(mouse.x, mouse.y)
      if (button) button.click(mouse.button)
      else mouse.accepted = false
    }
  }
}
