// platform: wayland
// stub: bin/nova-hyprland-focus-app record
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/notifications" as Notifications

// What the notifications keep, through their real files (files.sh): a toast
// gone is replayed from the history, and one on screen comes back when the
// shell restarts. Each notification is handed to the service as its server
// would, a stand-in with the same properties; the restart is the service made
// anew over the same folders. No bus.
ShellRoot {
  id: test

  property QtObject fakeShell: QtObject {
    property var shellConfig: ({})
    function serviceFor(id) { return null }
  }
  property var service: null
  property Item stage: Item {}

  Component {
    id: maker
    Notifications.Service {}
  }

  Component {
    id: noteMaker
    QtObject {
      property int id: 0
      property bool tracked: false
      property string appName: "Mail"
      property string appIcon: ""
      property string summary: "Head"
      property string body: ""
      property string image: ""
      property int urgency: 1
      property real expireTimeout: -1
      property var hints: ({})
      property var actions: []
      signal closed(int reason)
      function expire() { closed(1) }
      function dismiss() { closed(2) }
    }
  }

  property int nextId: 1
  function arrive(summary) {
    const note = noteMaker.createObject(stage, { id: nextId++, summary: summary })
    service.arrive(note)
    return note
  }

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  function shown() {
    var all = []
    for (var i = 0; i < service.toasts.count; i++) all.push(service.toasts.get(i).summary)
    return JSON.stringify(all)
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

  // The shell restarted: the service gone, and a new one over its files.
  function restart(next) {
    service.destroy()
    later(200, () => {
      service = maker.createObject(stage, { shell: fakeShell })
      later(600, next)
    })
  }

  function first() {
    arrive("Gone")
    arrive("Kept")
    later(300, second)
  }

  function second() {
    check(shown() === JSON.stringify(["Kept", "Gone"]), "two toasts with no bar show")
    // "Gone" to the history; "Kept" stays on screen.
    service.dismiss(1)
    later(300, () => restart(third))
  }

  function third() {
    check(shown() === JSON.stringify(["Kept"]), "a toast with no bar on screen comes back after a restart")
    service.showHistory()
    later(400, fourth)
  }

  function fourth() {
    check(shown() === JSON.stringify(["Kept", "Gone"]), "and the history replays the toasts gone, and those on screen")
    service.dismissAll()
    console.log("DONE")
    Qt.quit()
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(() => {
    service = maker.createObject(stage, { shell: fakeShell })
    later(300, first)
  })
}
