// platform: wayland
// stub: bin/nova-hw-laptop-closed record
// warns: failed to create subject for listener
// warns: failed to register listener
import QtQuick
import Quickshell
import "plugins/polkit" as Polkit

// Nothing is asked behind the lock: a request that starts while the screen
// is locked is cancelled at once and shows no card, and the one asked when
// the lock comes up is cancelled then, its card gone. Locked is anything but
// the lock service saying the session is open: before it has answered (a
// shell started again under a lock it may have left), and with no lock
// service at all. Polkit's request is a stand-in that counts its cancels,
// and whether one is under way (`asking`) is set as polkit would; no bus, so
// polkit's own agent does not register.
ShellRoot {
  id: test

  property QtObject lock: QtObject { property bool sessionOpen: false }
  property bool hasLock: true
  property QtObject fakeShell: QtObject {
    function serviceFor(id) { return id === "nova.lock" && test.hasLock ? test.lock : null }
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
      property var selectedIdentity: null
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

  // A request as polkit starts one: its flow, under way, announced.
  function request() {
    const flow = flowMaker.createObject(stage)
    agent.flow = flow
    agent.asking = true
    agent.requestStarted()
    return flow
  }

  // The request over, as polkit ends one.
  function over() {
    agent.asking = false
    agent.flow = null
  }

  property var asked: null

  function first() {
    // The shell started again: the lock service is there and has not said
    // the session is open.
    const early = request()
    check(early.cancels === 1 && early.submitted.length === 0 && !agent.shown,
      "a request before the lock service says the session is open is cancelled at once, and no card shows")
    over()
    // Polkit's flow before its announcement: cancelled as the flow comes.
    const flowFirst = flowMaker.createObject(stage)
    agent.flow = flowFirst
    check(flowFirst.cancels === 1, "a flow that comes behind the lock is cancelled as it comes")
    agent.asking = true
    agent.requestStarted()
    check(flowFirst.cancels === 1, "and once only, when its request is announced after")
    over()

    lock.sessionOpen = true
    asked = request()
    later(300, second)
  }

  function second() {
    check(asked.cancels === 0 && agent.shown && agent.surface !== null, "one that starts while the session is open is asked: its card shows")
    lock.sessionOpen = false
    check(asked.cancels === 1 && !agent.shown, "and cancelled when the lock comes up, the card no longer shown")
    later(300, third)
  }

  function third() {
    check(agent.surface === null, "the card's window is gone")
    lock.sessionOpen = true
    check(asked.cancels === 1, "the unlock asks nothing again: the program asks anew")
    over()
    // Locked, with polkit still saying a request is under way: no card.
    lock.sessionOpen = false
    agent.asking = true
    later(300, fourth)
  }

  function fourth() {
    check(!agent.shown && agent.surface === null, "while locked no card shows, whatever polkit says")
    agent.asking = false
    agent.destroy()
    // No lock service at all: locked too.
    hasLock = false
    lock.sessionOpen = true
    agent = maker.createObject(stage, { shell: fakeShell })
    const none = request()
    check(none.cancels === 1 && !agent.shown, "with no lock service, a request is cancelled and no card shows")
    over()
    console.log("DONE")
    Qt.quit()
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(() => {
    agent = maker.createObject(stage, { shell: fakeShell })
    first()
  })
}
