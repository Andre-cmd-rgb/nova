import QtQuick
import Quickshell
import qs.Commons

// Util's pure helpers. decodeBase64 carries the theme and the image picker's
// rows over IPC: UTF-8 text in, and nothing at all for what is not.
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
    console.log("DONE")
    Qt.quit()
  }
}
