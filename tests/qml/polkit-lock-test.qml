// platform: wayland
// warns: failed to create subject for listener
// warns: failed to register listener
import QtQuick
import Quickshell
import "plugins/polkit" as Polkit

// Nothing is asked behind the lock: a request that starts while the screen
// is locked is cancelled at once and shows no card, and the one asked when
// the lock comes up is cancelled then. Polkit's request is a stand-in that
// counts its cancels; no bus, so polkit's own agent does not register.
ShellRoot {
  id: test

  property QtObject lock: QtObject { property bool locked: false }
  property QtObject fakeShell: QtObject {
    function serviceFor(id) { return id === "nova.lock" ? test.lock : null }
  }
  property var agent: null
  property Item stage: Item {}

  Component {
    id: maker
    Polkit.PolkitAgent {}
  }

  Component {
    id: flowMaker
    QtObject {
      property string message: "Authentication is needed to run `/usr/bin/true' as the super user"
      property bool isResponseRequired: true
      property bool responseVisible: false
      property string inputPrompt: ""
      property string supplementaryMessage: ""
      property bool failed: false
      property int cancels: 0
      property var submitted: []
      signal authenticationFailed()
      signal authenticationSucceeded()
      signal authenticationRequestCancelled()
      function cancelAuthenticationRequest() { cancels++ }
      function submit(text) { submitted = submitted.concat([text]) }
    }
  }

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(() => {
    agent = maker.createObject(stage, { shell: fakeShell })

    lock.locked = true
    const behind = flowMaker.createObject(stage)
    agent.flow = behind
    agent.requestStarted()
    check(behind.cancels === 1 && behind.submitted.length === 0 && !agent.shown && agent.surface === null,
      "a request that starts behind the lock is cancelled at once, and no card shows")

    lock.locked = false
    const asked = flowMaker.createObject(stage)
    agent.flow = asked
    agent.requestStarted()
    check(asked.cancels === 0, "one that starts while unlocked is asked")
    lock.locked = true
    check(asked.cancels === 1 && !agent.shown, "and cancelled when the lock comes up, its card gone")
    lock.locked = false
    check(asked.cancels === 1, "the unlock asks nothing again: the program asks anew")

    console.log("DONE")
    Qt.quit()
  })
}
