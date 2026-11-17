// platform: wayland
// stub: bin/nova-hyprland-focus-app record
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/notifications" as Notifications
import "plugins/notifications/NotificationLogic.js" as Notes

// A click on a toast from the history, which has no sender left to ask: an
// app of this computer's is brought forward by its name; an iPhone's (the
// nova-iphone hint, kept in the row) is not, as an app here may have the
// same name. No bus: the service's server has no one to serve.
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

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  FileView { id: calls; path: Quickshell.env("HOME") + "/stub-calls"; printErrors: false }
  function called() {
    calls.reload()
    calls.waitForJob()
    return String(calls.text() || "")
  }

  Timer {
    id: waiter
    property int tries: 0
    interval: 50
    repeat: true
    onTriggered: {
      if (test.called().indexOf("nova-hyprland-focus-app firefox") >= 0 || ++tries > 100) {
        stop()
        test.finish()
      }
    }
  }

  function finish() {
    const said = called()
    check(said.indexOf("nova-hyprland-focus-app firefox") >= 0, "a toast of this computer's app brings it forward")
    check(said.indexOf("WhatsApp") < 0, "an iPhone's brings nothing forward")
    check(service.toasts.count === 0, "both go once clicked")
    console.log("DONE")
    Qt.quit()
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(() => {
    service = maker.createObject(stage, { shell: fakeShell })
    service.replay([
      Notes.historyRow({ id: 1, app: "WhatsApp", summary: "WhatsApp · Anna", body: "Hi", timestamp: 2, iphone: true }),
      Notes.historyRow({ id: 2, app: "firefox", summary: "Firefox", body: "Done", timestamp: 1 })
    ])
    check(service.toasts.count === 2 && service.toasts.get(0).iphone === true && service.toasts.get(1).iphone === false,
      "the replayed rows keep whether they came from an iPhone")
    service.invoke(0)
    service.invoke(0)
    waiter.start()
  })
}
