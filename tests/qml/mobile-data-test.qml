// platform: wayland
// stub: home/mobile/bin/mobile-data mobile-data
// stub: bin/gdbus gdbus
import QtQuick
import Quickshell
import Quickshell.Io

// The mobile data bar widget, the real BarWidget.qml, fed states by a stub of
// the helper it runs (`mobile-data info`). The widget finds the helper beside
// its own file, so the test makes a copy of the widget in the scratch home,
// next to the stub, and loads that. The stub answers with the text the test
// writes to $HOME/mobile-info and notes a `toggle` in $HOME/mobile-ran.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  readonly property string copy: home + "/mobile/BarWidget.qml"
  property var widget: null
  property Item stage: Item {}

  property QtObject fakeBar: QtObject {
    readonly property bool vertical: false
    readonly property int thickness: 30
    readonly property string position: "top"
    readonly property string fontFamily: "monospace"
    readonly property color foreground: "white"
    readonly property color background: "black"
    readonly property color textColour: "white"
    readonly property color urgent: "red"
    readonly property bool textFades: false
    readonly property bool peek: false
    property var popup: null
    property var buttons: []
    property QtObject tip: QtObject {
      function ask(button, text) {}
      function withdraw(button) {}
    }
    property QtObject shell: QtObject {
      function serviceFor(id) { return null }
    }
    function listButton(button, on) {}
    function claimPopup(key, open) { popup = open ? key : null }
    function inWindow(item, window) { return false }
    function nextPanel(owner, step) { return false }
    function run(command) {}
  }

  FileView {
    id: installed
    path: Quickshell.env("TEST_PLUGINS") + "/mobile-data/BarWidget.qml"
    blockLoading: true
  }

  FileView {
    id: copyFile
    path: test.copy
    printErrors: false
    onSaved: test.begin()
  }

  FileView {
    id: infoFile
    path: test.home + "/mobile-info"
    printErrors: false
    onSaved: test.fed()
  }

  FileView {
    id: ranFile
    path: test.home + "/mobile-ran"
    blockLoading: true
    printErrors: false
  }

  FileView {
    id: failFile
    path: test.home + "/mobile-fail"
    printErrors: false
  }

  function check(name, got, want) {
    const same = JSON.stringify(got) === JSON.stringify(want)
    console.log((same ? "ok   " : "FAIL ") + name + (same ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  function find(item, test) {
    const below = item.contentItem ? [item.contentItem] : item.children
    for (const child of below) {
      if (test(child)) return child
      const deeper = find(child, test)
      if (deeper) return deeper
    }
    return null
  }

  function surface() {
    for (const child of widget.data) if (child.keys !== undefined && child.host !== undefined) return child
    return null
  }

  function toggleSwitch() {
    return find(surface(), item => item.checked !== undefined && item.busy !== undefined && item.toggled !== undefined)
  }

  // The widget's own wording of the state, by what the helper said.
  function info(state, more) {
    return "hw=yes\nstate=" + state + "\nmanaged=yes\nprofile=home\n" + (more || "")
  }

  // Writes <text> as the helper's answer and has the widget ask, then waits
  // until its state is <state> and calls <then>.
  property string waitingFor: ""
  property var then: null
  function feed(text, state, next) {
    waitingFor = state
    then = next
    infoFile.setText(text)
  }

  function fed() {
    // Written for the widget to find by itself.
    if (!then) return
    widget.refresh()
    settle(0)
  }

  function settle(tries) {
    if (widget.wwanState === waitingFor) {
      const next = then
      then = null
      next()
    } else if (tries > 100) {
      check("the widget reads state " + waitingFor, widget.wwanState, waitingFor)
      finish()
    } else {
      // A look asked while the last one runs is not made: asked again.
      widget.refresh()
      Qt.callLater(() => waitTimer.restartFor(tries))
    }
  }

  Timer {
    id: waitTimer
    interval: 50
    property int tries: 0
    function restartFor(n) { tries = n + 1; restart() }
    onTriggered: test.settle(tries)
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  // The next turn after <ms>, for what takes the stub a moment.
  function later(ms, next) {
    laterTimer.next = next
    laterTimer.interval = ms
    laterTimer.restart()
  }

  Timer {
    id: laterTimer
    property var next: null
    onTriggered: next()
  }

  Component.onCompleted: copyFile.setText(installed.text())

  function begin() {
    if (widget) return
    const made = Qt.createComponent("file://" + copy)
    if (made.status !== Component.Ready) {
      check("the widget loads", made.errorString(), "")
      return finish()
    }
    widget = made.createObject(stage, { bar: fakeBar })
    feed(info("connected", "operator=Smoke\ntech=5G\nsignal=70\nused_bytes=1048576\nnext_reset=2026-12-01\n"), "connected", connected)
  }

  function connected() {
    check("connected: shown in the bar", widget.visible, true)
    check("connected: the meta line names the operator and the technology", widget.metaText, "Smoke · 5G")
    check("connected: no hint", widget.hintText, "")
    widget.open()
    check("connected: the panel opens", surface().open, true)
    check("connected: the switch is on", toggleSwitch()?.checked, true)
    widget.close()
    feed(info("disabled"), "disabled", disabled)
  }

  function disabled() {
    check("disabled: the meta line says it is off", widget.metaText, "Mobile data off")
    widget.open()
    check("disabled: the switch is off", toggleSwitch()?.checked, false)
    toggleSwitch().toggled()
    check("disabled: the switch's toggle sets the switch heading on", widget.desired, true)
    later(1500, afterToggle)
  }

  function afterToggle() {
    ranFile.reload()
    check("the switch's toggle ran the helper's toggle, once", ranFile.text().trim(), "toggle")
    check("the toggle done: the switch is no longer busy", widget.busy, false)
    widget.close()
    failFile.setText("mobile-data: the SIM is locked and needs its PIN\nmore words\n")
    later(300, failing)
  }

  function failing() {
    widget.toggleData()
    later(1500, afterFailure)
  }

  function afterFailure() {
    check("a refused toggle: the hint is the helper's first line, plain", widget.hintText, "the SIM is locked and needs its PIN")
    feed(info("noservice"), "noservice", noservice)
  }

  function noservice() {
    check("noservice: the meta line says ModemManager is not running", widget.metaText, "ModemManager is not running")
    widget.lastError = ""
    check("noservice: the hint names the command to run", widget.hintText.indexOf("sudo systemctl enable --now ModemManager.service") >= 0, true)
    feed(info("starting"), "starting", starting)
  }

  function starting() {
    check("starting: the meta line says the modem is starting", widget.metaText, "Modem starting…")
    check("starting: the hint says to wait", widget.hintText.indexOf("half a minute") >= 0, true)
    check("starting: the switch shows it is under way rather than off", widget.pending, true)
    feed(info("failed", "why=noenable\n"), "failed", failed)
  }

  function failed() {
    check("failed: the meta line says the modem could not be turned on", widget.metaText, "The modem could not be turned on")
    check("failed: the hint says it stopped trying, and what tries again", widget.hintText.indexOf("stops trying") >= 0, true)
    feed(info("locked", "unlock=sim-pin\npin_tries=3\n"), "locked", locked)
  }

  function locked() {
    check("locked: the meta line says the SIM needs its PIN", widget.metaText, "The SIM needs its PIN")
    check("locked: the hint says where it is asked for", widget.hintText, "Settings → Mobile Data asks for it.")
    feed("hw=yes\nstate=noprofile\nmanaged=yes\nprofile=\n", "noprofile", noprofile)
  }

  function noprofile() {
    check("not set up: the meta line says so", widget.metaText, "Not set up yet")
    widget.open()
    check("not set up: the switch is there, off, to set it up", [toggleSwitch()?.visible, toggleSwitch()?.checked], [true, false])
    widget.close()
    feed(info("parked"), "parked", parked)
  }

  function parked() {
    check("parked: the meta line says off, no SIM", widget.metaText, "Off — no SIM")
    check("parked: the widget leaves the bar", [widget.shown, widget.visible], [false, false])
    // A SIM put in: ModemManager probes the modem afresh (the stub gdbus's
    // line, as the widget parked), and the widget looks by itself, its
    // polls stopped.
    then = null
    infoFile.setText(info("disconnected"))
    later(4500, simHeard)
  }

  function simHeard() {
    check("parked: a SIM going in is heard, and the widget looks by itself", widget.wwanState, "disconnected")
    finish()
  }
}
