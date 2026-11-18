// platform: wayland
// stub: bin/nova-capture-region capture-region
// warns: $HYPRLAND_INSTANCE_SIGNATURE is unset. Cannot connect to hyprland.
// warns: The active compositor does not support hyprland_global_shortcuts_v1.
// warns: GlobalShortcut will not work.
// warns: Failed to find render device
// warns: Render format initialization failed
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/capture"

// The screen picker (plugins/capture/Capture.qml) as its callers have it: a
// pick asked for and answered on the caller's FIFO, by a click on a window,
// a region drawn, the keys, or a pick given up; the still kept until it is
// thawed, and a request while it is held kept until then; a request that
// replaces another, which is told it was given up; a caller that thaws
// while picking, which gives it up; and PRINT's own pick, done before its
// command asks, or while it asks, handed to it, by its token, and to no
// other. The pointer and the keys are its functions, called as its mouse
// area and its window call them.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function same(got, want, what) {
    const ok = JSON.stringify(got) === JSON.stringify(want)
    check(ok, what + (ok ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  // Waits for <done> to hold, then calls <then>; fails <what> after 5 s.
  function when(done, then, what) {
    waiter.done = done
    waiter.then = then
    waiter.what = what
    waiter.left = 100
    waiter.start()
  }

  Timer {
    id: waiter
    property var done: null
    property var then: null
    property string what: ""
    property int left: 0
    interval: 50
    repeat: true
    onTriggered: {
      if (done()) {
        stop()
        then()
      } else if (--left <= 0) {
        stop()
        test.check(false, what)
        test.finish()
      }
    }
  }

  Capture { id: capture }

  // A caller: a FIFO, and the line read from it, in <name>.out once read
  // (written whole, so that it is there only once it is all there).
  property var outs: ({})
  function caller(name, then) {
    const fifo = test.home + "/" + name
    const proc = readerComponent.createObject(test, {
      command: ["sh", "-c", "mkfifo \"$1\" && head -n 1 \"$1\" >\"$1.part\" && mv \"$1.part\" \"$1.out\"", "sh", fifo] })
    proc.running = true
    outs[fifo] = outComponent.createObject(test, { path: fifo + ".out" })
    when(() => made.exists(fifo), () => then(fifo), "the FIFO " + name + " is made")
  }
  Component {
    id: readerComponent
    Process {}
  }
  Component {
    id: outComponent
    FileView {
      printErrors: false
      blockLoading: true
    }
  }
  property var made: QtObject {
    function exists(path) {
      probe.path = path
      probe.reload()
      return probe.loaded
    }
  }
  FileView {
    id: probe
    printErrors: false
    blockLoading: true
  }
  function answered(fifo) {
    const out = outs[fifo]
    out.reload()
    return out.loaded ? out.text() : null
  }

  function key(code, modifiers) {
    const event = { key: code, modifiers: modifiers || 0, accepted: false }
    capture.key(event)
    return event.accepted
  }

  function begin() {
    same(capture.opened, false, "nothing on screen before it is asked")
    caller("a", fifo => {
      capture.request("smart", fifo)
      same([capture.phase, capture.mode], ["picking", "smart"], "asked: the screen frozen, picking")
      when(() => capture.layKnown, () => clickWindow(fifo), "what is offered is read")
    })
  }

  function clickWindow(fifo) {
    capture.hover(150, 150)
    same(capture.highlight, { x: 100, y: 100, w: 400, h: 300 }, "the window under the pointer is highlighted")
    capture.hover(900, 600)
    same(capture.highlight, { x: 0, y: 0, w: 1280, h: 720 }, "beside every window, the screen")
    capture.pressed(150, 150)
    capture.released(152, 151)
    same([capture.phase, capture.bare], ["holding", true], "a click takes the window, and the still is bared")
    when(() => answered(fifo) !== null, () => {
      same(answered(fifo), "100,100 400x300\n", "the window is the answer")
      check(capture.waiting(fifo), "the still held for the caller")
      capture.thaw(test.home + "/other")
      same(capture.phase, "holding", "another's thaw leaves it")
      capture.thaw(fifo)
      same([capture.opened, capture.waiting(fifo)], [false, false], "thawed: gone")
      draw()
    }, "the click is answered")
  }

  function draw() {
    caller("b", fifo => {
      capture.request("region", fifo)
      when(() => capture.layKnown, () => {
        capture.hover(150, 150)
        same(capture.highlight, null, "region: nothing highlighted under the pointer")
        capture.pressed(10, 10)
        capture.released(12, 13)
        same(capture.phase, "picking", "region: a click draws nothing")
        capture.pressed(200.4, 120.6)
        capture.moved(10, 10)
        same(capture.selection, { x: 10, y: 10, w: 190, h: 111 }, "the region drawn so far")
        capture.released(10, 10)
        when(() => answered(fifo) !== null, () => {
          same(answered(fifo), "10,10 190x111\n", "the region drawn is the answer")
          capture.thaw(fifo)
          keys()
        }, "the region is answered")
      }, "what is offered is read")
    })
  }

  function keys() {
    caller("c", fifo => {
      capture.request("smart", fifo)
      when(() => capture.layKnown, () => {
        capture.hover(900, 600)
        check(key(Qt.Key_Tab), "TAB is taken")
        same(capture.highlight, { x: 100, y: 100, w: 400, h: 300 }, "TAB: the first window in reading order")
        key(Qt.Key_Tab)
        same(capture.highlight, { x: 600, y: 100, w: 200, h: 200 }, "TAB again: the next")
        key(Qt.Key_Tab, Qt.ControlModifier)
        same(capture.highlight, { x: 100, y: 100, w: 400, h: 300 }, "CTRL + TAB: back")
        key(Qt.Key_Right)
        same(capture.highlight, { x: 600, y: 100, w: 200, h: 200 }, "RIGHT: the window that way")
        key(Qt.Key_Return, Qt.ControlModifier)
        when(() => answered(fifo) !== null, () => {
          same(answered(fifo), "0,0 1280x720\n", "CTRL + RETURN: the screen in focus")
          capture.thaw(fifo)
          givenUp()
        }, "CTRL + RETURN is answered")
      }, "what is offered is read")
    })
  }

  function givenUp() {
    caller("d", first => caller("e", second => {
      capture.request("smart", first)
      capture.request("windows", second)
      same([capture.phase, capture.mode], ["picking", "windows"], "asked again while picking: the same still, the new mode")
      when(() => answered(first) !== null, () => {
        same(answered(first), "\n", "the request replaced is told it was given up")
        check(key(Qt.Key_Escape), "ESCAPE is taken")
        when(() => answered(second) !== null, () => {
          same([answered(second), capture.opened], ["\n", false], "ESCAPE gives the pick up, and the still goes")
          printFirst()
        }, "the pick given up is answered")
      }, "the first request is answered")
    }))
  }

  // PRINT: the screen frozen before its command asks, with its token.
  function printKey(token) {
    capture.printToken = token
    capture.freeze("smart")
  }

  function printFirst() {
    printKey("print-1")
    when(() => capture.layKnown, () => {
      capture.pressed(150, 150)
      capture.released(150, 150)
      when(() => capture.settled, () => {
        same(capture.settledWith, "100,100 400x300", "picked before it was asked: kept")
        caller("f", fifo => caller("other", other => {
          capture.request("smart", other, "-")
          same([capture.phase, capture.answer], ["holding", ""], "another request while PRINT's still is held: it waits")
          capture.request("smart", fifo, "print-1")
          when(() => answered(fifo) !== null, () => {
            same(answered(fifo), "100,100 400x300\n", "PRINT's pick handed to its command when it asks")
            same(capture.phase, "holding", "the still held for it")
            capture.thaw(fifo)
            same([capture.phase, capture.answer === other], ["picking", true], "let go, the request that waited is picked")
            capture.thaw(other)
            same([capture.opened, answered(other)], [false, null], "a caller that thaws while picking gives it up")
            printGivenUp()
          }, "the kept pick is answered")
        }))
      }, "the pick is kept")
    }, "what is offered is read")
  }

  function printGivenUp() {
    printKey("print-2")
    capture.cancel()
    caller("g", late => {
      capture.request("smart", late, "print-2")
      same(capture.opened, false, "given up before its command asked: not frozen again for it")
      when(() => answered(late) !== null, () => {
        same(answered(late), "\n", "and the command is told so")
        printGivenUpThenAnother()
      }, "the command is told")
    })
  }

  function printGivenUpThenAnother() {
    printKey("print-4")
    capture.cancel()
    caller("stranger", stranger => caller("g2", late => {
      capture.request("smart", stranger, "-")
      same([capture.phase, capture.answer === stranger], ["picking", true], "a request without PRINT's token is not given its pick: it picks")
      capture.request("smart", late, "print-4")
      same([capture.phase, capture.answer === stranger], ["picking", true], "its command asking after: the other's pick left alone")
      when(() => answered(late) !== null, () => {
        same([answered(late), answered(stranger)], ["\n", null], "and the command told it was given up, and no other")
        capture.cancel()
        printWhileAsking()
      }, "the command is told")
    }))
  }

  function printWhileAsking() {
    printKey("print-3")
    when(() => capture.layKnown, () => {
      caller("h", fifo => {
        capture.pressed(600, 600)
        capture.released(700, 650)
        same([capture.phase, capture.settled], ["holding", false], "a region drawn: on its way")
        capture.request("smart", fifo, "print-3")
        when(() => answered(fifo) !== null, () => {
          same(answered(fifo), "600,600 100x50\n", "PRINT's command asking as it is on its way is given it")
          capture.thaw(fifo)
          same(capture.opened, false, "thawed")
          finish()
        }, "the region on its way is answered")
      })
    }, "what is offered is read")
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(begin)
}
