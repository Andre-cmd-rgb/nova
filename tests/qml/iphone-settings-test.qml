// stub: bin/systemctl systemctl
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/settings" as Settings

// Settings → Bluetooth → iPhone notifications against the state file the
// service writes: the switch runs `nova-notification-iphone on` and `off`
// and shows what Settings' state says, not what was clicked; the line under
// it says how the iPhone is, counts the pairing window down, and offers Pair
// only with no iPhone paired; the iPhones it serves are handed to the
// devices' list. A service that is not running (systemctl, stubbed, says so)
// says so, whatever a state file left behind says.
ShellRoot {
  id: test

  readonly property string runtime: Quickshell.env("XDG_RUNTIME_DIR")

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  property var commands: []
  Settings.IphoneNotifications {
    id: page
    width: 600
    running: true
    onCommand: function (argv) { test.commands = test.commands.concat([argv.join(" ")]) }
  }

  // What the stubbed systemctl answers to is-active.
  FileView { id: unitFile; path: Quickshell.env("HOME") + "/systemctl-active"; printErrors: false }
  function unitIs(state) { unitFile.setText(state + "\n") }

  // The first item under <item> that passes.
  function find(item, pass) {
    for (var i = 0; i < item.children.length; i++) {
      var child = item.children[i]
      if (pass(child)) return child
      var deeper = find(child, pass)
      if (deeper) return deeper
    }
    return null
  }
  function toggle() { return find(page, c => c.label === "iPhone notifications" && c.clicked !== undefined && c.checked !== undefined) }
  function line() { return find(page, c => c.detail !== undefined && c.control !== undefined) }
  function pair() { return find(page, c => c.text === "Pair") }

  FileView { id: stateFile; path: test.runtime + "/nova/iphone-notifications.json"; printErrors: false; onSaved: test.saved() }
  property var then: null
  function write(json, next) {
    then = next
    stateFile.setText(JSON.stringify(json))
  }
  function saved() {
    const next = then
    then = null
    if (next) next()
  }

  // <next> once <ready> holds, looked at every 50 ms for up to 5 s.
  function when(ready, next, what) {
    waiter.ready = ready
    waiter.next = next
    waiter.what = what
    waiter.tries = 0
    waiter.restart()
  }
  Timer {
    id: waiter
    property var ready: null
    property var next: null
    property string what: ""
    property int tries: 0
    interval: 50
    repeat: true
    onTriggered: {
      if (ready()) {
        stop()
        next()
      } else if (++tries > 100) {
        stop()
        test.check(false, what)
        test.finish()
      }
    }
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  Process {
    running: true
    command: ["mkdir", "-p", test.runtime + "/nova"]
    onExited: {
      test.unitIs("active")
      test.off()
    }
  }

  Process { id: remover; command: ["rm", "-f", test.runtime + "/nova/iphone-notifications.json"] }

  function off() {
    check(page.status === "off" && !line().visible && !toggle().checked, "off: the switch alone")
    toggle().clicked()
    check(commands.join() === "nova-notification-iphone on" && !toggle().checked,
      "the switch runs nova-notification-iphone on, and waits for Settings to say it is on")
    write({ state: "pairing", name: "Nova", pairingUntil: Math.floor(Date.now() / 1000) + 150, phones: [] }, () => {
      page.on = true
      when(() => page.status === "pairing", pairing, "the pairing window is read")
    })
  }

  function pairing() {
    check(toggle().checked && line().visible && line().label === "Pair your iPhone"
      && /^On your iPhone, open Settings → Bluetooth and tap “Nova”\. 2:[23]\d left$/.test(line().detail),
      "pairing: what to do on the iPhone, with the computer's name, and the time left")
    check(!pair().visible, "no Pair button while pairing")
    write({ state: "no-iphone", name: "Nova", phones: [] }, () => when(() => page.status === "no-iphone", none, "no iPhone is read"))
  }

  function none() {
    check(line().label === "No iPhone" && pair().visible, "no iPhone: Pair")
    pair().clicked()
    check(commands[commands.length - 1] === "nova-notification-iphone pair", "Pair opens the window")
    write({ state: "connected", name: "Nova", link: { interval: 30, latency: 0, timeout: 720 },
            phones: [{ address: "AA:BB:CC:DD:EE:01", name: "Test iPhone", connected: true, state: "connected" }] },
      () => when(() => page.status === "connected", connected, "a connected iPhone is read"))
  }

  function connected() {
    check(line().label === "Test iPhone" && line().detail === "Connected" && !pair().visible, "connected: the iPhone by name")
    check(JSON.stringify(page.addresses) === "[\"AA:BB:CC:DD:EE:01\"]", "its address for the devices' list")
    write({ state: "not-shared", name: "Nova", phones: [{ address: "AA:BB:CC:DD:EE:01", name: "Test iPhone" }] },
      () => when(() => page.status === "not-shared", notShared, "an iPhone that does not share is read"))
  }

  function notShared() {
    check(line().detail === "On your iPhone: Settings → Bluetooth → ⓘ → Share System Notifications",
      "not shared: where to allow it on the iPhone")
    write({ state: "no-le", name: "Nova", phones: [] }, () => when(() => page.status === "no-le", noLe, "LE off is read"))
  }

  function noLe() {
    check(line().label === "Needs Bluetooth Low Energy" && line().detail === "", "LE off: it says it needs it")
    page.powered = false
    check(!line().visible, "Bluetooth off: nothing to say under the switch")
    page.powered = true
    // The service stops on an error: its state file goes with it, and
    // systemd says it is not running.
    unitIs("failed")
    remover.running = true
    when(() => page.status === "stopped", stopped, "a service that stopped is noticed")
  }

  function stopped() {
    check(line().visible && line().label === "Not running" && line().detail === "Switch it off and on to start it again"
      && page.addresses.length === 0, "stopped: it says so, and hands no iPhones to the list")
    // systemd starting it again (activating, until it owns its name): it
    // is starting, not stopped.
    unitIs("activating")
    when(() => page.status === "starting", starting, "a service starting is noticed")
  }

  function starting() {
    check(line().label === "Starting…" && page.addresses.length === 0, "activating: Starting…")
    // Started: what it writes is read.
    unitIs("active")
    write({ state: "waiting", name: "Nova", phones: [{ address: "AA:BB:CC:DD:EE:01", name: "Test iPhone", connected: false, state: "waiting" }] },
      () => when(() => page.status === "waiting", back, "the service back is noticed"))
  }

  function back() {
    check(line().label === "Test iPhone" && line().detail === "Not connected", "back: the iPhone, not connected")
    // Settings read the service as not running, and a state file is there
    // (a run that ended without its cleanup): it is not believed.
    unitIs("inactive")
    write({ state: "connected", name: "Nova", phones: [{ address: "AA:BB:CC:DD:EE:01", name: "Test iPhone", connected: true, state: "connected" }] }, () => {
      page.running = false
      when(() => page.status === "stopped", leftBehind, "a state file left behind is not believed")
    })
  }

  function leftBehind() {
    check(line().label === "Not running" && page.addresses.length === 0, "a state file left behind: not running, no iPhones for the list")
    toggle().clicked()
    check(commands[commands.length - 1] === "nova-notification-iphone off", "on, the switch runs off")
    page.on = false
    check(page.addresses.length === 0 && page.status === "off", "off: no iPhones for the list")
    finish()
  }
}
