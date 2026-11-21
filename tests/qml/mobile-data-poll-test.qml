// stub: home/mobile/bin/mobile-data mobile-data
// stub: bin/rfkill rfkill-then
import QtQuick
import Quickshell
import Quickshell.Io

// What the mobile data service asks while no panel is open, by the lines its
// helper's stub writes for each `info` ($HOME/mobile-asked). Connected, the
// background poll takes the stats (`info --verbose`, the byte counters and a
// ping). Off at the radio (`radio=blocked`), nothing is asked: the radio is
// listened for, and turned on again it is heard and looked at. Otherwise
// (here a SIM that wants its PIN, then ModemManager's own disabled with the
// radio on, as just after it comes on) the poll goes on, the plain one, with
// no ping to wake a radio for. The service is a copy of the real one beside
// the stub, which it finds by its own path.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  readonly property string serviceCopy: home + "/mobile/Service.qml"
  property var service: null
  property Item stage: Item {}

  // A copy of the widget, as the service sees one: its entry polls every
  // 2 s (the least there is), and its panel is shut.
  property QtObject holder: QtObject {
    property bool opened: false
    function setting(name, fallback) { return name === "interval" ? 2 : fallback }
  }

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  function info(state, more) {
    return "hw=yes\nstate=" + state + "\nmanaged=yes\nprofile=home\n" + (more || "")
  }

  FileView {
    id: installed
    path: Quickshell.env("TEST_PLUGINS") + "/mobile-data/Service.qml"
    blockLoading: true
  }

  FileView {
    id: copyFile
    path: test.serviceCopy
    printErrors: false
    onSaved: radioFile.setText("idx 3 type 5 op 0 soft 1 hard 0\n")
  }

  // The WWAN radio as the watch says it when it starts: soft-blocked.
  FileView {
    id: radioFile
    path: test.home + "/rfkill-event"
    printErrors: false
    onSaved: infoFile.setText(test.info("connected", "iface=wwan0\noperator=Smoke\ntech=5G\nsignal=70\n"))
  }

  // What to do once the helper's next answer is written, so that nothing
  // the test does next can find the last one.
  property var afterInfo: null

  FileView {
    id: infoFile
    path: test.home + "/mobile-info"
    printErrors: false
    onSaved: {
      if (!test.service) return test.begin()
      const next = test.afterInfo
      test.afterInfo = null
      if (next) next()
    }
  }

  FileView {
    id: nextFile
    path: test.home + "/rfkill-next"
    printErrors: false
  }

  FileView {
    id: askedFile
    path: test.home + "/mobile-asked"
    blockLoading: true
    printErrors: false
  }

  function asked() {
    askedFile.reload()
    askedFile.waitForJob()
    return String(askedFile.text()).split("\n").filter(line => line !== "")
  }

  Component.onCompleted: copyFile.setText(installed.text())

  // <ready>() polled every 100 ms, for at most <ms>; then <next>(whether it
  // came true).
  function when(ready, ms, next) {
    waiter.ready = ready
    waiter.next = next
    waiter.left = Math.ceil(ms / 100)
    waiter.restart()
  }

  Timer {
    id: waiter
    interval: 100
    repeat: true
    property var ready: null
    property var next: null
    property int left: 0
    onTriggered: {
      const done = ready()
      if (done || --left <= 0) {
        stop()
        next(done)
      }
    }
  }

  function begin() {
    const made = Qt.createComponent("file://" + serviceCopy)
    if (made.status !== Component.Ready) {
      check(false, "the service loads: " + made.errorString())
      return finish()
    }
    service = made.createObject(stage)
    service.hold(holder)
    when(() => asked().indexOf("info --verbose") >= 0, 8000, connected)
  }

  function connected(sampled) {
    check(service.connected, "the service reads the modem connected")
    check(sampled, "connected, the background poll takes the stats: " + JSON.stringify(asked()))
    infoFile.setText(info("disabled", "radio=blocked\n"))
    when(() => service.wwanState === "disabled", 8000, off)
  }

  property int askedOff: 0

  function off(read) {
    check(read, "mobile data turned off is read")
    check(service.quiet && service.listening, "off, the service listens to the radio")
    askedOff = asked().length
    // Two polls' time and more.
    when(() => false, 5000, stillOff)
  }

  function stillOff() {
    check(asked().length === askedOff, "off, nothing is polled (" + (asked().length - askedOff) + " looks)")
    // Turned on again: the SIM wants its PIN, which is no connection either.
    // The radio's change comes once that answer is there.
    afterInfo = () => {
      nextFile.setText("idx 3 type 5 op 2 soft 0 hard 0\n")
      when(() => service.wwanState === "locked", 8000, turnedOn)
    }
    infoFile.setText(info("locked", "unlock=sim-pin\npin_tries=3\n"))
  }

  property int askedOn: 0

  function turnedOn(read) {
    check(read, "the radio turned on is heard, and the modem looked at")
    check(!service.quiet && !service.listening, "on, the service polls again and stops listening")
    askedOn = asked().length
    when(() => asked().length >= askedOn + 2, 8000, polled)
  }

  function polled(twice) {
    const since = asked().slice(askedOn)
    check(twice, "on, the background poll runs (" + since.length + " looks)")
    check(since.every(line => line === "info"), "not connected, the poll is the plain one, with no ping: " + JSON.stringify(since))
    // ModemManager's own disabled, the radio on: no rfkill change will come.
    infoFile.setText(info("disabled"))
    when(() => service.wwanState === "disabled", 8000, modemDisabled)
  }

  property int askedDisabled: 0

  function modemDisabled(read) {
    check(read, "the modem disabled with its radio on is read")
    check(!service.off && !service.quiet, "the radio on, a disabled modem is not off: the service goes on looking")
    askedDisabled = asked().length
    when(() => asked().length >= askedDisabled + 2, 8000, stillLooking)
  }

  function stillLooking(twice) {
    check(twice, "and it looks again (" + (asked().length - askedDisabled) + " looks)")
    service.release(holder)
    check(!service.wanted, "let go, the service rests")
    finish()
  }
}
