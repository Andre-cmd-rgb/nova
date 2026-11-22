// stub: bin/busctl refusing
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/lock" as Lock

// logind's LockedHint follows the lock: true once it is secure, false when
// it ends, nothing at the start; a change while a call runs is made after it,
// so the last call says what the lock is. It is set on this session's own
// object ($XDG_SESSION_ID, escaped as sd-bus escapes it, or "auto"); a call
// that fails is made once more, and no more; a new logind (the file
// nova-sessiond writes) hears it again while the lock is secure. busctl is a
// stub that notes its calls and fails as many as $HOME/refusals says; no bus.
ShellRoot {
  id: test

  property bool secure: false
  property Item stage: Item {}
  property var hint: null
  // How many calls were said before the step under way.
  property int seen: 0

  Component {
    id: maker
    Lock.LockedHint { secure: test.secure }
  }

  Component {
    id: named
    Lock.LockedHint { secure: false }
  }

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  FileView { id: calls; path: Quickshell.env("HOME") + "/stub-calls"; blockAllReads: true; printErrors: false }
  function lines() {
    calls.reload()
    return String(calls.text() || "").split("\n").filter(line => line !== "")
  }
  function said() {
    return lines().map(line => line.replace(/^.* SetLockedHint b /, ""))
  }
  // The calls said since the step began.
  function fresh() { return JSON.stringify(said().slice(seen)) }
  function mark() { seen = said().length }

  Process { id: shell }
  function write(script) {
    shell.command = ["sh", "-c", script]
    shell.running = true
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

  function pathOf(login) {
    const one = named.createObject(stage, { login: login })
    const path = one.sessionPath
    one.destroy()
    return path
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(() => {
    hint = maker.createObject(stage)
    const session = "/org/freedesktop/login1/session/"
    check(pathOf("1") === session + "_31" && pathOf("c2") === session + "c2" && pathOf("12") === session + "_312",
      "the session's object is its name, escaped as logind's: 1 is _31, c2 is c2")
    check(pathOf("") === session + "auto" && pathOf("../x") === session + "auto",
      "no name, or one logind would not give, is logind's auto")
    later(300, () => {
      check(said().length === 0, "nothing is said as the shell starts")
      secure = true
      later(400, () => {
        check(fresh() === JSON.stringify(["true"]) && lines()[0].includes(" " + session + "auto "),
          "the lock secure: the hint is true, on the session ($XDG_SESSION_ID unset here: auto)")
        secure = false
        secure = true
        secure = false
        later(600, () => {
          const all = said()
          check(all.length >= 2 && all[all.length - 1] === "false", "changes while a call runs end with the lock as it is: unlocked, false")
          retries()
        })
      })
    })
  })

  function retries() {
    write("echo 1 >\"$HOME/refusals\"")
    later(200, () => {
      mark()
      secure = true
      later(600, () => {
        check(fresh() === JSON.stringify(["true", "true"]), "a call that fails is made once more")
        write("echo 2 >\"$HOME/refusals\"")
        later(200, () => {
          mark()
          secure = false
          later(600, () => {
            check(fresh() === JSON.stringify(["false", "false"]), "and only once")
            newLogind()
          })
        })
      })
    })
  }

  function newLogind() {
    mark()
    write("rm -f \"$HOME/refusals\"; echo '1 0' >\"$XDG_RUNTIME_DIR/nova/logind\"")
    later(700, () => {
      check(fresh() === "[]", "a new logind while unlocked: nothing, its own false is right")
      secure = true
      later(400, () => {
        mark()
        write("echo '1 1' >\"$XDG_RUNTIME_DIR/nova/logind\"")
        later(700, () => {
          check(fresh() === JSON.stringify(["true"]), "a new logind under the lock: the hint is said again")
          console.log("DONE")
          Qt.quit()
        })
      })
    })
  }
}
