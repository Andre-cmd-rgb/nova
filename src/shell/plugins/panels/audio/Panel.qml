import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The sound on the bar: the speaker's icon by its volume, the wheel over it
// to change the volume, a right click to mute everything or unmute it. A
// click opens the panel: a switch for all of it, the output's volume and
// the outputs to choose from, the input's with its level and the inputs,
// and each application playing, with its own volume. The pointer and the
// keys share one cursor through it all.
Panel {
  id: root
  moduleName: "nova.audio"
  ipcTarget: "nova.audio"

  // ---------------------------------------------------------------- nodes

  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var source: Pipewire.defaultAudioSource
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
  readonly property var activeMediaPlayer: {
    var media = bar?.shell?.serviceFor("nova.media")
    return media ? media.activePlayer : null
  }

  readonly property var everyOutput: Model.sinks(nodes)
  readonly property var everyInput: Model.sources(nodes)
  readonly property var streams: Model.streams(nodes)

  // The outputs a cable or a card says are there, the default always; the
  // inputs, the default first. A moment with none (PipeWire publishing its
  // nodes anew) shows the last ones there were.
  property var lastOutputs: []
  property var lastInputs: []
  readonly property var outputsNow: Model.withDefault(everyOutput.filter(sinkAvailable), sink)
  readonly property var inputsNow: Model.withDefault(everyInput.slice(), source)
  readonly property var outputs: outputsNow.length > 0 ? outputsNow : lastOutputs
  readonly property var inputs: inputsNow.length > 0 ? inputsNow : lastInputs

  onOutputsNowChanged: if (outputsNow.length > 0) lastOutputs = outputsNow
  onInputsNowChanged: if (inputsNow.length > 0) lastInputs = inputsNow

  function sinkAvailable(node) {
    if (!node || !node.name || !sinkAvailability.loaded) return true
    return sinkAvailability.plugged[String(node.name)] !== false
  }

  PwObjectTracker { objects: root.everyOutput }
  PwObjectTracker { objects: root.everyInput }
  PwObjectTracker { objects: root.streams }

  SinkAvailability {
    id: sinkAvailability
    active: root.opened
  }

  // The rows are made from copies of the lists, taken 75 ms after a change,
  // and none while the panel is shut. PipeWire can take a node away while
  // Quickshell is still announcing it, and a Repeater rebuilt on that
  // announcement has crashed Quickshell's PipeWire service; the wait lets
  // the change settle.
  property var shownOutputs: []
  property var shownInputs: []
  property var shownStreams: []

  function copyLists() {
    if (!opened) return
    shownOutputs = Model.copy(outputs)
    shownInputs = Model.copy(inputs)
    shownStreams = Model.copy(streams)
    clampCursor()
  }

  function copySoon() {
    if (opened) copyTimer.restart()
  }

  onOutputsChanged: copySoon()
  onInputsChanged: copySoon()
  onStreamsChanged: copySoon()

  Timer { id: copyTimer; interval: 75; onTriggered: root.copyLists() }

  // ---------------------------------------------------------------- volume

  // The output's volume lives on the sink the keys' service names: the
  // physical one behind the default output, where that is a speaker tuning
  // or EasyEffects (nova-audio-output-sink resolves it). The volume of such
  // a sink sets the level going into its processing, so a slider on it
  // would move while the speakers did not, and through a limiter change the
  // tone too. The volume keys and the output switcher go by the same sink.
  readonly property var volumeSink: {
    var keys = bar?.shell?.serviceFor("nova.keys")
    return keys ? keys.volumeSink : sink
  }

  readonly property real outputVolume: volumeSink && volumeSink.audio ? volumeSink.audio.volume : 0
  readonly property bool outputMuted: volumeSink && volumeSink.audio ? volumeSink.audio.muted : false
  readonly property real inputVolume: source && source.audio ? source.audio.volume : 0
  readonly property bool inputMuted: source && source.audio ? source.audio.muted : false

  // Only a channel there is counts: a machine with no input would otherwise
  // read as an input unmuted for ever, and the switch could mute but never
  // unmute.
  readonly property bool hasOutput: !!(volumeSink && volumeSink.audio)
  readonly property bool hasInput: !!(source && source.audio)
  readonly property bool anyAudible: (hasOutput && !outputMuted) || (hasInput && !inputMuted)

  // Touchpad scrolling smaller than a notch, carried to the next event.
  property real wheelRest: 0

  function outputIcon(volume) {
    return Model.speakerIcon(sink, outputMuted, volume === undefined ? outputVolume : volume)
  }

  function setOutputVolume(v) {
    if (!volumeSink || !volumeSink.audio) return outputVolume
    var volume = Math.max(0, Math.min(1, v))
    volumeSink.audio.volume = volume
    return volume
  }

  function setInputVolume(v) {
    if (source && source.audio) source.audio.volume = Math.max(0, Math.min(1, v))
  }

  function toggleOutputMute() {
    if (volumeSink && volumeSink.audio) volumeSink.audio.muted = !volumeSink.audio.muted
  }

  function toggleInputMute() {
    if (source && source.audio) source.audio.muted = !source.audio.muted
  }

  // The switch, and the right click on the bar, mute both channels at once
  // or unmute them. Anything still audible reads as on, so muting one
  // channel from its slider does not flip it.
  function toggleAllMuted() {
    var mute = anyAudible
    if (hasOutput) volumeSink.audio.muted = mute
    if (hasInput) source.audio.muted = mute
  }

  function toggleStreamMute(node) {
    if (node && node.audio) node.audio.muted = !node.audio.muted
  }

  function showVolumeOsd(volume) {
    if (!bar || !bar.shell) return
    bar.shell.summon("nova.osd", JSON.stringify({ icon: outputIcon(volume), value: Math.round(volume * 100) }))
  }

  function setDefaultSink(node) {
    if (!node) return
    Pipewire.preferredDefaultAudioSink = node
    if (node.id !== undefined && node.name)
      Quickshell.execDetached(["nova-audio-output-set-default", String(node.id), String(node.name)])
  }

  function setDefaultSource(node) {
    if (!node) return
    Pipewire.preferredDefaultAudioSource = node
    if (node.id !== undefined && node.name)
      Quickshell.execDetached(["nova-audio-input-set-default", String(node.id), String(node.name)])
  }

  PwNodePeakMonitor {
    id: inputPeak
    node: root.source
    enabled: root.opened && !!root.source
  }

  // ---------------------------------------------------------------- cursor

  // Shown once the pointer or a key has moved it. focusSection is "output",
  // "input", "streams" or "header", the switch; selectedIndex -1 is a
  // section's slider, 0 and on its rows.
  property bool cursorActive: false
  property string focusSection: "output"
  property int selectedIndex: -1

  function shape() {
    return {
      sinks: shownOutputs.length,
      sources: shownInputs.length,
      streams: shownStreams.length,
      hasSource: !!source
    }
  }

  // Each row the cursor lights is scrolled into view, so it moves in one
  // step: from one section to another it passes through no row (index -2
  // is none), and the pointer shows it only once it is where it points.
  function go(next) {
    if (next.section !== focusSection) selectedIndex = -2
    focusSection = next.section
    selectedIndex = next.index
  }

  function point(section, index) {
    go(Model.at(section, index))
    cursorActive = true
  }

  function moveCursor(delta) {
    go(Model.move(Model.at(focusSection, selectedIndex), delta, shape()))
  }

  function clampCursor() {
    go(Model.clamp(Model.at(focusSection, selectedIndex), shape()))
  }

  function onStream() {
    return focusSection === "streams" && selectedIndex >= 0 && selectedIndex < shownStreams.length
  }

  // h and l: the slider the cursor is on, the output's or the input's, or
  // the stream's on its row; nothing on a device's row.
  function adjustVolume(delta) {
    if (focusSection === "output" && selectedIndex === -1) {
      setOutputVolume(outputVolume + delta)
    } else if (focusSection === "input" && selectedIndex === -1) {
      setInputVolume(inputVolume + delta)
    } else if (onStream()) {
      var s = shownStreams[selectedIndex]
      if (s && s.audio) s.audio.volume = Math.max(0, Math.min(1.5, s.audio.volume + delta))
    }
  }

  // Return or Space: the switch, a slider's mute, a device made the
  // default, a stream's mute.
  function activateCursor() {
    if (focusSection === "header") {
      toggleAllMuted()
    } else if (focusSection === "output") {
      if (selectedIndex === -1) toggleOutputMute()
      else setDefaultSink(shownOutputs[selectedIndex])
    } else if (focusSection === "input") {
      if (selectedIndex === -1) toggleInputMute()
      else setDefaultSource(shownInputs[selectedIndex])
    } else if (focusSection === "streams" && selectedIndex >= 0) {
      toggleStreamMute(shownStreams[selectedIndex])
    }
  }

  // m: the stream the cursor is on, the input in its section, else the
  // output.
  function muteAtCursor() {
    if (onStream()) toggleStreamMute(shownStreams[selectedIndex])
    else if (focusSection === "input") toggleInputMute()
    else toggleOutputMute()
  }

  function resetScroll() {
    var flick = scrollArea.contentItem
    if (flick && flick.contentY !== undefined) flick.contentY = 0
  }

  // The row the cursor lands on scrolled into view, 6 px clear of the edge.
  // The top of the card stays in view while the cursor is on the output's
  // slider, and a card that scrolls by less than 24 px does not scroll.
  function ensureCursorVisible(item) {
    var flick = scrollArea.contentItem
    if (!item || !flick || flick.contentY === undefined) return
    var maxY = Math.max(0, (flick.contentHeight || 0) - flick.height)
    if (maxY <= Style.space(24) || (focusSection === "output" && selectedIndex === -1)) {
      flick.contentY = 0
      return
    }
    var top = item.mapToItem(flick.contentItem || flick, 0, 0).y
    var bottom = top + (item.height || 0)
    if (top < flick.contentY + 6) flick.contentY = Math.max(0, Math.min(maxY, top - 6))
    else if (bottom > flick.contentY + flick.height - 6) flick.contentY = Math.max(0, Math.min(maxY, bottom + 6 - flick.height))
  }

  // Opened, the lists are read and the cursor (unshown) put on the output's
  // slider; shut, the rows go.
  onOpenedChanged: {
    if (opened) {
      copyLists()
      go(Model.at("output", -1))
      cursorActive = false
      Qt.callLater(resetScroll)
    } else {
      copyTimer.stop()
      shownOutputs = []
      shownInputs = []
      shownStreams = []
    }
  }

  // ---------------------------------------------------------------- bar

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.outputIcon()
    onPressed: function(which) {
      if (which === Qt.RightButton) root.toggleAllMuted()
      else root.toggle()
    }
    onWheelMoved: function(delta) {
      if (!root.hasOutput) return
      var wheel = Util.wheelSteps(root.wheelRest, delta)
      root.wheelRest = wheel.remainder
      if (wheel.steps === 0) return
      root.showVolumeOsd(root.setOutputVolume(root.outputVolume + wheel.steps * 0.05))
    }
  }

  // ---------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(560))

    // j and k walk the switch, the sliders and the rows; h and l move the
    // slider the cursor is on; Return or Space acts; m mutes. The first key
    // only shows the cursor.
    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) root.cursorActive = true
        else if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjustVolume(dx * 0.05)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if ((t === "m" || t === "M") && root.cursorActive) root.muteAtCursor()
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: content.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        // It scrolls only when there is more than fits.
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: content.implicitHeight > scrollArea.height
        }

        Column {
          id: content
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // The icon shows the output; the switch alone mutes, and is the
          // cursor's stop above the output's slider. It reads on while
          // anything can be heard, so muting all reads as audio off.
          PanelHero {
            title: "Audio"
            meta: Model.mood(outputSlider.dragging ? outputSlider.liveValue : root.outputVolume, root.outputMuted)
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            iconOpacity: root.outputMuted ? 0.5 : 1.0
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.outputIcon()
                color: root.bar.foreground
                font { family: root.bar.fontFamily; pixelSize: Style.font.display }
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: powerSwitch
                checked: root.anyAudible
                hasCursor: root.cursorActive && root.focusSection === "header"
                foreground: root.bar.foreground
                onHovered: function(on) { if (on) root.point("header", -1) }
                onToggled: root.toggleAllMuted()

                PanelToolTip {
                  visible: powerSwitch.containsMouse
                  text: root.anyAudible ? "Mute" : "Unmute"
                  fontFamily: root.bar.fontFamily
                }
              }
            }
          }

          PanelSeparator { foreground: root.bar.foreground }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Heading {
              title: "OUTPUT"
              reading: Math.round((outputSlider.dragging ? outputSlider.liveValue : root.outputVolume) * 100) + "%"
              muted: root.outputMuted
            }

            SliderRow {
              section: "output"
              height: outputSlider.implicitHeight + Style.spacing.controlGap

              PanelSlider {
                id: outputSlider
                anchors { fill: parent; leftMargin: Style.space(6); rightMargin: Style.space(6) }
                bar: root.bar
                minimum: 0
                maximum: 1
                step: 0.05
                value: root.outputVolume
                opacity: root.outputMuted ? 0.5 : 1.0
                enabled: !!root.sink
                onMoved: function(v) { root.setOutputVolume(v) }
                onRightClicked: root.toggleOutputMute()
              }
            }

            Repeater {
              model: root.shownOutputs
              DeviceRow { section: "output"; width: content.width }
            }
          }

          PanelSeparator {
            visible: root.shownInputs.length > 0 || !!root.source
            foreground: root.bar.foreground
          }

          Column {
            visible: root.shownInputs.length > 0 || !!root.source
            width: parent.width
            spacing: Style.space(6)

            Heading {
              title: "INPUT"
              reading: Math.round((inputSlider.dragging ? inputSlider.liveValue : root.inputVolume) * 100) + "%"
              muted: root.inputMuted
            }

            // The input's slider, and under it the level coming in.
            SliderRow {
              visible: !!root.source
              section: "input"
              height: inputControls.implicitHeight + Style.spacing.controlGap

              Column {
                id: inputControls
                anchors { fill: parent; leftMargin: Style.space(6); rightMargin: Style.space(6) }
                spacing: Style.space(5)

                PanelSlider {
                  id: inputSlider
                  width: parent.width
                  bar: root.bar
                  minimum: 0
                  maximum: 1
                  step: 0.05
                  value: root.inputVolume
                  opacity: root.inputMuted ? 0.5 : 1.0
                  enabled: !!root.source
                  onMoved: function(v) { root.setInputVolume(v) }
                  onRightClicked: root.toggleInputMute()
                }

                Rectangle {
                  width: parent.width
                  height: Math.max(Style.space(5), Style.spacing.xs)
                  color: Util.alpha(root.bar.foreground, 0.18)
                  opacity: root.inputMuted ? 0.35 : 1.0

                  Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, inputPeak.peak))
                    height: parent.height
                    color: root.bar.foreground
                    Behavior on width { NumberAnimation { duration: 70 } }
                  }
                }
              }
            }

            Repeater {
              model: root.shownInputs
              DeviceRow { section: "input"; width: content.width }
            }
          }

          PanelSeparator {
            visible: root.shownStreams.length > 0
            foreground: root.bar.foreground
          }

          Column {
            visible: root.shownStreams.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "SOURCES"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: root.shownStreams
              StreamRow { width: content.width }
            }
          }
        }
      }
    }
  }

  // A section's name, and its volume at the far end, dimmed while muted.
  component Heading: Item {
    property alias title: label.text
    property alias reading: readout.text
    property bool muted: false

    width: parent.width
    implicitHeight: Math.max(label.implicitHeight, readout.implicitHeight)

    PanelSectionHeader {
      id: label
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
    }

    Text {
      id: readout
      anchors { right: parent.right; rightMargin: Style.space(6); verticalCenter: parent.verticalCenter }
      textFormat: Text.PlainText
      color: Qt.darker(root.bar.foreground, 1.4)
      font { family: root.bar.fontFamily; pixelSize: Style.font.caption; bold: true }
      opacity: parent.muted ? 0.5 : 1.0
    }
  }

  // A section's slider, which the cursor lights as a whole at index -1.
  component SliderRow: CursorSurface {
    id: sliderRow
    property string section

    width: parent.width
    hasCursor: root.cursorActive && root.focusSection === section && root.selectedIndex === -1
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(sliderRow)
    foreground: root.bar.foreground

    HoverHandler {
      onHoveredChanged: if (hovered) root.point(sliderRow.section, -1)
    }
  }

  // An output or an input: its icon and name, bold on the default. A click
  // makes it the default.
  component DeviceRow: CursorSurface {
    id: device
    required property var modelData
    required property int index
    property string section
    readonly property bool output: section === "output"
    readonly property var chosen: output ? root.sink : root.source
    readonly property bool isActive: chosen && modelData && chosen.id === modelData.id

    hasCursor: root.cursorActive && root.focusSection === section && root.selectedIndex === index
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(device)
    current: isActive
    foreground: root.bar.foreground
    implicitHeight: inner.implicitHeight + Style.spacing.xl

    Row {
      id: inner
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.space(6); rightMargin: Style.space(6) }
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: device.output ? Model.sinkIcon(device.modelData) : Model.sourceIcon(device.modelData)
        color: root.bar.foreground
        font { family: root.bar.fontFamily; pixelSize: Style.font.title }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(22) - Style.space(8)
        textFormat: Text.PlainText
        text: Model.deviceName(device.modelData)
        color: root.bar.foreground
        font { family: root.bar.fontFamily; pixelSize: Style.font.body; bold: device.isActive }
        elide: Text.ElideRight
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.point(device.section, device.index)
      onClicked: device.output ? root.setDefaultSink(device.modelData) : root.setDefaultSource(device.modelData)
    }
  }

  // An application playing: its mute, its name (bold on the one the media
  // widget shows) and volume, over a slider of its own, which h and l move
  // too while the cursor is on the row. Up to 150%, as PipeWire allows.
  component StreamRow: CursorSurface {
    id: stream
    required property var modelData
    required property int index
    readonly property real volume: modelData && modelData.audio ? modelData.audio.volume : 0
    readonly property bool muted: modelData && modelData.audio ? modelData.audio.muted : false
    readonly property bool isActive: Model.playsFor(modelData, root.activeMediaPlayer, root.mprisPlayers, root.shownStreams)

    hasCursor: root.cursorActive && root.focusSection === "streams" && root.selectedIndex === index
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(stream)
    current: isActive
    foreground: root.bar.foreground
    implicitHeight: lines.implicitHeight + Style.spacing.xl

    Column {
      id: lines
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.space(6); rightMargin: Style.space(6) }
      spacing: Style.space(2)

      Row {
        width: parent.width
        spacing: Style.space(8)

        Text {
          id: muteIcon
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(22)
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: stream.muted ? "󰝟" : "󰕾"
          color: root.bar.foreground
          font { family: root.bar.fontFamily; pixelSize: Style.font.title }
          opacity: stream.muted ? 0.5 : 1.0

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.toggleStreamMute(stream.modelData)
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - muteIcon.width - percent.width - Style.space(16)
          textFormat: Text.PlainText
          text: Model.streamName(stream.modelData, root.mprisPlayers, root.shownStreams)
          color: root.bar.foreground
          font { family: root.bar.fontFamily; pixelSize: Style.font.body; bold: stream.isActive }
          elide: Text.ElideRight
        }

        Text {
          id: percent
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(36)
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          text: Math.round(stream.volume * 100) + "%"
          color: Qt.darker(root.bar.foreground, 1.5)
          font { family: root.bar.fontFamily; pixelSize: Style.font.caption; bold: true }
          opacity: stream.muted ? 0.5 : 1.0
        }
      }

      PanelSlider {
        width: parent.width
        bar: root.bar
        minimum: 0
        maximum: 1.5
        step: 0.05
        value: stream.volume
        opacity: stream.muted ? 0.5 : 1.0
        onMoved: function(v) {
          if (stream.modelData && stream.modelData.audio) stream.modelData.audio.volume = v
        }
        onRightClicked: root.toggleStreamMute(stream.modelData)
      }
    }

    // Hover only; clicks go through to the slider and the mute.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      propagateComposedEvents: true
      onContainsMouseChanged: if (containsMouse) root.point("streams", stream.index)
    }
  }
}
