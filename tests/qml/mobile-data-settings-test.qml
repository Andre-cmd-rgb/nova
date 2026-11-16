// stub: bin/nova-mobile-data nova-mobile-data
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/settings" as Settings

// Settings → Mobile Data against a stub of nova-mobile-data: the SIM's PIN
// goes to `pin` on its standard input and never among its arguments, a
// network that refuses the APN (exit 3) has the page ask for one, and the
// APN given is set and then mobile data turned on, in that order.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  Settings.MobileDataView { id: page; width: 600 }

  // A file written, and <then> once it is.
  property var then: null
  function write(file, text, next) {
    then = next
    file.setText(text)
  }
  function saved() {
    const next = then
    then = null
    if (next) next()
  }

  FileView { id: infoFile; path: test.home + "/md-info"; printErrors: false; onSaved: test.saved() }
  FileView { id: onStatus; path: test.home + "/md-on-status"; printErrors: false; onSaved: test.saved() }
  FileView { id: onError; path: test.home + "/md-on-error"; printErrors: false; onSaved: test.saved() }
  FileView { id: ranFile; path: test.home + "/md-ran"; blockLoading: true; printErrors: false }

  function ran() {
    ranFile.reload()
    return ranFile.text().trim().split("\n")
  }

  // <next> once <ready> holds, looked at every 50 ms for up to 5 s.
  function when(ready, next, what) {
    waiter.ready = ready
    waiter.next = next
    waiter.what = what
    waiter.tries = 0
    waiter.restart()
  }

  Timer {
    id: waiter
    property var ready: null
    property var next: null
    property string what: ""
    property int tries: 0
    interval: 50
    repeat: true
    onTriggered: {
      if (ready()) {
        stop()
        next()
      } else if (++tries > 100) {
        stop()
        test.check(false, what)
        test.finish()
      }
    }
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  Component.onCompleted: write(infoFile, "hw=yes\nstate=locked\nunlock=sim-pin\npin_tries=2\nmanaged=yes\nprofile=very\n", () => {
    page.load()
    when(() => page.modem === "locked", locked, "the page reads a locked SIM")
  })

  function locked() {
    check(page.summary === "The SIM needs its PIN.", "a locked SIM: the page says it needs its PIN")
    page.unlock("12")
    check(!page.busy, "a PIN of two digits is not sent")
    page.unlock("1234")
    when(() => !page.busy && ran()[0] !== "", unlocked, "the PIN is sent and done")
  }

  function unlocked() {
    check(JSON.stringify(ran()) === JSON.stringify(["pin stdin=1234"]), "the PIN goes on the standard input, not among the arguments")
    write(onError, "mobile-data: the network does not know the APN \"internet.it\": Settings > Mobile Data takes another\n",
      () => write(onStatus, "3\n", refuse))
  }

  function refuse() {
    page.run(["nova-mobile-data", "on"])
    when(() => !page.busy && page.failure !== "", refused, "the refused connection is said")
  }

  function refused() {
    check(page.askApn, "a network that does not know the APN (exit 3): the page asks for one")
    check(page.failure === "The network does not know the APN \"internet.it\": Settings > Mobile Data takes another.", "and says why, as a sentence")
    write(onStatus, "", () => {
      page.run(["nova-mobile-data", "apn", "web.it"], ["nova-mobile-data", "on"])
      when(() => ran().length >= 4 && !page.busy, chained, "the APN is set and mobile data turned on")
    })
  }

  function chained() {
    const lines = ran()
    check(lines[2] === "apn web.it" && lines[3] === "on", "the APN given is set first, and then mobile data turned on")
    check(!page.askApn && page.failure === "", "connected: the APN is asked for no more")
    finish()
  }
}
