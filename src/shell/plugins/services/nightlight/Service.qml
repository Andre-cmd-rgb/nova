import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Schedule.js" as Schedule

// The night light, hyprsunset's warmer screen: the bar's switch, and the
// schedule that switches it by itself, from sunset to sunrise or at set
// hours (shell.json's nightlight, which nova nightlight schedule and
// warmth set). nova-toggle-nightlight does the switching, for the bar as
// for the keys, the menu and the schedule: it waits out a hyprsunset still
// starting, and then has this service ask hyprsunset again (refresh).
Item {
  id: nightlight

  // Injected by the shell.
  property var shell: null

  readonly property var settings: shell && shell.shellConfig && shell.shellConfig.nightlight ? shell.shellConfig.nightlight : ({})
  // How warm the night is, in kelvin.
  readonly property int night: Schedule.warmth(settings.temperature)
  // "sunset", "hours" or "off".
  readonly property string schedule: settings.schedule === "sunset" || settings.schedule === "hours" ? settings.schedule : "off"
  readonly property int from: Util.minutesOf(settings.from, 22 * 60)
  readonly property int to: Util.minutesOf(settings.to, 7 * 60)

  // hyprsunset's colour temperature in kelvin, or what a switch is setting
  // it to; null while hyprsunset is not running or cannot say. Under 6000 K
  // the screen counts as warmed, as nova-toggle-nightlight counts it.
  property var kelvin: null
  readonly property bool enabled: kelvin != null && kelvin < 6000

  // The state asked for while a switch runs, "on" or "off": the last one.
  property string waiting: ""

  // The switch by hand, the bar's and Settings'. It shows the night or the
  // day (6500 K) at once, as nova-toggle-nightlight sets them.
  function setNightlight(on) {
    bySchedule = false
    switchTo(on)
  }

  function switchTo(on) {
    kelvin = on ? night : 6500
    var state = on ? "on" : "off"
    if (switching.running) waiting = state
    else switching.start(state)
  }

  function refresh() {
    if (!asking.running) asking.running = true
  }

  // hyprsunset answers with the number among some words; a failed call
  // means no hyprsunset to ask.
  Process {
    id: asking
    command: ["hyprctl", "hyprsunset", "temperature"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var number = String(text == null ? "" : text).match(/\d+/)
        nightlight.kelvin = number ? Number(number[0]) : null
        // Not as the last turn left it: switched by the keys or the menu,
        // whose nova-toggle-nightlight asks for this look when it is done.
        if (nightlight.kelvin != null && nightlight.made !== "" && nightlight.enabled !== nightlight.made.startsWith("on "))
          nightlight.bySchedule = false
      }
    }
    onExited: code => {
      if (code !== 0) nightlight.kelvin = null
    }
  }

  // When a switch ends: the one asked for meanwhile, or else a look at what
  // hyprsunset now says.
  Process {
    id: switching

    function start(state) {
      command = ["nova-toggle-nightlight", state]
      running = true
    }

    onExited: {
      var next = nightlight.waiting
      nightlight.waiting = ""
      if (next) start(next)
      else nightlight.refresh()
    }
  }

  // ------------------------------------------------------------ schedule

  // Where the sun is reckoned for, { latitude, longitude, name }, from
  // nova-nightlight-place: the weather's place, else the time zone's. Null
  // while it is not known, or there is none (UTC).
  property var place: null

  // The schedule's last turn at <now>: { on, since }; null with no
  // schedule, or no sun to go by.
  function turnAt(now) {
    if (schedule === "hours") return Util.lastTurn(now, from, to)
    if (schedule === "sunset" && place) return Schedule.lastTurn(now, place.latitude, place.longitude)
    return null
  }

  // Sunrise and sunset on the day of <now> where the place is, for
  // Settings: { rise, set }, or null.
  function sun(now) {
    return place ? Schedule.sun(now, place.latitude, place.longitude) : null
  }

  // Each turn is made once, and a switch by hand lasts until the next, as
  // on a Mac. The last one made (Util.turnName) is kept in the runtime
  // directory: a shell started again does not make it again, and a new
  // session, whose night light starts off, does.
  property string made: ""
  // Whether the night light is as the last turn left it, with no switch by
  // hand since: the schedule switched off ends a night it turned on.
  property bool bySchedule: false

  FileView {
    id: madeFile

    property bool read: false

    path: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/nightlight-turn"
    printErrors: false
    onLoaded: readOnce(text())
    onLoadFailed: readOnce("")

    function readOnce(content) {
      if (read) return
      nightlight.made = /^(on|off) \d{4}-\d\d-\d\d$/.test(String(content).trim()) ? String(content).trim() : ""
      nightlight.bySchedule = nightlight.made !== ""
      read = true
      // Not while the load is still ending: a write started in its
      // handler leaves the load dropped.
      Qt.callLater(nightlight.follow)
    }
  }

  function follow() {
    aim()
    if (!madeFile.read) return
    var turn = turnAt(Date.now())
    if (!turn || Util.turnName(turn) === made) return
    made = Util.turnName(turn)
    madeFile.setText(made + "\n")
    bySchedule = true
    switchTo(turn.on)
  }

  // The schedule's next turn (ms), which a timer waits for: 0 with none,
  // as with no schedule, or no sun to go by.
  property real nextTurn: 0

  function turnAfter(now) {
    if (schedule === "hours") return Util.nextTurn(now, from, to)
    if (schedule === "sunset" && place) return Schedule.nextTurn(now, place.latitude, place.longitude)
    return null
  }

  function aim() {
    var now = Date.now()
    var next = turnAfter(now)
    nextTurn = next === null ? 0 : next
    if (next === null) turnTimer.stop()
    else {
      turnTimer.interval = Util.intervalTo(next, now)
      turnTimer.restart()
    }
  }

  Timer {
    id: turnTimer
    onTriggered: nightlight.follow()
  }

  // Switched off, the schedule ends a night it turned on, and leaves one
  // turned on by hand; and it forgets its last turn, so that it makes it
  // again when it is switched back on.
  function stop() {
    if (!madeFile.read || made === "") return
    if (bySchedule && made.startsWith("on ")) switchTo(false)
    made = ""
    bySchedule = false
    madeFile.setText("")
  }

  // The place, looked up again whenever it may have moved: as the schedule
  // turns to the sun, after a sleep, in a new time zone, and as Settings
  // shows it.
  function locate() {
    if (schedule !== "sunset") return
    if (placing.running) placing.again = true
    else placing.running = true
  }

  Process {
    id: placing
    property bool again: false
    command: ["nova-nightlight-place"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var found = null
        try {
          found = JSON.parse(String(text))
        } catch (e) {
          // No place: UTC, or no zone tables.
        }
        var known = !!found && typeof found.latitude === "number" && typeof found.longitude === "number"
        if (!known) found = null
        if (JSON.stringify(found) !== JSON.stringify(nightlight.place)) nightlight.place = found
      }
    }
    onExited: {
      if (!again) return
      again = false
      running = true
    }
  }

  // A turn later, once the schedule and its hours are all the new ones: a
  // change from off to set hours would otherwise see the hours from before.
  onScheduleChanged: {
    if (schedule === "off") stop()
    locate()
    Qt.callLater(follow)
  }
  onFromChanged: Qt.callLater(follow)
  onToChanged: Qt.callLater(follow)
  onPlaceChanged: follow()

  // The timer waits for the next turn on the monotonic clock, which stands
  // still through a sleep and does not follow a clock set or a new time
  // zone: those are heard of (Wake), and the schedule is followed and the
  // timer aimed again then, the place looked up again after a sleep or in a
  // new zone.
  Connections {
    target: Wake
    function onWoke() {
      nightlight.locate()
      nightlight.follow()
    }
  }

  Component.onCompleted: {
    refresh()
    locate()
  }

  IpcHandler {
    target: "nightlight"

    function refresh(): void {
      nightlight.refresh()
    }
  }
}
