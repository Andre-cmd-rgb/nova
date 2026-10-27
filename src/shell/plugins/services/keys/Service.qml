import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Services.Pipewire
import "KeysModel.js" as Model

// The volume and brightness keys, in the shell. Hyprland hands them over as
// global shortcuts (data/hypr/bindings/media.lua), and the shell does the
// rest: the volume over its own PipeWire connection, the backlight with one
// brightnessctl, the OSD in place. Run as commands, a press started ten or a
// dozen processes for some 130 ms of CPU, and a held key asked for forty a
// second. `nova-audio-output-volume` and `nova-brightness-display` do the
// same from a terminal.
Item {
  id: root

  property var shell: null

  function showOsd(icon, percent) {
    if (root.shell) root.shell.summon("nova.osd", JSON.stringify({ icon: icon, value: percent }))
  }

  // A press takes a step now; held, it goes on after Hyprland's repeat delay
  // (data/hypr/input.lua), a step every 50 ms, until it is let go or <step>
  // says there is no further to go.
  function hold(step) {
    held.stop()
    if (!step()) return
    held.step = step
    held.interval = 250
    held.start()
  }

  function release() {
    held.stop()
  }

  Timer {
    id: held
    property var step: null
    repeat: true
    onTriggered: {
      interval = 50
      if (!step()) stop()
    }
  }

  // ------------------------------------------------------------ volume

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []

  // The physical sink under any DSP sink in front of it (a speaker tuning,
  // EasyEffects): where loudness lives, as nova-audio-output-sink resolves it
  // for the audio panel too. The default output until it answers.
  property string volumeSinkName: ""
  readonly property var volumeSink: {
    if (volumeSinkName === "" || !sink) return sink
    if (volumeSinkName === String(sink.name)) return sink
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream && String(n.name) === volumeSinkName && n.audio)
        return n
    }
    return sink
  }

  PwObjectTracker { objects: [root.sink, root.volumeSink].filter(function (n) { return !!n }) }

  onSinkChanged: resolveVolumeSink()

  // A change while a lookup runs asks again once it ends: that lookup may
  // have read the old output.
  property bool volumeSinkStale: false

  function resolveVolumeSink() {
    if (volumeSinkProc.running) volumeSinkStale = true
    else volumeSinkProc.running = true
  }

  Process {
    id: volumeSinkProc
    command: ["nova-audio-output-sink"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.volumeSinkName = String(text).trim()
    }
    onExited: {
      if (!root.volumeSinkStale) return
      root.volumeSinkStale = false
      Qt.callLater(root.resolveVolumeSink)
    }
  }

  // A safety net for a tuning applied or removed under the same default.
  Timer {
    interval: 15000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.resolveVolumeSink()
  }

  // A step unmutes. Held, each step follows the last one set rather than
  // PipeWire's answer to it.
  function pressVolume(delta) {
    var percent = -1
    hold(function () {
      var node = root.volumeSink
      if (!node || !node.audio) return false
      percent = Model.volumeStep(percent < 0 ? node.audio.volume : percent / 100, delta)
      node.audio.muted = false
      node.audio.volume = percent / 100
      root.showOsd(Model.volumeIcon(percent, false), percent)
      return Model.volumeMore(percent, delta)
    })
  }

  // A key that bounces sends two presses: the second, within 250 ms, is not
  // a second toggle.
  property real lastMute: 0

  function toggleMute() {
    var now = Date.now()
    if (now - lastMute < 250) return
    lastMute = now
    var node = root.volumeSink
    if (!node || !node.audio) return
    var muted = !node.audio.muted
    var percent = Math.round(node.audio.volume * 100)
    node.audio.muted = muted
    showOsd(Model.volumeIcon(percent, muted), percent)
  }

  // -------------------------------------------------------- brightness

  // The focused display's: an internal panel's backlight, an external one's
  // over DDC/CI, as nova-brightness-display decides.
  readonly property string focusedMonitor: Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name) : ""
  readonly property bool focusedExternal: focusedMonitor !== "" && !/^(eDP|LVDS|DSI)-/.test(focusedMonitor)

  // The backlight, as nova-hw-display picks it; read here, and set with
  // brightnessctl, which goes through logind: the file is root's.
  property string backlight: ""

  Process {
    id: backlightProc
    command: ["nova-hw-display"]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.backlight = String(text).trim()
    }
  }

  FileView {
    id: backlightValue
    path: root.backlight !== "" ? "/sys/class/backlight/" + root.backlight + "/brightness" : ""
    blockLoading: true
  }

  FileView {
    id: backlightMax
    path: root.backlight !== "" ? "/sys/class/backlight/" + root.backlight + "/max_brightness" : ""
    blockLoading: true
  }

  function backlightNow() {
    backlightValue.reload()
    return Model.backlightPercent(backlightValue.text(), backlightMax.text())
  }

  // One brightnessctl at a time; a step asked for while one runs waits for
  // it, and only the last of them is set.
  property int backlightQueued: -1

  function setBacklight(percent) {
    if (backlightSetProc.running) {
      backlightQueued = percent
      return
    }
    backlightSetProc.command = ["brightnessctl", "-q", "-d", root.backlight, "set", percent + "%"]
    backlightSetProc.running = true
  }

  Process {
    id: backlightSetProc
    onExited: {
      if (root.backlightQueued < 0) return
      var percent = root.backlightQueued
      root.backlightQueued = -1
      root.setBacklight(percent)
    }
  }

  // DDC/CI takes its time: a step asked for while one runs is the one it is
  // already taking, and the OSD shows what the display says it is at.
  Process {
    id: ddcProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var percent = parseInt(String(text).trim(), 10)
        if (!isNaN(percent)) root.showOsd("brightness", percent)
      }
    }
  }

  function stepDdc(key) {
    if (!ddcProc.running) {
      ddcProc.command = ["nova-brightness-display-ddc", root.focusedMonitor, Model.ddcStep(key)]
      ddcProc.running = true
    }
    return key !== "max" && key !== "min"
  }

  function pressBrightness(key) {
    if (root.focusedExternal) {
      hold(function () { return root.stepDdc(key) })
      return
    }
    var percent = -1
    hold(function () {
      if (root.backlight === "") return false
      var from = percent < 0 ? root.backlightNow() : percent
      if (from < 0) return false
      percent = Model.brightnessStep(from, key)
      root.setBacklight(percent)
      root.showOsd("brightness", percent)
      return Model.brightnessMore(percent, key)
    })
  }

  // --------------------------------------------------------- shortcuts

  GlobalShortcut {
    appid: "nova"
    name: "volume-up"
    description: "Volume up"
    onPressed: root.pressVolume(5)
    onReleased: root.release()
  }

  GlobalShortcut {
    appid: "nova"
    name: "volume-down"
    description: "Volume down"
    onPressed: root.pressVolume(-5)
    onReleased: root.release()
  }

  GlobalShortcut {
    appid: "nova"
    name: "volume-up-fine"
    description: "Volume up precise"
    onPressed: root.pressVolume(1)
    onReleased: root.release()
  }

  GlobalShortcut {
    appid: "nova"
    name: "volume-down-fine"
    description: "Volume down precise"
    onPressed: root.pressVolume(-1)
    onReleased: root.release()
  }

  GlobalShortcut {
    appid: "nova"
    name: "volume-mute"
    description: "Mute"
    onPressed: root.toggleMute()
  }

  GlobalShortcut {
    appid: "nova"
    name: "brightness-up"
    description: "Brightness up"
    onPressed: root.pressBrightness("up")
    onReleased: root.release()
  }

  GlobalShortcut {
    appid: "nova"
    name: "brightness-down"
    description: "Brightness down"
    onPressed: root.pressBrightness("down")
    onReleased: root.release()
  }

  GlobalShortcut {
    appid: "nova"
    name: "brightness-up-fine"
    description: "Brightness up precise"
    onPressed: root.pressBrightness("up-fine")
    onReleased: root.release()
  }

  GlobalShortcut {
    appid: "nova"
    name: "brightness-down-fine"
    description: "Brightness down precise"
    onPressed: root.pressBrightness("down-fine")
    onReleased: root.release()
  }

  GlobalShortcut {
    appid: "nova"
    name: "brightness-max"
    description: "Brightness maximum"
    onPressed: root.pressBrightness("max")
  }

  GlobalShortcut {
    appid: "nova"
    name: "brightness-min"
    description: "Brightness minimum"
    onPressed: root.pressBrightness("min")
  }
}
