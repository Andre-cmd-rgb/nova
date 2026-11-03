import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import qs.Ui

// The default microphone: crossed out while muted, lit while a program
// records from it. A click mutes it, a middle click opens the audio panel,
// the wheel sets its volume in steps of 5%.
BarWidget {
  id: root
  moduleName: "nova.microphone"

  readonly property var source: Pipewire.defaultAudioSource
  readonly property bool muted: source && source.audio ? source.audio.muted : true
  // A recording stream: one that is not a sink, and not muted itself.
  readonly property bool recorded: {
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    for (var i = 0; i < nodes.length; i++) {
      var node = nodes[i]
      if (node && node.isStream && node.isSink === false && !node.audio?.muted) return true
    }
    return false
  }
  readonly property bool inUse: recorded && !muted

  visible: source !== null
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  PwObjectTracker { objects: root.source ? [root.source] : [] }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.muted ? "󰍭" : "󰍬"
    active: root.inUse
    tooltipText: root.muted ? "Microphone muted" : (root.inUse ? "Microphone in use" : "Microphone live")

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) root.bar.run("nova-shell shell toggle nova.audio")
      else if (root.source && root.source.audio) root.source.audio.muted = !root.source.audio.muted
    }

    onWheelMoved: function(delta) {
      if (!root.source || !root.source.audio) return
      var volume = root.source.audio.volume + (delta > 0 ? 0.05 : -0.05)
      root.source.audio.volume = Math.max(0, Math.min(1, volume))
    }
  }
}
