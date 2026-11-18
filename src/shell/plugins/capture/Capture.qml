import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import "Pick.js" as Pick

// The picker that screenshots, screen recordings and text from the screen
// share (nova-capture-region), kept loaded so that it is on screen at once:
// a still of every screen the moment it is asked for, the rest dimmed, and on
// it a region drawn, or a window or a screen taken.
//
//   smart     drawn freely, the window or the screen under the pointer
//             highlighted, which a click takes
//   region    drawn freely
//   windows   a click takes the window or the screen under it
//
// RETURN takes what is highlighted (the screen in focus, where nothing is),
// CTRL + RETURN the screen in focus; TAB and CTRL + TAB go round the windows
// in reading order, the arrows to the nearest window that way. ESCAPE or a
// right click gives the pick up, as PRINT does a pick it started.
//
// nova-capture-region asks with `nova-shell nova.capture pick <mode>
// <answer> <token>`, <answer> a FIFO it reads the region from, "X,Y WxH", or
// a blank line for a pick given up. The still stays on screen after, its
// dimming gone, while the caller takes the region from it with grim, until
// it says `thaw <answer>` (or ten seconds have gone); a caller that thaws
// while it is picked gives it up. A request that comes while another's
// still is held waits for it to go. PRINT freezes the screen itself, before
// the screenshot it starts has asked, and gives that command a token
// (NOVA_CAPTURE_PICK): a region picked or a pick given up by then is the
// answer the request with that token is given, and no other.
Item {
  id: capture

  property var shell: null
  property var manifest: null

  // "" while nothing is on screen; "picking"; "holding", the region given
  // and the still kept for the caller.
  property string phase: ""
  readonly property bool opened: phase !== ""
  property string mode: "smart"
  // The request answered: its FIFO; "" while none has come.
  property string answer: ""
  // What PRINT's own pick came to before its command asked: a region, or ""
  // for one given up; and the token its command asks with.
  property bool settled: false
  property string settledWith: ""
  property string printToken: ""
  property int printed: 0
  // A request that came while another's still was held: { mode, path, token }.
  property var queued: null

  property var lay: Pick.layout("")
  property bool layKnown: false
  property var highlight: null
  // Where a drag began, and what it has drawn, across every screen.
  property var drag: null
  property var selection: null
  // The pointer, across every screen; NaN until it is seen.
  property real px: NaN
  property real py: NaN
  // A click made before the layout came, taken once it has.
  property var pendingClick: null
  // The dimming and the frame gone, the still kept: as the region is given.
  property bool bare: false

  readonly property color dim: Qt.rgba(0, 0, 0, 0.35)

  // ---- asked --------------------------------------------------------------

  IpcHandler {
    target: "nova.capture"

    function pick(mode: string, answer: string, token: string): string {
      capture.request(mode, answer, token)
      return "ok"
    }

    function thaw(answer: string): string {
      capture.thaw(answer)
      return "ok"
    }

    function waiting(answer: string): string {
      return capture.waiting(answer) ? "yes" : "no"
    }
  }

  function thaw(path) {
    if (opened && path === answer) end()
  }

  // Whether the request is still being answered: its caller gives up on one
  // the shell has let go, or on a shell that went away.
  function waiting(path) {
    return opened && answer === path
  }

  // PRINT, a key of Hyprland's that the shell takes (data/hypr/keys).
  GlobalShortcut {
    appid: "nova"
    name: "screenshot"
    description: "Screenshot"
    onPressed: capture.shortcut()
  }

  function shortcut() {
    if (phase === "picking") {
      cancel()
      return
    }
    if (phase !== "") return
    settled = false
    settledFor.stop()
    settledWith = ""
    freeze("smart")
    printed += 1
    printToken = "print-" + printed + "-" + Date.now()
    Quickshell.execDetached(["env", "NOVA_CAPTURE_PICK=" + printToken, "nova-capture-screenshot"])
  }

  function request(asked, path, token) {
    var own = !!token && token === printToken
    if (settled && own) {
      settled = false
      settledFor.stop()
      reply(path, settledWith)
      // A region's still is held for it; a pick given up leaves alone
      // another's that has come since.
      if (settledWith !== "" && phase === "holding") {
        answer = path
        holdFor.restart()
      }
      return
    }
    if (phase === "holding") {
      // PRINT's region on its way to the command that has just asked.
      if (answer === "" && own) answer = path
      else queued = { mode: asked, path: path, token: token }
      return
    }
    if (answer !== "" && answer !== path) reply(answer, "")
    if (phase === "") freeze(asked)
    else mode = asked
    answer = path
  }

  function freeze(asked) {
    mode = asked === "region" || asked === "windows" ? asked : "smart"
    answer = ""
    lay = Pick.layout("")
    layKnown = false
    highlight = null
    drag = null
    selection = null
    pendingClick = null
    bare = false
    phase = "picking"
    layoutRead.running = true
  }

  // The region <r> taken: the still bared, then, a few frames later, once the
  // screen shows it so, the region given.
  function take(r) {
    if (phase !== "picking" || !r || r.w <= 0 || r.h <= 0) return
    bare = true
    phase = "holding"
    giving.region = Pick.format(r)
    giving.restart()
  }

  function cancel() {
    if (phase === "") return
    var path = answer
    end()
    if (path !== "") reply(path, "")
    else settle("")
  }

  function end() {
    phase = ""
    answer = ""
    bare = false
    highlight = null
    drag = null
    selection = null
    pendingClick = null
    giving.stop()
    holdFor.stop()
    if (queued) {
      var next = queued
      queued = null
      request(next.mode, next.path, next.token)
    }
  }

  // Every screen, as one region: what a drag past an edge is cut to.
  function desk() {
    var all = null
    for (var i = 0; i < Quickshell.screens.length; i++) {
      var s = Quickshell.screens[i]
      if (!all) {
        all = { x: s.x, y: s.y, right: s.x + s.width, bottom: s.y + s.height }
      } else {
        all.x = Math.min(all.x, s.x)
        all.y = Math.min(all.y, s.y)
        all.right = Math.max(all.right, s.x + s.width)
        all.bottom = Math.max(all.bottom, s.y + s.height)
      }
    }
    return all ? { x: all.x, y: all.y, w: all.right - all.x, h: all.bottom - all.y } : null
  }

  // PRINT's pick, done before its command asked: kept for it a while.
  function settle(text) {
    settled = true
    settledWith = text
    settledFor.restart()
  }

  // Written as the caller reads it; opened for reading too, so that the
  // write never waits on a caller that has gone.
  function reply(path, text) {
    Quickshell.execDetached(["sh", "-c", "[ -p \"$2\" ] && exec 3<>\"$2\" && printf '%s\\n' \"$1\" >&3", "sh", text, path])
  }

  Timer {
    id: giving
    property string region: ""
    interval: 60
    onTriggered: {
      if (capture.answer !== "") capture.reply(capture.answer, region)
      else capture.settle(region)
      holdFor.restart()
    }
  }

  // A caller that never thaws the still does not keep the screen frozen.
  Timer {
    id: holdFor
    interval: 10000
    onTriggered: capture.end()
  }

  Timer {
    id: settledFor
    interval: 5000
    onTriggered: {
      capture.settled = false
      if (capture.phase === "holding" && capture.answer === "") capture.end()
    }
  }

  // The windows and screens on offer: what slurp is offered, from the same
  // place, the moment the screen freezes.
  Process {
    id: layoutRead
    command: ["nova-capture-region", "--layout"]
    stdout: StdioCollector {
      onStreamFinished: capture.laidOut(text)
    }
  }

  function laidOut(text) {
    if (phase !== "picking") return
    lay = Pick.layout(text)
    layKnown = true
    if (pendingClick) {
      var at = pendingClick
      pendingClick = null
      clicked(at.x, at.y)
    } else {
      hover(px, py)
    }
  }

  // ---- the pointer and the keys --------------------------------------------

  function hover(x, y) {
    px = x
    py = y
    if (phase !== "picking" || drag || !layKnown || mode === "region" || !isFinite(x)) return
    highlight = Pick.offered(lay, x, y)
  }

  function pressed(x, y) {
    px = x
    py = y
    drag = { x: x, y: y }
    selection = null
  }

  function moved(x, y) {
    px = x
    py = y
    if (drag && mode !== "windows") selection = Pick.drawn(drag.x, drag.y, x, y)
  }

  function released(x, y) {
    if (!drag) return
    var r = mode === "windows" ? null : Pick.drawn(drag.x, drag.y, x, y)
    var all = desk()
    if (r && all) r = Pick.clip(r, all)
    drag = null
    if (r && !Pick.isClick(r)) {
      take(r)
      return
    }
    selection = null
    // A click draws nothing.
    if (mode !== "region") clicked(x, y)
  }

  function clicked(x, y) {
    if (!layKnown) {
      pendingClick = { x: x, y: y }
      return
    }
    take(Pick.offered(lay, x, y))
  }

  function key(event) {
    if (phase !== "picking") return
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    if (event.key === Qt.Key_Escape) {
      cancel()
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (layKnown) take(ctrl ? lay.focused : highlight || Pick.highlighted(lay, px, py))
    } else {
      var way = { [Qt.Key_Tab]: ctrl ? "prev" : "next", [Qt.Key_Backtab]: "prev", [Qt.Key_Left]: "left",
        [Qt.Key_Right]: "right", [Qt.Key_Up]: "up", [Qt.Key_Down]: "down" }[event.key]
      if (!way) return
      if (layKnown) {
        var current = lay.windows.some(function (w) { return Pick.same(w, highlight) }) ? highlight : null
        // From the pointer; from the middle of the screen in focus where the
        // pointer is not seen yet.
        var f = lay.focused
        var ox = isFinite(px) ? px : f ? f.x + Math.floor(f.w / 2) : 0
        var oy = isFinite(py) ? py : f ? f.y + Math.floor(f.h / 2) : 0
        highlight = Pick.step(lay.windows, current, ox, oy, way) || highlight
        selection = null
      }
    }
    event.accepted = true
  }

  // ---- every screen ----------------------------------------------------------

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: frame

      required property var modelData
      readonly property var area: ({ x: modelData.x, y: modelData.y, w: modelData.width, h: modelData.height })
      readonly property bool focusedScreen: !Hyprland.focusedMonitor || Hyprland.focusedMonitor.name === modelData.name

      screen: modelData
      visible: capture.opened
      color: "transparent"
      anchors {
        top: true
        bottom: true
        left: true
        right: true
      }
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.namespace: "nova-capture"
      WlrLayershell.keyboardFocus: capture.phase === "picking" && focusedScreen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

      Item {
        id: face
        anchors.fill: parent
        focus: true
        Keys.onPressed: function (event) { capture.key(event) }

        // Taken afresh at every freeze, so the still is of this moment. Until
        // it comes, nothing is drawn: the screen as it is shows through, and
        // no dimming is caught in the still.
        Loader {
          id: still
          anchors.fill: parent
          active: capture.opened
          sourceComponent: ScreencopyView {
            captureSource: frame.modelData
            live: false
          }
        }

        readonly property bool shown: !!still.item && still.item.hasContent && !capture.bare
        onShownChanged: if (shown && frame.focusedScreen) forceActiveFocus()

        // What is not dimmed, on this screen: what is drawn, else what is
        // highlighted.
        readonly property var hole: {
          var r = Pick.clip(capture.selection || capture.highlight, frame.area)
          return r ? { x: r.x - frame.area.x, y: r.y - frame.area.y, w: r.w, h: r.h } : null
        }

        Item {
          anchors.fill: parent
          visible: face.shown

          Rectangle {
            width: parent.width
            height: face.hole ? face.hole.y : parent.height
            color: capture.dim
          }
          Rectangle {
            visible: !!face.hole
            y: face.hole ? face.hole.y + face.hole.h : 0
            width: parent.width
            height: parent.height - y
            color: capture.dim
          }
          Rectangle {
            visible: !!face.hole
            y: face.hole ? face.hole.y : 0
            width: face.hole ? face.hole.x : 0
            height: face.hole ? face.hole.h : 0
            color: capture.dim
          }
          Rectangle {
            visible: !!face.hole
            x: face.hole ? face.hole.x + face.hole.w : 0
            y: face.hole ? face.hole.y : 0
            width: parent.width - x
            height: face.hole ? face.hole.h : 0
            color: capture.dim
          }
          Rectangle {
            visible: !!face.hole
            x: face.hole ? face.hole.x : 0
            y: face.hole ? face.hole.y : 0
            width: face.hole ? face.hole.w : 0
            height: face.hole ? face.hole.h : 0
            color: "transparent"
            border.color: Commons.Color.accent
            border.width: 2
          }

          // The size drawn, by its lower right corner, on the screen with the
          // pointer.
          Rectangle {
            id: size
            readonly property real cornerX: capture.px - frame.area.x
            readonly property real cornerY: capture.py - frame.area.y
            visible: !!capture.selection && cornerX >= 0 && cornerX < parent.width && cornerY >= 0 && cornerY < parent.height
            x: Math.max(0, Math.min(parent.width - width, cornerX + 12))
            y: Math.max(0, Math.min(parent.height - height, cornerY + 12))
            width: sizeText.implicitWidth + Style.space(16)
            height: sizeText.implicitHeight + Style.space(8)
            radius: height / 2
            color: Commons.Color.popups.background

            Text {
              id: sizeText
              anchors.centerIn: parent
              text: capture.selection ? capture.selection.w + " × " + capture.selection.h : ""
              textFormat: Text.PlainText
              color: Commons.Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        MouseArea {
          anchors.fill: parent
          enabled: capture.phase === "picking"
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          cursorShape: Qt.CrossCursor
          onContainsMouseChanged: if (containsMouse) capture.hover(frame.area.x + mouseX, frame.area.y + mouseY)
          onPositionChanged: function (mouse) {
            var x = frame.area.x + mouse.x, y = frame.area.y + mouse.y
            if (pressed && (mouse.buttons & Qt.LeftButton)) capture.moved(x, y)
            else capture.hover(x, y)
          }
          onPressed: function (mouse) {
            if (mouse.button === Qt.RightButton) capture.cancel()
            else capture.pressed(frame.area.x + mouse.x, frame.area.y + mouse.y)
          }
          onReleased: function (mouse) {
            if (mouse.button === Qt.LeftButton) capture.released(frame.area.x + mouse.x, frame.area.y + mouse.y)
          }
        }
      }
    }
  }
}
