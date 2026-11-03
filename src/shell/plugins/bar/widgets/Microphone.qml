import QtQuick
import Quickshell
import Quickshell.Services.Pipewire
import qs.Ui

// The default microphone, crossed out while muted and lit while a program
// records from it. A click mutes or unmutes it, a middle click opens the
// audio panel, and the wheel moves its volume 5% a notch.
BarWidget {
  id: widget
  moduleName: "nova.microphone"

  readonly property var source: Pipewire.defaultAudioSource
  readonly property var audio: source ? source.audio : null
  readonly property bool muted: audio ? audio.muted : true
  // Some stream records: a stream that is not a sink and is not muted.
  readonly property bool recorded: Array.prototype.some.call(Pipewire.nodes ? Pipewire.nodes.values : [], function(node) {
    return node && node.isStream && node.isSink === false && !node.audio?.muted
  })
  readonly property bool inUse: recorded && !muted

  visible: source !== null
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  PwObjectTracker { objects: widget.source ? [widget.source] : [] }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: widget.bar
    active: widget.inUse
    text: widget.muted ? "\u{F036D}" : "\u{F036C}"
    tooltipText: widget.muted ? "Microphone muted" : widget.inUse ? "Microphone in use" : "Microphone live"

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.MiddleButton) widget.bar.run("nova-shell shell toggle nova.audio")
      else if (widget.audio) widget.audio.muted = !widget.audio.muted
    }

    onWheelMoved: function(delta) {
      if (widget.audio) widget.audio.volume = Math.max(0, Math.min(1, widget.audio.volume + (delta > 0 ? 0.05 : -0.05)))
    }
  }
}
