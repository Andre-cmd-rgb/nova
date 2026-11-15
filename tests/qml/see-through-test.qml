import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/bar" as Bar

// The ink and shade of a see-through bar (SeeThrough), against a stub picker
// that reads the "background" as it starts and answers 0.6 s later. A change
// while it runs makes its answer stale: the bar must ask again, and show the
// ink and shade for the background as it is now.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  property bool ran: false

  Bar.SeeThrough {
    id: seeThrough
    pickCommand: [test.home + "/pick"]
    screenWidth: 1920
    screenHeight: 1200
    thickness: 26
    text: "#ffffff"
    backdrop: "#000000"
  }

  FileView {
    id: wall
    path: test.home + "/wall"
    preload: false
    printErrors: false
  }

  FileView {
    id: asked
    path: test.home + "/asked"
    preload: false
    printErrors: false
    blockLoading: true
  }

  FileView {
    id: pick
    path: test.home + "/pick"
    preload: false
    printErrors: false
    onSaved: executable.running = true
  }

  Process {
    id: executable
    command: ["chmod", "+x", test.home + "/pick"]
    onExited: wall.setText("#111111 #eeeeee 0.10\n")
  }

  Connections {
    target: wall
    function onSaved() { if (!test.ran) test.begin() }
  }

  function check(name, got, want) {
    console.log((got === want ? "ok   " : "FAIL ") + name + (got === want ? "" : ": got " + got + ", want " + want))
  }

  // The stub answers what the "background" holds, and keeps what it was
  // asked with.
  Component.onCompleted: pick.setText('#!/bin/sh\necho "$*" >"$HOME/asked"\nread -r answer <"$HOME/wall"\nsleep 0.6\necho "$answer"\n')

  // Switched on: the picker starts 120 ms on. The wallpaper changes 250 ms
  // later, and the edge with it, while the picker still runs.
  function begin() {
    ran = true
    seeThrough.want(true)
    change.start()
  }

  Timer {
    id: change
    interval: 370
    onTriggered: {
      wall.setText("#222222 #dddddd 0.40\n")
      seeThrough.edge = "bottom"
      settled.start()
    }
  }

  Timer {
    id: settled
    interval: 2500
    onTriggered: {
      check("see-through once the picker answers", seeThrough.shown, true)
      check("  in the ink for the background as it is now", String(seeThrough.colour), "#222222")
      check("  with its shade", String(seeThrough.shade), "#dddddd")
      check("  at its strength", seeThrough.strength, 0.4)
      asked.reload()
      check("  asked with the edge, the bar's depth, the screen and the theme's two colours", asked.text().trim(), "bottom 26 1920x1200 #ffffff #000000")
      seeThrough.answered("not an answer")
      check("an answer that is not one changes nothing", String(seeThrough.colour), "#222222")
      seeThrough.want(false)
      check("solid again: no shade", seeThrough.strength, 0)
      check("  and the theme's text", String(seeThrough.colour), "#ffffff")
      console.log("DONE")
      Qt.quit()
    }
  }
}
