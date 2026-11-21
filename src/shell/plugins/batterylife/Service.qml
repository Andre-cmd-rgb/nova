import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons

// The part that keeps the record. It asks the CLI for a sample on a cadence,
// and again whenever the power source changes, so the boundary between one
// discharge run and the next is written down at the moment it happens rather
// than up to a minute late.
//
// Deliberately thin: nothing is aggregated here. A shell restart costs one
// sample, and every question about the data is answered by the CLI instead;
// its last answer is kept for the bar on every screen and for Settings, which
// would otherwise each ask it the same question. That answer walks the whole
// history, so it is asked after a sample only while something shows it: the
// bar's widget and the Settings page hold() the service while they are
// there, and release() it as they go. The widget is not on the bar unless
// put there, and the page is made only while it is shown, so most of the
// time the samples are written and nothing reads them. The power profiles
// the bar's panel offers are read here too, once for every screen, and
// likewise only while the service is held.
Item {
  id: root

  // Injected by nova-shell.
  property var shell: null
  property var manifest: null

  // A test gives a stub in its place.
  property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/batterylife")).replace(/^file:\/\//, ""))

  // Settings live in the CLI's config file — one place to change them, and no
  // second copy in shell.json that could disagree with it.
  property int batteryInterval: 60
  property int acInterval: 300

  readonly property bool onBattery: UPower.onBattery
  readonly property int interval: (onBattery ? batteryInterval : acInterval) * 1000

  signal sampled()

  // The CLI's `json`, as the bar and Settings show it.
  property var info: ({})
  property real readAt: 0

  // How many of the widget and the page show the record now. The first to
  // come reads it, and the power profiles, at once.
  property int holds: 0

  function hold() {
    if (holds++ > 0) return
    refresh(5000)
    loadProfiles()
  }

  function release() {
    if (holds > 0) holds--
  }

  // A read walks the whole history, and a sample, a percent and a charge
  // state tend to move at once, with every screen's widget asking: they share
  // one read. A <maxAge> in ms is a read only if the last is older.
  function refresh(maxAge) {
    if (maxAge !== undefined && Date.now() - readAt < maxAge) return
    if (!readSettle.running) readSettle.start()
  }

  Timer {
    id: readSettle
    interval: 200
    onTriggered: root.read()
  }

  // Asked while a read runs, it reads again once that one ends: the first may
  // have missed what moved.
  property bool readStale: false

  function read() {
    if (readProc.running) readStale = true
    else readProc.running = true
  }

  Process {
    id: readProc
    command: [root.helper, "json", "--days", "7", "--sessions", "12"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text))
          if (parsed && typeof parsed === "object") {
            root.info = parsed
            root.readAt = Date.now()
          }
        } catch (e) {
          // A truncated read is not worth blanking the widgets over.
        }
      }
    }
    onExited: {
      if (!root.readStale) return
      root.readStale = false
      root.read()
    }
  }

  function sample() {
    // A sample still in flight is a sample: asking twice writes two rows a
    // few milliseconds apart, which is noise in every average downstream.
    if (sampleProc.running) return
    sampleProc.running = true
  }

  Component.onCompleted: sample()

  Process {
    id: sampleProc
    command: [root.helper, "sample"]
    onExited: {
      root.sampled()
      if (root.holds > 0) root.refresh()
    }
  }

  // ---- settings

  // The CLI's config file, KEY=value a line, the last of a key counting, as
  // bin/batterylife's get_cfg reads it; a whole number of seconds, ten at
  // least, or the default. Read as it changes (nova battery set, or by
  // hand), with no process and no clock; its folder is made first, for the
  // file to be seen when it is made.
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config"
  readonly property string configFolder: configHome + "/nova-batterylife"
  property bool configWatched: false

  function setting(text, key, otherwise) {
    var value = ""
    var pattern = new RegExp("^\\s*" + key + "\\s*=\\s*(.*)$")
    String(text || "").split("\n").forEach(function (line) {
      var found = pattern.exec(line.replace(/\r/g, ""))
      if (found) value = found[1]
    })
    var number = parseInt(value, 10)
    return isFinite(number) && number >= 10 ? number : otherwise
  }

  function takeSettings(text) {
    batteryInterval = setting(text, "SAMPLE_INTERVAL", 60)
    acInterval = setting(text, "AC_INTERVAL", 300)
  }

  Process {
    running: true
    command: ["mkdir", "-p", root.configFolder]
    onExited: root.configWatched = true
  }

  WatchedFile {
    id: configFile
    path: root.configWatched ? root.configFolder + "/config" : ""
    onLoaded: root.takeSettings(text())
    onLoadFailed: root.takeSettings("")
  }

  // Plugging in or pulling the plug ends one run and starts another. Both
  // sides want a reading: the one that closes the run, and the one that opens
  // the next at a known charge.
  Connections {
    target: UPower
    function onOnBatteryChanged() {
      root.sample()
      root.loadProfiles()
    }
  }

  // The power profiles, as `nova-power-profile list` names them, and the one
  // in force, for the bar's panel: read while the service is held, at the
  // first hold, when the power source changes (plugged in there are none: it
  // is always full power), when every screen's widget sees the charge state
  // change, and after a profile is set.
  property var profiles: []
  property string activeProfile: ""
  // A choice clicked while the one before is still being set, set after it:
  // the last one clicked is the one kept.
  property string profileWanted: ""
  property bool profilesAskedAgain: false

  function setProfile(name) {
    // nova-power-profile keeps it until the next plug-in.
    profileWanted = String(name)
    if (!profileProc.running) setWantedProfile()
  }

  function setWantedProfile() {
    profileProc.command = ["nova-power-profile", "set", profileWanted]
    profileWanted = ""
    profileProc.running = true
  }

  // Asked by every screen's widget in the same turn, it reads once; asked
  // while a read runs, it reads again after: the one running may have
  // started before the change it is asked for.
  function loadProfiles() {
    Qt.callLater(root.readProfiles)
  }

  function readProfiles() {
    if (holds === 0) return
    if (profilesProc.running) profilesAskedAgain = true
    else profilesProc.running = true
  }

  Process {
    id: profilesProc
    command: ["nova-power-profile", "list", "--active-state"]
    onExited: {
      if (!root.profilesAskedAgain) return
      root.profilesAskedAgain = false
      running = true
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var names = []
        var active = ""
        var lines = String(text).split("\n")
        for (var i = 0; i < lines.length; i++) {
          var parts = lines[i].split("\t")
          if (!parts[0]) continue
          names.push(parts[0])
          if (parts[1] === "1") active = parts[0]
        }
        root.profiles = names
        root.activeProfile = active
      }
    }
  }

  Process {
    id: profileProc
    onExited: {
      if (root.profileWanted !== "") root.setWantedProfile()
      else root.loadProfiles()
    }
  }

  Timer {
    interval: root.interval
    running: true
    repeat: true
    onTriggered: root.sample()
  }

  // A resume is the one moment a sample is worth more than usual: the charge
  // reading either side of a suspend is the only evidence of what it cost,
  // and the timer above cannot have fired while the machine was down.
  // nova-sessiond hears of the wake from logind and tells the shell (Wake).
  Connections {
    target: Wake
    function onWoke() { root.sample() }
  }
}
