// stub: bin/hyprctl hyprctl
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

// What Style asks Hyprland, with hyprctl a stub: its rounding and gaps once
// as the shell starts, not again for the gaps toggle's first reading; and
// again when the toggle changes.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")

  function check(name, got, want) {
    const same = JSON.stringify(got) === JSON.stringify(want)
    console.log((same ? "ok   " : "FAIL ") + name + (same ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  function asked() {
    callsFile.reload()
    return callsFile.text().split("\n").filter(line => line.indexOf(" getoption ") >= 0)
  }

  FileView {
    id: callsFile
    path: test.home + "/stub-calls"
    blockLoading: true
    printErrors: false
  }

  // The gaps toggle turned on, as `nova toggle window-gaps` does it.
  Process {
    id: toggle
    command: ["sh", "-c", "printf -- '-- no gaps\\n' >\"$0\"", Commons.Color.stateHome + "/nova/toggles/hypr/window-no-gaps.lua"]
  }

  // The gaps toggle's file, off, then Style, made as it is first read.
  Process {
    id: folder
    command: ["sh", "-c", "mkdir -p \"${0%/*}\" && : >\"$0\"", Commons.Color.stateHome + "/nova/toggles/hypr/window-no-gaps.lua"]
    onExited: {
      console.log("ok   Style's corners start at " + Style.cornerRadius)
      started.start()
    }
  }

  Component.onCompleted: folder.running = true

  // Given time, the second reading of old would have come by now.
  Timer {
    id: started
    interval: 1000
    onTriggered: {
      test.check("asked once as the shell starts", test.asked().sort(),
        ["hyprctl -j getoption decoration:rounding", "hyprctl -j getoption general:gaps_out"])
      toggle.running = true
      changed.start()
    }
  }

  // Looked at every 50 ms, for 5 s at most.
  Timer {
    id: changed
    property int left: 100
    interval: 50
    repeat: true
    onTriggered: {
      if (test.asked().length < 4 && --left > 0) return
      stop()
      test.check("and again when the gaps toggle changes", test.asked().length, 4)
      console.log("DONE")
      Qt.quit()
    }
  }
}
