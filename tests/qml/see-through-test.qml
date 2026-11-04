import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/bar" as Bar

// The text colour of a see-through bar (SeeThrough), against a stub picker
// that reads the "wallpaper" as it starts and answers 0.6 s later. A change
// while it runs makes its answer stale: the bar must ask again, and show the
// colour for the wallpaper as it is now.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  property bool ran: false

  Bar.SeeThrough {
    id: seeThrough
    pickCommand: test.home + "/pick"
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
    id: pick
    path: test.home + "/pick"
    preload: false
    printErrors: false
    onSaved: executable.running = true
  }

  Process {
    id: executable
    command: ["chmod", "+x", test.home + "/pick"]
    onExited: wall.setText("#111111\n")
  }

  Connections {
    target: wall
    function onSaved() { if (!test.ran) test.begin() }
  }

  function check(name, got, want) {
    console.log((got === want ? "ok   " : "FAIL ") + name + (got === want ? "" : ": got " + got + ", want " + want))
  }

  Component.onCompleted: pick.setText('#!/bin/sh\nread -r colour <"$HOME/wall"\nsleep 0.6\necho "$colour"\n')

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
      wall.setText("#222222\n")
      seeThrough.edge = "bottom"
      settled.start()
    }
  }

  Timer {
    id: settled
    interval: 2500
    onTriggered: {
      check("see-through once the picker answers", seeThrough.shown, true)
      check("  in the colour for the wallpaper as it is now", String(seeThrough.colour), "#222222")
      console.log("DONE")
      Qt.quit()
    }
  }
}
