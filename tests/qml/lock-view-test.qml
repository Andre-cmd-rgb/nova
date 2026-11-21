// platform: wayland
// warns: Cannot set file position
// warns: broken.ppm
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "plugins/lock"

// The lock screen's view, as the lock and the greeter put it up: on a black
// window over the whole screen. What it draws is read back pixel by pixel
// (the view grabbed, saved and sampled), at each step:
//
//   - its picture still loading, and no backdrop there: nothing at all, the
//     window's black. A frame of flat colour, or the card without its
//     picture, flashed between the boot's black and the lock: white, on a
//     light theme. Qt reads images one at a time, on one thread: an image
//     from a FIFO nobody has written yet holds it, and the picture waits
//     behind it for as long as the test likes (the FIFO, written at last,
//     fails to load, as Qt cannot seek in it: the warning it prints);
//   - the picture once it comes: the picture, with the card;
//   - the backdrop nova-theme makes: ready before the first frame, the
//     finished view in it;
//   - a picture that is not there: the theme's colour and the card, at
//     once, and not a word in the log (a home nova-theme has not set up
//     yet: the warnings of the lock's images, the backdrop and the picture
//     not there, failed the whole shell's smoke run);
//   - one there that cannot be read: the same, once it has failed;
//   - one that never comes: nothing for 1.5 s, then the same;
//   - a fade (the boot's lock, the greeter): nothing until the window has
//     shown a frame, black, then the picture coming in.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  readonly property string fifo: home + "/picture.ppm"
  readonly property string halves: home + "/halves.ppm"
  readonly property string backdrop: home + "/backdrop.ppm"
  readonly property string broken: home + "/broken.ppm"

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  // A 64x40 PPM, dark grey (64) on the left half and white on the right,
  // written by sh to <path> (a FIFO blocks until it is read).
  function ppmCommand(path) {
    return ["sh", "-c", "{ printf 'P6\\n64 40\\n255\\n'; i=0; while [ $i -lt 40 ]; do head -c 96 /dev/zero | tr '\\0' '\\100'; head -c 96 /dev/zero | tr '\\0' '\\377'; i=$((i+1)); done; } > \"$1\"", "sh", path]
  }

  // Holds Qt's image thread on the FIFO while its source is set.
  Image {
    id: blocker
    asynchronous: true
    cache: false
    visible: false
  }

  PanelWindow {
    id: screen
    anchors { top: true; bottom: true; left: true; right: true }
    exclusionMode: ExclusionMode.Ignore
    color: "black"
    WlrLayershell.layer: WlrLayer.Overlay

    // Where each step's view goes.
    Item {
      id: stage
      anchors.fill: parent
    }
  }

  // The grab, saved as a PPM and read back: no image is loaded for it, as
  // Qt loads every image on one thread, which the FIFO holds while it waits.
  // A PPM has no alpha: what is not drawn reads as black, as the screen
  // shows it over the black window.
  FileView {
    id: grabbed
    blockLoading: true
    printErrors: false
  }

  property int grabs: 0

  // How the view looks, 32 cells by 20: how many are drawn (not black), the
  // left and right halves' mean brightness, and the spread between the
  // brightest drawn cell and the darkest.
  function measure(path) {
    grabbed.path = ""
    grabbed.path = path
    const bytes = new Uint8Array(grabbed.data())
    // The header: P6, width, height, 255, each after whitespace.
    let at = 0
    const field = () => {
      while (bytes[at] === 10 || bytes[at] === 32) at++
      let word = ""
      while (bytes[at] !== 10 && bytes[at] !== 32) word += String.fromCharCode(bytes[at++])
      return word
    }
    const magic = field(), width = Number(field()), height = Number(field())
    field()
    at++
    const cols = 32, rows = 20
    let drawn = 0, left = 0, right = 0, low = 255, high = 0
    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const x = Math.floor((c + 0.5) * width / cols), y = Math.floor((r + 0.5) * height / rows)
        const i = at + (y * width + x) * 3
        const lum = 0.2126 * bytes[i] + 0.7152 * bytes[i + 1] + 0.0722 * bytes[i + 2]
        if (Math.max(bytes[i], bytes[i + 1], bytes[i + 2]) > 4) {
          drawn++
          low = Math.min(low, lum)
          high = Math.max(high, lum)
        }
        if (c < cols / 2) left += lum
        else right += lum
      }
    }
    const cells = cols * rows
    return { magic: magic, drawn: drawn, cells: cells, left: left / (cells / 2), right: right / (cells / 2), spread: high - low }
  }

  Component {
    id: viewComponent
    LockView { anchors.fill: parent; takesInput: false }
  }

  property var view: null

  function show(props) {
    if (view) view.destroy()
    view = viewComponent.createObject(stage, props)
    return view
  }

  // The view as drawn.
  function grab(then) {
    view.grabToImage(result => {
      const path = home + "/grab-" + (grabs++) + ".ppm"
      if (!result.saveToFile(path)) {
        check(false, "the grab is saved")
        then({ drawn: -1, cells: 0, left: 0, right: 0, spread: 0 })
        return
      }
      then(measure(path))
    })
  }

  Process {
    id: sh
    property var after: null
    function run(command, then) {
      after = then
      exec(command)
    }
    onExited: if (after) { const then = after; after = null; then() }
  }

  // ---------------------------------------------------------------- steps

  property int step: 0
  readonly property var steps: [
    // Files: the FIFO, the picture, and a backdrop of the same halves.
    () => sh.run(["mkfifo", fifo], next),
    () => sh.run(ppmCommand(halves), next),
    () => sh.run(ppmCommand(backdrop), next),
    () => sh.run(["sh", "-c", "printf 'P6\\n64 40\\n255\\nxx' > \"$1\"", "sh", broken], next),

    // A picture still loading, and no backdrop there: nothing drawn.
    () => {
      blocker.source = "file://" + fifo
      show({ backdrop: home + "/no-backdrop.ppm", picture: halves })
      check(!view.revealed, "a picture loading: the view is not shown")
      wait(400)
    },
    () => grab(seen => {
      check(seen.drawn === 0, "a picture loading: nothing drawn, only the window's black (" + seen.drawn + " of " + seen.cells + " cells)")
      next()
    }),
    // The picture comes: then the picture, blurred, with the card.
    () => {
      Quickshell.execDetached(ppmCommand(fifo))
      until(() => view.pictureShown, 5000, "the picture comes once the image thread is let go")
    },
    () => wait(400),
    () => grab(seen => {
      check(seen.drawn === seen.cells, "the picture once it comes: drawn over all of it (" + seen.drawn + " of " + seen.cells + ")")
      check(seen.right - seen.left > 60, "the picture once it comes: its dark half and its light half (" + Math.round(seen.left) + ", " + Math.round(seen.right) + ")")
      next()
    }),

    // The backdrop: ready before any frame, and drawn at once.
    () => {
      show({ backdrop: backdrop, picture: home + "/never.ppm" })
      check(view.backdropShown && view.revealed && view.shown === 1, "the backdrop: ready and shown before the first frame")
      wait(200)
    },
    () => grab(seen => {
      check(seen.drawn === seen.cells && seen.right - seen.left > 60, "the backdrop: the finished view in the first frames (" + seen.drawn + " cells, " + Math.round(seen.left) + ", " + Math.round(seen.right) + ")")
      next()
    }),

    // A picture that is not there, nor a backdrop: the theme's colour and
    // the card, at once; the log says nothing of them (the runner fails on a
    // warning this test does not list).
    () => {
      show({ backdrop: home + "/no-backdrop.ppm", picture: home + "/missing.ppm" })
      check(view.revealed && !view.backdropThere && !view.pictureThere, "a picture that is not there: the view is shown at once")
      wait(400)
    },
    () => grab(seen => {
      check(seen.drawn === seen.cells && Math.abs(seen.right - seen.left) < 4, "a picture that is not there: the theme's colour all over, and the card (" + seen.drawn + " cells, " + Math.round(seen.left) + ", " + Math.round(seen.right) + ")")
      next()
    }),

    // One there that cannot be read: the same, once it has failed.
    () => {
      show({ picture: broken })
      until(() => view.revealed, 3000, "a picture that cannot be read: the view is shown")
    },
    () => wait(400),
    () => grab(seen => {
      check(seen.drawn === seen.cells && Math.abs(seen.right - seen.left) < 4, "a picture that cannot be read: the theme's colour all over, and the card (" + seen.drawn + " cells, " + Math.round(seen.left) + ", " + Math.round(seen.right) + ")")
      next()
    }),

    // One that never comes: nothing for 1.5 s, then the theme's colour.
    () => sh.run(["sh", "-c", "rm -f \"$1\" && mkfifo \"$1\"", "sh", fifo], next),
    () => {
      blocker.source = ""
      blocker.source = "file://" + fifo + "?again"
      show({ picture: halves })
      wait(1000)
    },
    () => grab(seen => {
      check(seen.drawn === 0, "a picture that does not come: still nothing after 1 s")
      wait(1200)
    }),
    () => grab(seen => {
      check(view.revealed && !view.pictureShown && seen.drawn === seen.cells, "a picture that does not come: the theme's colour after 1.5 s (" + seen.drawn + " cells)")
      // The reader still waiting on the FIFO is let go.
      Quickshell.execDetached(ppmCommand(fifo))
      next()
    }),

    // A fade: shown only once the window has drawn a frame.
    () => {
      show({ backdrop: backdrop, fadeIn: true })
      check(view.backdropShown && !view.revealed, "a fade: not shown before the window's first frame")
      until(() => view.revealed, 3000, "a fade: shown after the window's first frame")
    },
    () => {
      check(view.shown < 1, "a fade: the picture comes in, not at once (" + view.shown.toFixed(2) + ")")
      wait(600)
    },
    () => grab(seen => {
      check(seen.drawn === seen.cells && seen.right - seen.left > 60, "a fade: then the finished view (" + seen.drawn + " cells, " + Math.round(seen.left) + ", " + Math.round(seen.right) + ")")
      next()
    }),

    () => {
      console.log("DONE")
      Qt.quit()
    }
  ]

  function next() {
    if (step < steps.length) steps[step++]()
  }

  Timer {
    id: pause
    onTriggered: test.next()
  }

  function wait(ms) {
    pause.interval = ms
    pause.restart()
  }

  // Polls <ok> every 50 ms until it holds or <ms> pass; a check either way.
  Timer {
    id: poll
    interval: 50
    repeat: true
    property var ok: null
    property double deadline: 0
    property string what: ""
    onTriggered: {
      const held = ok()
      if (!held && Date.now() < deadline) return
      stop()
      test.check(held, what)
      test.next()
    }
  }

  function until(ok, ms, what) {
    poll.ok = ok
    poll.what = what
    poll.deadline = Date.now() + ms
    poll.restart()
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(next)
}
