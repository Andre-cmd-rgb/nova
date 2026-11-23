// platform: wayland
// stub: bin/nova-hyprland-session-lock-stranded stranded
// stub: bin/nova-automount record
// stub: bin/fprintd-list record
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "plugins/lock" as Lock

// The lock service started again, as after a shell's crash: the session is
// not open (sessionOpen, which the polkit agent and the drives' mounting go
// by) while the stranded-lock helper cannot tell whether a lock was left
// behind, which it says while any process named like a locker runs; and it
// keeps asking past its quick tries, so the session opens once the helper
// can tell. The helper is a stub answering what the test writes; the boot's
// first unlock is marked done, so nothing locks.
ShellRoot {
  id: test

  property var service: null
  property Item stage: Item {}

  Component {
    id: maker
    Lock.Service {}
  }

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  FileView { id: calls; path: Quickshell.env("HOME") + "/stub-calls"; blockAllReads: true; printErrors: false }
  function called(prefix) {
    calls.reload()
    return String(calls.text() || "").split("\n").filter(line => line.startsWith(prefix))
  }

  Timer {
    id: wait
    property var next: null
    onTriggered: next()
  }
  function later(ms, next) {
    wait.interval = ms
    wait.next = next
    wait.restart()
  }

  // The helper's answer from now on.
  Process {
    id: answer
    property var after: null
    function say(code, then) {
      after = then
      command = ["sh", "-c", "echo " + code + " >\"$HOME/stranded\""]
      running = true
    }
    onExited: after()
  }

  Process {
    id: prepare
    command: ["sh", "-c", "mkdir -p \"$XDG_RUNTIME_DIR/nova\" && echo 1 >\"$XDG_RUNTIME_DIR/nova/unlocked-once\" && echo 2 >\"$HOME/stranded\""]
    onExited: {
      test.check(!Commons.BootLock.unlocked, "an autologin shell starts with the boot's first unlock to come")
      test.service = maker.createObject(test.stage)
      test.later(1000, test.first)
    }
  }

  function first() {
    check(Commons.BootLock.unlocked, "the first unlock read back from the runtime folder: the keyring's readers go on (Commons/BootLock.qml)")
    check(!service.sessionOpen && !service.locked, "while the helper cannot tell, the session is not open, though nothing is locked")
    check(called("nova-automount ").length >= 1 && called("nova-automount on").length === 0, "and drives do not mount")
    // Past the 20 quick tries, 500 ms apart.
    later(10500, second)
  }

  function second() {
    check(called("nova-hyprland-session-lock-stranded ").length >= 20 && !service.sessionOpen, "the quick tries are spent, the session still not open")
    // The process named like a locker has gone: the helper can tell.
    answer.say(1, () => test.later(6000, test.third))
  }

  function third() {
    check(service.sessionOpen, "the question is asked on past them, and the session opens once the helper can tell")
    check(called("nova-automount on").length === 1, "and drives mount")
    console.log("DONE")
    Qt.quit()
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(() => { prepare.running = true })
}
