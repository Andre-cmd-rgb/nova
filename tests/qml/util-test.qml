import QtQuick
import Quickshell
import qs.Commons

// Util's pure helpers. decodeBase64 carries the theme and the image picker's
// rows over IPC: UTF-8 text in, and nothing at all for what is not. stepIndex
// moves the menu's and the clipboard's cursor.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    check(Util.decodeBase64("w7FvdmEg4pyTIHswLDF9") === "ñova ✓ {0,1}", "base64 decodes to UTF-8 text")
    check(Util.decodeBase64("YmFja2dyb3VuZCA9ICMxZTFlMmUK") === "background = #1e1e2e\n", "a theme line survives the trip")
    check(Util.decodeBase64("") === "" && Util.decodeBase64(undefined) === "", "nothing decodes to nothing")
    check(Util.decodeBase64("/w==") === "", "bytes that are not UTF-8 decode to nothing")
    check(Util.stepIndex(0, -1, 4) === 3 && Util.stepIndex(3, 1, 4) === 0, "an arrow wraps round the ends")
    check(Util.stepIndex(0, -6, 4) === 0 && Util.stepIndex(1, 6, 4) === 3 && Util.stepIndex(9, -6, 12) === 3,
      "a page stops at the ends")
    // Hyprland's windows, as Quickshell lists them: the shell's own are
    // org.quickshell's, told apart by their titles.
    var here = { id: 2 }, there = { id: 5 }
    var windows = [
      { title: "Settings", wayland: { appId: "org.gnome.Settings" }, workspace: there },
      { title: "Calendar", wayland: { appId: "org.quickshell" }, workspace: here },
      { title: "Settings", wayland: null, lastIpcObject: { "class": "org.quickshell" }, workspace: there },
      { title: "Clock", wayland: { appId: "org.quickshell" }, workspace: null },
    ]
    check(Util.onAnotherWorkspace(windows, "Settings", 2) && !Util.onAnotherWorkspace(windows, "Settings", 5),
      "the shell's window on another workspace is told from one on this")
    check(!Util.onAnotherWorkspace(windows, "Calendar", 2) && Util.onAnotherWorkspace(windows, "Calendar", 3),
      "by its title and its workspace")
    check(!Util.onAnotherWorkspace([windows[0]], "Settings", 2), "another program's window of the same title is not the shell's")
    check(!Util.onAnotherWorkspace(windows, "Clock", 2) && !Util.onAnotherWorkspace(windows, "Settings", null)
      && !Util.onAnotherWorkspace(undefined, "Settings", 2) && !Util.onAnotherWorkspace(windows, "Weather", 2),
      "a workspace not known, none focused, no windows or no such window: it is here")
    console.log("DONE")
    Qt.quit()
  }
}
