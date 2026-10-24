import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Sound's page in Settings: where sound goes and comes from, and how loud.
// The bar's sound menu stays the quick way in, and the one with each app's
// own volume.
Column {
  id: root
  spacing: Style.space(22)

  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  // The output chosen, which with a speaker tuning on is the tuning itself.
  readonly property var selected: Pipewire.defaultAudioSink
  readonly property var source: Pipewire.defaultAudioSource
  // Speaker tuning puts a filter in front of the speakers and makes it the
  // default; the volume that matters is the speakers' own, behind it, which
  // nova-audio-output-sink names.
  property string outputName: ""
  readonly property var output: {
    var fallback = Pipewire.defaultAudioSink
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (n && n.isSink && !n.isStream && n.audio && String(n.name) === outputName) return n
    }
    return fallback
  }

  // The choices, as plain snapshots: a Repeater or a menu holding PipeWire
  // nodes outlives the ones that go away, and takes Quickshell down with them.
  property var outputs: []
  property var inputs: []
  property string choicesText: ""
  // sink name -> false for an output with nothing plugged in (HDMI, say), and
  // for the speakers a speaker tuning stands in front of: the tuning is listed
  // in their place, as choosing them would leave it out.
  property var plugged: ({})

  PwObjectTracker { objects: [root.output, root.source] }

  Component.onCompleted: { sync(); probe() }
  onNodesChanged: sync()
  onSelectedChanged: sync()
  onSourceChanged: sync()

  function label(n) {
    var p = n && n.ready && n.properties ? n.properties : {}
    var text = String(n.nickname || p["node.nick"] || n.description || p["node.description"] || n.name || "")
    return text.replace(/^sof-soundwire\s+/i, "").replace(/\s+(Output|Input)$/i, "").replace(/\bMicrophones\b/g, "Microphone")
  }

  function sync() {
    var outs = [], ins = []
    for (var i = 0; i < nodes.length; i++) {
      var n = nodes[i]
      if (!n || n.isStream || !n.name) continue
      var name = String(n.name)
      if (n.isSink) {
        // A filter's own input is processing on the way somewhere, not a
        // place sound goes.
        if (name.indexOf("effect_input.") === 0 || (plugged[name] === false && n !== selected)) continue
        outs.push({ value: name, label: label(n), id: n.id })
      } else if (n.audio && name !== "quickshell") {
        ins.push({ value: name, label: label(n), id: n.id })
      }
    }
    var text = JSON.stringify([outs, ins])
    if (text === choicesText) return
    choicesText = text
    outputs = outs
    inputs = ins
  }

  function choose(list, name, command, preferred) {
    var row = list.filter(function (r) { return r.value === name })[0]
    if (!row) return
    for (var i = 0; i < nodes.length; i++)
      if (nodes[i] && String(nodes[i].name) === name) preferred(nodes[i])
    Quickshell.execDetached([command, String(row.id), name])
    outputProbe.restart()
  }

  function probe() {
    if (!sinkProc.running) sinkProc.running = true
    if (!pluggedProc.running) pluggedProc.running = true
  }

  // Which output is behind the default, and what is plugged in, change with
  // a cable or a click in the bar: a light poll keeps the page true.
  Timer {
    interval: 4000
    repeat: true
    running: true
    onTriggered: root.probe()
  }

  Timer {
    id: outputProbe
    interval: 600
    onTriggered: root.probe()
  }

  Process {
    id: sinkProc
    command: ["nova-audio-output-sink"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.outputName = String(text).trim()
    }
  }

  Process {
    id: pluggedProc
    command: ["nova-audio-sink-availability"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = {}
        String(text || "").split("\n").forEach(function (line) {
          var parts = line.trim().split("\t")
          if (parts.length >= 2) next[parts[0]] = parts[1] !== "0"
        })
        root.plugged = next
        root.sync()
      }
    }
  }

  Section {
    title: "OUTPUT"
    Line {
      label: "Play sound through"
      Dropdown {
        width: Style.spacing.dropdownWidth
        showLabel: false
        options: root.outputs
        value: root.selected ? String(root.selected.name) : ""
        onChanged: function (value) {
          root.choose(root.outputs, value, "nova-audio-output-set-default", function (n) { Pipewire.preferredDefaultAudioSink = n })
        }
      }
    }
    Line {
      label: "Volume"
      detail: !root.output || !root.output.audio ? "No output."
        : root.output.audio.muted ? "Muted." : Math.round(outputSlider.liveValue * 100) + "%"
      Row {
        spacing: Style.space(12)
        PanelSlider {
          id: outputSlider
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(220)
          minimum: 0
          maximum: 1
          step: 0.05
          enabled: !!root.output && !!root.output.audio
          opacity: enabled && !root.output.audio.muted ? 1 : 0.5
          value: root.output && root.output.audio ? root.output.audio.volume : 0
          onMoved: function (v) { if (root.output && root.output.audio) root.output.audio.volume = Math.max(0, Math.min(1, v)) }
        }
        Button {
          text: root.output && root.output.audio && root.output.audio.muted ? "Unmute" : "Mute"
          bordered: true
          onClicked: if (root.output && root.output.audio) root.output.audio.muted = !root.output.audio.muted
        }
      }
    }
  }

  Section {
    title: "INPUT"
    Line {
      label: "Record sound from"
      Dropdown {
        width: Style.spacing.dropdownWidth
        showLabel: false
        options: root.inputs
        value: root.source ? String(root.source.name) : ""
        onChanged: function (value) {
          root.choose(root.inputs, value, "nova-audio-input-set-default", function (n) { Pipewire.preferredDefaultAudioSource = n })
        }
      }
    }
    Line {
      label: "Input volume"
      detail: !root.source || !root.source.audio ? "No microphone."
        : root.source.audio.muted ? "Muted: nothing records you." : Math.round(inputSlider.liveValue * 100) + "%"
      Row {
        spacing: Style.space(12)
        PanelSlider {
          id: inputSlider
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(220)
          minimum: 0
          maximum: 1
          step: 0.05
          enabled: !!root.source && !!root.source.audio
          opacity: enabled && !root.source.audio.muted ? 1 : 0.5
          value: root.source && root.source.audio ? root.source.audio.volume : 0
          onMoved: function (v) { if (root.source && root.source.audio) root.source.audio.volume = Math.max(0, Math.min(1, v)) }
        }
        Button {
          text: root.source && root.source.audio && root.source.audio.muted ? "Unmute" : "Mute"
          bordered: true
          onClicked: if (root.source && root.source.audio) root.source.audio.muted = !root.source.audio.muted
        }
      }
    }
  }
}
