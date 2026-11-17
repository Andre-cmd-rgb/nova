// stub: bin/nova-settings nova-settings
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/settings" as Settings

// What Settings shows while a change runs: what the change sets, at once,
// laid over what was read, and the rest of the state the very objects read;
// what was read again once its command is done, which for a command that
// failed is the state as it was, its failure said; and a change still shown
// when a read that began before its command was done comes back.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function same(got, want, what) {
    const ok = JSON.stringify(got) === JSON.stringify(want)
    check(ok, what + (ok ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  // Waits for <done> to hold, then calls <then>; fails <what> after 5 s.
  function when(done, then, what) {
    waiter.done = done
    waiter.then = then
    waiter.what = what
    waiter.left = 100
    waiter.start()
  }

  Timer {
    id: waiter
    property var done: null
    property var then: null
    property string what: ""
    property int left: 0
    interval: 50
    repeat: true
    onTriggered: {
      if (done()) {
        stop()
        then()
      } else if (--left <= 0) {
        stop()
        test.check(false, what)
        test.finish()
      }
    }
  }

  // The next turn after <ms>.
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

  FileView {
    id: stateFile
    path: test.home + "/settings-state.json"
    printErrors: false
    blockWrites: true
  }

  Settings.SettingsState { id: state }

  readonly property string first: JSON.stringify({ bar: { transparent: false, position: "top" }, lock: { seconds: 300 } })

  // Nothing running, nothing waiting, nothing laid over.
  function settled() {
    return !state.actionProc.running && !state.stateProc.running && state.queue.length === 0 && state.asked.length === 0
  }

  function begin() {
    stateFile.setText(first)
    state.load()
    when(() => state.loaded, shownAtOnce, "the state is read")
  }

  function shownAtOnce() {
    same(state.info.bar.transparent, false, "read: the bar is solid")
    const lock = state.read.lock
    state.run(["sh", "-c", "sleep 0.3"], { "bar.transparent": true })
    same(state.info.bar.transparent, true, "a change is shown at once, before its command has run")
    same(state.info.bar.position, "top", "what it does not set is as read")
    check(state.info.lock === lock, "the rest of the state is the very object read")
    same(state.read.bar.transparent, false, "what was read stays as read")
    when(settled, readBack, "the change runs and the state is read again")
  }

  function readBack() {
    // The command set nothing: what is shown is the state as read.
    same(state.info.bar.transparent, false, "once read again, what is shown is what is set")
    same(state.failure, "", "no failure")
    state.run(["sh", "-c", "echo 'the lock could not be set' >&2; exit 1"], { "lock.seconds": 0 })
    same(state.info.lock.seconds, 0, "a change that will fail is shown at once too")
    when(settled, failed, "the failing change runs and the state is read again")
  }

  function failed() {
    same(state.info.lock.seconds, 300, "a change that failed goes back to the state as it was")
    same(state.failure, "the lock could not be set", "and its failure is said")
    const set = JSON.stringify({ bar: { transparent: true, position: "top" }, lock: { seconds: 300 } })
    state.run(["sh", "-c", "printf '%s' '" + set + "' >\"$HOME/settings-state.json\""], { "bar.transparent": true })
    when(settled, kept, "the setting change runs and the state is read again")
  }

  function kept() {
    same(state.info.bar.transparent, true, "a change that took is shown as read")
    // A read begun while a change's command still runs comes back without it.
    state.run(["sh", "-c", "sleep 0.8"], { "bar.position": "left" })
    later(100, () => {
      state.load()
      when(() => !state.stateProc.running && state.actionProc.running, readMidway, "a read during the change comes back")
    })
  }

  function readMidway() {
    same(state.read.bar.position, "top", "the read during the change has it as it was")
    same(state.info.bar.position, "left", "and the change is still shown over it")
    when(settled, () => {
      same(state.info.bar.position, "top", "once its command is done and read again, what is set is shown")
      finish()
    }, "the change runs and the state is read again")
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(begin)
}
