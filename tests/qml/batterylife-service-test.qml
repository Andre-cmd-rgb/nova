// stub: bin/batterylife record
// stub: bin/nova-power-profile nova-power-profile
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/batterylife" as BatteryLife

// Battery Life's service, against a stub of its CLI that notes each call: a
// sample as it starts, and the record read after a sample only while
// something holds the service (the bar's widget, the Settings page), at
// once as the first comes, with the power profiles; and the sampling
// intervals from the CLI's config file, read as it is made, written and
// removed, with no process.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  readonly property string config: home + "/.config/nova-batterylife/config"
  readonly property string read: "batterylife json --days 7 --sessions 12"
  property var service: null
  property Item stage: Item {}

  function check(name, got, want) {
    const same = JSON.stringify(got) === JSON.stringify(want)
    console.log((same ? "ok   " : "FAIL ") + name + (same ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  FileView { id: callsFile; path: test.home + "/stub-calls"; blockLoading: true; printErrors: false }
  FileView { id: configFile; path: test.config; printErrors: false; onSaved: test.saved() }

  // The calls of the CLI, or of <command>.
  function calls(command) {
    callsFile.reload()
    const of = (command || "batterylife") + " "
    return String(callsFile.text()).trim().split("\n").filter(line => line.startsWith(of))
  }

  property var then: null
  function write(text, next) {
    then = next
    configFile.setText(text)
  }
  function saved() {
    const next = then
    then = null
    if (next) next()
  }

  // Waits for <done> to hold, then calls <next>; fails <what> after 5 s.
  function when(done, next, what) {
    waiter.done = done
    waiter.next = next
    waiter.what = what
    waiter.left = 100
    waiter.start()
  }
  Timer {
    id: waiter
    property var done: null
    property var next: null
    property string what: ""
    property int left: 0
    interval: 50
    repeat: true
    onTriggered: {
      if (done()) {
        stop()
        next()
      } else if (--left <= 0) {
        stop()
        test.check(what, false, true)
        test.finish()
      }
    }
  }

  // <next> after <ms>, for what must not come.
  function later(ms, next) {
    pause.next = next
    pause.interval = ms
    pause.restart()
  }
  Timer {
    id: pause
    property var next: null
    onTriggered: next()
  }

  Component {
    id: made
    BatteryLife.Service {}
  }

  Component.onCompleted: Qt.callLater(() => {
    service = made.createObject(stage, { helper: "batterylife" })
    when(() => calls().length > 0 && service.configWatched, unheld, "a sample as it starts")
  })

  function unheld() {
    later(800, () => {
      check("a sample as it starts, and with nothing showing it, no read", calls(), ["batterylife sample"])
      check("nor of the power profiles", calls("nova-power-profile"), [])
      service.hold()
      when(() => calls().length === 2, held, "the first to hold it reads at once")
    })
  }

  function held() {
    check("the first to hold it reads at once", calls()[1], read)
    service.hold()
    service.sample()
    when(() => calls().length === 4, () => {
      check("held, a sample is read", calls().slice(2), ["batterylife sample", read])
      service.release()
      check("released once of twice, still held", service.holds, 1)
      service.release()
      service.release()
      check("released by both, and once too often, held by none", service.holds, 0)
      service.sample()
      when(() => calls().length === 5, () => later(800, () => {
        check("held by none, a sample is not read", calls().slice(4), ["batterylife sample"])
        check("the power profiles read once, at the first hold", calls("nova-power-profile"), ["nova-power-profile list --active-state"])
        settings()
      }), "the sample")
    }, "the sample and its read")
  }

  function settings() {
    check("no config file: the defaults", [service.batteryInterval, service.acInterval], [60, 300])
    write("# by hand\n  SAMPLE_INTERVAL = 90\r\nAC_INTERVAL=5\nSAMPLE_INTERVAL=120 \n", () => {
      when(() => service.batteryInterval !== 60, () => {
        check("the file made: the last of a key, and the default for one under ten seconds", [service.batteryInterval, service.acInterval], [120, 300])
        write("AC_INTERVAL=600\n", () => {
          when(() => service.acInterval === 600, () => {
            check("written again: read again, a key gone back to its default", [service.batteryInterval, service.acInterval], [60, 600])
            removeConfig.running = true
          }, "the file written again is read")
        })
      }, "the file made is read")
    })
  }

  Process {
    id: removeConfig
    command: ["rm", "-f", test.config]
    onExited: test.when(() => test.service.acInterval === 300, () => {
      test.check("removed: the defaults", [test.service.batteryInterval, test.service.acInterval], [60, 300])
      test.check("and not one process for the settings", test.calls().filter(line => line.indexOf("config") >= 0), [])
      test.finish()
    }, "the file removed is read")
  }
}
