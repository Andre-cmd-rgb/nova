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

  readonly property var mic: Pipewire.defaultAudioSource
  // Its audio, once PipeWire has bound it (the tracker below).
  readonly property var audio: mic?.audio ?? null
  readonly property bool muted: !audio || audio.muted
  readonly property bool heard: !muted && recording()

  // Whether a program records: a stream that is no sink and is not muted.
  function recording() {
    const nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    return Array.prototype.some.call(nodes, node => !!node && node.isStream && node.isSink === false && !node.audio?.muted)
  }

  // The volume moved by <step>, within 0 and 1.
  function nudge(step) {
    if (audio) audio.volume = Math.max(0, Math.min(1, audio.volume + step))
  }

  visible: mic !== null
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  PwObjectTracker { objects: widget.mic ? [widget.mic] : [] }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: widget.bar
    active: widget.heard
    text: widget.muted ? "\u{F036D}" : "\u{F036C}"
    tooltipText: widget.muted ? "Microphone muted" : widget.heard ? "Microphone in use" : "Microphone live"

    onPressed: mouseButton => {
      if (mouseButton === Qt.MiddleButton) widget.bar.run("nova-shell shell toggle nova.audio")
      else if (widget.audio) widget.audio.muted = !widget.muted
    }
    onWheelMoved: delta => widget.nudge(delta > 0 ? 0.05 : -0.05)
  }
}
