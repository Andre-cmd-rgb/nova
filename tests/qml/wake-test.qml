import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Wake, the shell's word that the wall clock moved: nova-sessiond's stamp in
// $XDG_RUNTIME_DIR/nova/clock, written whole and moved into place. What the
// file held before the shell started is not news; each new line is, once:
// a wake, a clock set, a new time zone; the same line written again is not;
// a file removed and made again is. No timer of Wake's own runs.
ShellRoot {
  id: test

  readonly property string stamp: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/clock"
  // Wake is made at its first use, once the stamp from before is there.
  property bool armed: false
  property int woken: 0
  property var steps: []

  function check(name, got, want) {
    const same = JSON.stringify(got) === JSON.stringify(want)
    console.log((same ? "ok   " : "FAIL ") + name + (same ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  Connections {
    target: test.armed ? Wake : null
    function onWoke() { test.woken++ }
  }

  // Writes <line> as nova-sessiond does, or removes the stamp for "".
  Process {
    id: writer
    property string line: ""
    command: ["bash", "-c", '[[ -n $2 ]] || { rm -f "$1"; exit; }; mkdir -p "${1%/*}"; printf "%s\\n" "$2" >"$1.new" && mv -f "$1.new" "$1"', "stamp", test.stamp, line]
    onExited: settle.restart()
  }

  // Long enough for the file's read, and the one after it.
  Timer {
    id: settle
    interval: 700
    onTriggered: test.next()
  }

  function write(line, then) {
    steps.unshift(then)
    writer.line = line
    writer.running = true
  }

  function next() {
    const step = steps.shift()
    if (step) step()
  }

  Component.onCompleted: Qt.callLater(() => write("woke 1000", () => {
    armed = true
    steps.unshift(() => {
      check("what the file held before the shell started is not news", woken, 0)
      write("set 2000", () => {
        check("a clock set is", woken, 1)
        write("set 2000", () => {
          check("the same line written again is not", woken, 1)
          write("zone 3000", () => {
            check("a new time zone is", woken, 2)
            write("", () => {
              check("the file removed is not", woken, 2)
              write("woke 4000", () => {
                check("made again, a wake is", woken, 3)
                console.log("DONE")
                Qt.quit()
              })
            })
          })
        })
      })
    })
    settle.restart()
  }))
}
