// platform: wayland
// warns: Module path contains invalid characters for a module name
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/image-picker" as Picker

// A request with no image to show, a folder with none in it, does not open
// the picker: it would hold the keyboard with nothing to take the keys. The
// one waiting is let go at once.
ShellRoot {
  id: test

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  Picker.ImagePicker { id: picker }

  FileView {
    id: done
    path: Quickshell.env("HOME") + "/done"
    printErrors: false
  }

  Component.onCompleted: Qt.callLater(run)

  function run() {
    picker.start("/nowhere", "\n\t/t/orphan.jpg\n", "", "", Quickshell.env("HOME") + "/done", false, false)
    check(picker.opened && picker.waiting, "a request with rows opens the picker as it comes")
    settle.start()
  }

  Timer {
    id: settle
    interval: 400
    onTriggered: {
      done.reload()
      reread.start()
    }
  }

  Timer {
    id: reread
    interval: 300
    onTriggered: {
      check(!picker.opened && !picker.waiting, "rows with no image in them: the picker shuts")
      check(done.loaded, "and the one waiting is given its done file")
      console.log("DONE")
      Qt.quit()
    }
  }
}
