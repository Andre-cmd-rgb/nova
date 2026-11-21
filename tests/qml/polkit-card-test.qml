// platform: wayland
// stub: bin/nova-hw-laptop-closed record
import QtQuick
import Quickshell
import Quickshell.Io

// The polkit agent's card, the real PolkitAgent.qml with a stand-in for the
// agent Quickshell registers on the system bus, which a test cannot reach: no
// card while nothing asks; a request makes it, with what it is for and the
// field; the password goes to PAM as typed and the field is emptied; a wrong
// one keeps the card; a right one, a moment later, takes it away; and the
// next request makes it again, its field empty. The lid check is a stub that
// says the lid is shut, so the card asks for the password, not the finger.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  property Item stage: Item {}
  property var agent: null
  property var polkit: null

  function check(name, got, want) {
    const same = JSON.stringify(got) === JSON.stringify(want)
    console.log((same ? "ok   " : "FAIL ") + name + (same ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  // What PAM's conversation is, as the agent reads it.
  property QtObject flow: QtObject {
    property string message: "Authentication is needed to run `/usr/bin/foo' as the super user"
    property bool isResponseRequired: true
    property bool responseVisible: false
    property string inputPrompt: "Password: "
    property string supplementaryMessage: ""
    property bool failed: false
    property var submitted: []
    signal authenticationFailed()
    signal authenticationSucceeded()
    signal authenticationRequestCancelled()
    function submit(text) { submitted = submitted.concat([text]) }
    function cancelAuthenticationRequest() { authenticationRequestCancelled() }
  }

  FileView {
    id: installed
    path: Quickshell.env("TEST_PLUGINS") + "/polkit/PolkitAgent.qml"
    blockLoading: true
  }

  FileView {
    id: model
    path: Quickshell.env("TEST_PLUGINS") + "/polkit/PolkitModel.js"
    blockLoading: true
  }

  FileView {
    id: modelCopy
    path: test.home + "/polkit/PolkitModel.js"
    printErrors: false
    onSaved: agentCopy.setText(test.standIn(installed.text()))
  }

  FileView {
    id: agentCopy
    path: test.home + "/polkit/PolkitAgent.qml"
    printErrors: false
    onSaved: test.begin()
  }

  // The agent's file with its PolkitAgent, which registers on the system
  // bus, taken out for an object of the same id that the test drives.
  function standIn(text) {
    const at = text.indexOf("\n  PolkitAgent {")
    let depth = 0, end = text.indexOf("{", at)
    for (; end < text.length; end++) {
      if (text[end] === "{") depth++
      else if (text[end] === "}" && --depth === 0) break
    }
    return text.slice(0, at) + "\n  QtObject { id: polkit; objectName: \"polkit\"; property bool isActive: false; property var flow: null }"
      + text.slice(end + 1)
  }

  // The first item under <item> whose text is <text>.
  function shows(item, text) {
    if (!item) return false
    if (item.visible === false) return false
    if (item.text === text) return true
    const below = item.contentItem ? [item.contentItem] : item.children
    for (const child of below) if (shows(child, text)) return true
    return false
  }

  Component.onCompleted: modelCopy.setText(model.text())

  function begin() {
    const made = Qt.createComponent("file://" + home + "/polkit/PolkitAgent.qml")
    if (made.status !== Component.Ready) {
      check("the agent loads", made.errorString(), "")
      return finish()
    }
    agent = made.createObject(stage)
    polkit = Array.from(agent.data).find(item => item.objectName === "polkit")
    check("nothing asks: no card", agent.surface, null)
    ask()
    later(300, asked)
  }

  // A request, as the agent hears one.
  function ask() {
    polkit.flow = flow
    polkit.isActive = true
    agent.start()
  }

  function asked() {
    check("a request: the card is made, and shown", [agent.surface !== null, agent.surface?.visible], [true, true])
    check("saying what the request is for, and asking for the password",
      [shows(agent.surface, "Authorize running '/usr/bin/foo'"), shows(agent.surface, "Enter password")], [true, true])
    agent.surface.field.text = "one two"
    agent.answer()
    check("the password goes to PAM as typed, and the field is emptied", [flow.submitted, agent.surface.field.text, agent.checking],
      [["one two"], "", true])
    flow.authenticationFailed()
    check("a wrong one: the card stays, and says so", [agent.surface !== null, agent.wrong, shows(agent.surface, "Wrong")], [true, true, true])
    flow.authenticationSucceeded()
    polkit.isActive = false
    later(100, () => {
      check("a right one: the card stays a moment", agent.surface !== null, true)
      later(400, gone)
    })
  }

  function gone() {
    check("and then goes", agent.surface, null)
    ask()
    later(300, () => {
      check("the next request makes it again, its field empty", [agent.surface !== null, agent.surface?.field.text], [true, ""])
      finish()
    })
  }

  function later(ms, then) {
    laterTimer.then = then
    laterTimer.interval = ms
    laterTimer.restart()
  }

  Timer {
    id: laterTimer
    property var then: null
    onTriggered: then()
  }
}
