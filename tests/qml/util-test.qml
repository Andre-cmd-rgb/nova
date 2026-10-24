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
    console.log("DONE")
    Qt.quit()
  }
}
