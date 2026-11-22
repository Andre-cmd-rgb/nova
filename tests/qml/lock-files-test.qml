// warns: spoilt.ppm
// warns: Cannot set file position
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/lock"

// Which of its files the lock screen's view shows, offscreen (what it draws
// is lock-view-test's, under sway): the view as the lock makes it, its
// properties read at each step.
//
//   - the picture is looked for without being read: it is read once, by
//     Qt's image thread (held here on a FIFO nobody writes yet, as Qt reads
//     images one at a time), and not before, as its access time tells;
//   - a backdrop there that cannot be read, beside a good picture: the
//     picture, and nothing ready before it;
//   - a picture whose folder is not there, one not in its folder, and an
//     empty one: none, known well before the 1.5 s wait;
//   - a name with wildcard characters is that name: "w?.ppm" is not "wx.ppm",
//     and "we[i]rd*.ppm" is found;
//   - a link to the picture is the picture, and one to nothing is none;
//   - a picture changed on a view shown: the new one looked for, never the
//     old one's answer.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  readonly property string halves: home + "/halves.ppm"
  readonly property string spoilt: home + "/spoilt.ppm"
  readonly property string held: home + "/held.ppm"

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  // A 64x40 PPM, grey on the left half and white on the right, to <path>.
  function ppm(path) {
    return "{ printf 'P6\\n64 40\\n255\\n'; i=0; while [ $i -lt 40 ]; do head -c 96 /dev/zero | tr '\\0' '\\100'; head -c 96 /dev/zero | tr '\\0' '\\377'; i=$((i+1)); done; } > \"" + path + "\""
  }

  Component {
    id: viewComponent
    LockView { width: 640; height: 400; takesInput: false }
  }

  // Holds Qt's image thread on the FIFO while its source is set.
  Image {
    id: blocker
    asynchronous: true
    cache: false
    visible: false
  }

  Item {
    id: stage
  }

  property var view: null

  function show(props) {
    if (view) view.destroy()
    view = viewComponent.createObject(stage, props)
    return view
  }

  Process {
    id: sh
    stdout: StdioCollector { id: out }
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
    () => sh.run(["sh", "-c", [
      ppm(halves),
      "printf 'P6\\n64 40\\n255\\nxx' > \"$HOME/spoilt.ppm\"",
      ": > \"$HOME/empty.ppm\"",
      "cp \"$HOME/halves.ppm\" \"$HOME/wx.ppm\"",
      "cp \"$HOME/halves.ppm\" \"$HOME/we[i]rd*.ppm\"",
      "ln -s halves.ppm \"$HOME/link\"",
      "ln -s gone.ppm \"$HOME/dangling\"",
      "mkfifo \"$HOME/held.ppm\"",
      "touch -a -d 2000-01-01 \"$HOME/halves.ppm\""
    ].join(" && ")], next),

    // The picture looked for while the image thread is held: not read.
    () => {
      blocker.source = "file://" + held
      show({ picture: halves })
      until(() => view.pictureThere, 1000, "a picture: found")
    },
    () => sh.run(["stat", "-c", "%X", halves], () => {
      const read = Number(out.text.trim())
      check(read > 0 && read < 978307200, "a picture: found without being read (read at " + new Date(read * 1000).toISOString() + ")")
      Quickshell.execDetached(["sh", "-c", ppm(held)])
      until(() => view.pictureShown, 5000, "a picture: shown once the image thread is let go")
    }),

    // A backdrop that cannot be read beside a good picture.
    () => {
      show({ backdrop: spoilt, picture: halves })
      check(!view.backdropShown && !view.ready, "a spoilt backdrop: nothing ready before the picture")
      until(() => view.pictureShown, 3000, "a spoilt backdrop: the picture comes")
    },
    () => {
      check(view.ready && !view.backdropShown && view.pictureThere, "a spoilt backdrop: the picture shown, ready")
      next()
    },

    // None there: known before the 1.5 s wait.
    () => none(home + "/nowhere/picture.ppm", "a picture whose folder is not there"),
    () => none(home + "/missing.ppm", "a picture not in its folder"),
    () => none(home + "/empty.ppm", "an empty picture"),
    () => none(home + "/w?.ppm", "\"w?.ppm\" beside \"wx.ppm\""),
    () => none(home + "/dangling", "a link to nothing"),
    () => found(home + "/we[i]rd*.ppm", "\"we[i]rd*.ppm\""),
    () => found(home + "/link", "a link to the picture"),

    // The picture changed on a view shown, to one not there and back.
    () => {
      view.picture = home + "/missing.ppm"
      check(!view.pictureThere, "a picture changed to one not there: not the old one's answer")
      until(() => !view.pictureLooking, 1000, "a picture changed to one not there: looked for")
    },
    () => {
      check(!view.pictureThere && view.ready, "a picture changed to one not there: none")
      view.picture = halves
      check(!view.pictureThere, "a picture changed back: looked for again")
      until(() => view.pictureShown, 3000, "a picture changed back: shown")
    },

    () => {
      console.log("DONE")
      Qt.quit()
    }
  ]

  function none(path, what) {
    show({ picture: path })
    until(() => view.ready, 1000, what + ": ready")
    after = () => {
      check(!view.pictureThere && !view.waited, what + ": none, before the wait")
      next()
    }
  }

  function found(path, what) {
    show({ picture: path })
    until(() => view.pictureShown, 3000, what + ": shown")
  }

  property var after: null

  function next() {
    if (after) { const then = after; after = null; then(); return }
    if (step < steps.length) steps[step++]()
  }

  Timer {
    id: poll
    property var condition: null
    property string what: ""
    property double deadline: 0
    interval: 20
    repeat: true
    onTriggered: {
      if (condition()) {
        stop()
        next()
      } else if (Date.now() > deadline) {
        stop()
        check(false, what + " (timed out)")
        next()
      }
    }
  }

  function until(condition, ms, what) {
    poll.condition = condition
    poll.what = what
    poll.deadline = Date.now() + ms
    poll.start()
  }

  Component.onCompleted: next()
}
