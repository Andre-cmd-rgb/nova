import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The sound on the bar: the speaker's icon, by its volume. The wheel over it
// sets the volume, and a right click mutes everything or unmutes it. A
// click opens the panel: a switch for all of it, the output's volume and
// the outputs to choose from, the input's with the level coming in and the
// inputs, and each application playing, at a volume of its own. The keys
// and the pointer move one cursor through it all.
Panel {
  id: sound
  moduleName: "nova.audio"
  ipcTarget: "nova.audio"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color ink: bar.foreground
  readonly property string typeface: bar.fontFamily

  // ---- PipeWire -----------------------------------------------------------

  readonly property var defaultSink: Pipewire.defaultAudioSink
  readonly property var defaultSource: Pipewire.defaultAudioSource
  readonly property var nodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var players: Mpris.players ? Mpris.players.values : []

  // One of the shell's services, or null without it.
  function service(id) {
    var shell = bar ? bar.shell : null
    return shell ? shell.serviceFor(id) : null
  }

  // The player the media widget shows: its stream is the one in bold.
  readonly property var mediaPlayer: {
    var media = service("nova.media")
    return media ? media.activePlayer : null
  }

  // The output's volume is the volume of the sink the keys' service names:
  // the physical one behind the default output, when that is a speaker
  // tuning or EasyEffects (nova-audio-output-sink finds it). The volume of
  // such a filter is the level going into it, so a slider on it would move
  // while the speakers stayed as they were, and through a limiter would
  // change the tone too. The volume keys and the output switcher go by the
  // same sink.
  readonly property var volumeSink: {
    var keys = service("nova.keys")
    return keys ? keys.volumeSink : defaultSink
  }

  Channel {
    id: speaker
    node: sound.volumeSink
  }

  Channel {
    id: mic
    node: sound.defaultSource
  }

  // Anything still audible reads as on, so that muting one channel from its
  // slider does not flip the switch.
  readonly property bool audible: (speaker.present && !speaker.muted) || (mic.present && !mic.muted)
  readonly property string speakerGlyph: Model.speakerIcon(defaultSink, speaker.muted, speaker.volume)
  // The output's and the input's volume as their sliders show it: where the
  // knob is while it is dragged.
  readonly property real outputLevel: speakerSlider.dragging ? speakerSlider.liveValue : speaker.volume
  readonly property real inputLevel: micSlider.dragging ? micSlider.liveValue : mic.volume

  // The switch, and a right click on the bar, mute both channels at once or
  // unmute them.
  function toggleAll() {
    var mute = audible
    speaker.setMuted(mute)
    mic.setMuted(mute)
  }

  function flipMute(node) {
    if (node && node.audio) node.audio.muted = !node.audio.muted
  }

  // The output's channel or the input's, by the cursor's section name.
  function channelOf(section) {
    return section === "output" ? speaker : section === "input" ? mic : null
  }

  // A device made the default output, or input, for PipeWire now and for
  // the session's next start.
  function makeDefault(node, output) {
    if (!node) return
    if (output) Pipewire.preferredDefaultAudioSink = node
    else Pipewire.preferredDefaultAudioSource = node
    if (node.id !== undefined && node.name)
      Quickshell.execDetached([output ? "nova-audio-output-set-default" : "nova-audio-input-set-default", String(node.id), String(node.name)])
  }

  function announce(volume) {
    var shell = bar ? bar.shell : null
    if (shell) shell.summon("nova.osd", JSON.stringify({ icon: Model.speakerIcon(defaultSink, speaker.muted, volume), value: Math.round(volume * 100) }))
  }

  // Touchpad scrolling of less than a notch, kept for the next event.
  property real wheelLeft: 0

  function wheeled(delta) {
    if (!speaker.present) return
    var turn = Util.wheelSteps(wheelLeft, delta)
    wheelLeft = turn.remainder
    if (turn.steps !== 0) announce(speaker.setVolume(speaker.volume + turn.steps * 0.05))
  }

  PwNodePeakMonitor {
    id: micPeak
    node: sound.defaultSource
    enabled: sound.opened && !!sound.defaultSource
  }

  // A sink or a source, as the panel moves its volume and its mute. Read
  // straight from the node: <present> may not have caught up with it yet.
  component Channel: QtObject {
    property var node: null
    readonly property bool present: !!(node && node.audio)
    readonly property real volume: node && node.audio ? node.audio.volume : 0
    readonly property bool muted: node && node.audio ? node.audio.muted : false

    // The volume set, kept to 0..1; the volume as it was without a node.
    function setVolume(level) {
      if (!node || !node.audio) return volume
      var kept = Math.max(0, Math.min(1, level))
      node.audio.volume = kept
      return kept
    }

    function setMuted(on) {
      if (node && node.audio) node.audio.muted = on
    }

    function toggleMute() {
      sound.flipMute(node)
    }
  }

  // ---- the lists ----------------------------------------------------------

  readonly property var outputsAll: Model.sinks(nodes)
  readonly property var inputsAll: Model.sources(nodes)
  readonly property var streamsAll: Model.streams(nodes)

  PwObjectTracker { objects: sound.outputsAll }
  PwObjectTracker { objects: sound.inputsAll }
  PwObjectTracker { objects: sound.streamsAll }

  // Which outputs a cable or a card says are there, read while the panel is
  // open.
  SinkAvailability {
    id: plugs
    active: sound.opened
  }

  // Any output counts until that is known.
  function plugged(node) {
    if (!node || !node.name || !plugs.loaded) return true
    return plugs.plugged[String(node.name)] !== false
  }

  // The outputs there are and the inputs, the default always, first when
  // it is not among them.
  Held {
    id: outputsHeld
    now: Model.withDefault(sound.outputsAll.filter(sound.plugged), sound.defaultSink)
  }

  Held {
    id: inputsHeld
    now: Model.withDefault(sound.inputsAll.slice(), sound.defaultSource)
  }

  // A list that keeps the last it had through a moment with none, as
  // PipeWire publishes its nodes anew.
  component Held: QtObject {
    property var now: []
    property var last: []
    readonly property var list: now.length > 0 ? now : last

    onNowChanged: if (now.length > 0) last = now
    onListChanged: sound.listsMoved()
  }

  // The rows are made from copies of the lists, taken 75 ms after they
  // change and only while the panel is open. PipeWire can take a node away
  // while Quickshell is still announcing it, and a Repeater rebuilt on that
  // announcement has crashed Quickshell's PipeWire service: the wait lets
  // the change settle.
  property var rows: ({ outputs: [], inputs: [], streams: [] })
  readonly property bool hasInputs: rows.inputs.length > 0 || !!defaultSource

  function listsMoved() {
    if (opened) settle.restart()
  }

  onStreamsAllChanged: listsMoved()

  Timer {
    id: settle
    interval: 75
    onTriggered: sound.takeRows()
  }

  function takeRows() {
    if (!opened) return
    rows = { outputs: Model.copy(outputsHeld.list), inputs: Model.copy(inputsHeld.list), streams: Model.copy(streamsAll) }
    cursor.keepIn()
  }

  // Opened, the lists are read and the cursor, not shown yet, put on the
  // output's slider; shut, the rows go.
  onOpenedChanged: {
    if (opened) {
      takeRows()
      cursor.place = Model.at("output", -1)
      cursor.shown = false
      Qt.callLater(scroller.toTop)
    } else {
      settle.stop()
      rows = { outputs: [], inputs: [], streams: [] }
    }
  }

  // ---- the cursor ---------------------------------------------------------

  Cursor {
    id: cursor
  }

  // Shown once a key or the pointer has moved it. Its place is a section,
  // "output", "input" or "streams", or "header" for the switch, and a row
  // in it: -1 is the output's or the input's slider, 0 on their devices.
  component Cursor: QtObject {
    property bool shown: false
    property var place: Model.at("output", -1)

    function shape() {
      return {
        sinks: sound.rows.outputs.length,
        sources: sound.rows.inputs.length,
        streams: sound.rows.streams.length,
        hasSource: !!sound.defaultSource
      }
    }

    function on(section, index) {
      return shown && place.section === section && place.index === index
    }

    // Moved, then shown: each row the cursor lights is scrolled into view,
    // and only the one it lands on should be.
    function point(section, index) {
      place = Model.at(section, index)
      shown = true
    }

    function keepIn() {
      place = Model.clamp(place, shape())
    }

    // The stream the cursor is on, or null.
    function stream() {
      return place.section === "streams" ? sound.rows.streams[place.index] || null : null
    }

    // The first key only shows the cursor. Then j and k walk the switch, the
    // sliders and the rows, and h and l move the slider the cursor is on: a
    // channel's, or the stream's on its row.
    function nudge(dx, dy) {
      if (!shown) {
        shown = true
      } else if (dy !== 0) {
        place = Model.move(place, dy, shape())
      } else if (dx !== 0) {
        var channel = place.index === -1 ? sound.channelOf(place.section) : null
        var s = stream()
        if (channel) channel.setVolume(channel.volume + dx * 0.05)
        else if (s && s.audio) s.audio.volume = Math.max(0, Math.min(1.5, s.audio.volume + dx * 0.05))
      }
    }

    // Return or Space: the switch, a channel's mute on its slider, a device
    // made the default, a stream's mute.
    function press() {
      var channel = sound.channelOf(place.section)
      if (place.section === "header") sound.toggleAll()
      else if (channel && place.index === -1) channel.toggleMute()
      else if (channel) sound.makeDefault(sound.rows[place.section === "output" ? "outputs" : "inputs"][place.index], place.section === "output")
      else if (place.index >= 0) sound.flipMute(stream())
    }

    // m: the stream the cursor is on, the input in its section, else the
    // output.
    function muteHere() {
      var s = stream()
      if (s) sound.flipMute(s)
      else if (place.section === "input") mic.toggleMute()
      else speaker.toggleMute()
    }
  }

  // ---- the bar ------------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: sound.bar
    text: sound.speakerGlyph
    onPressed: function(which) {
      if (which === Qt.RightButton) sound.toggleAll()
      else sound.toggle()
    }
    onWheelMoved: function(delta) { sound.wheeled(delta) }
  }

  // ---- the panel ----------------------------------------------------------

  KeyboardPanel {
    id: card
    anchorItem: button
    owner: sound
    bar: sound.bar
    open: sound.opened
    focusTarget: keys
    contentWidth: card.fittedContentWidth(Style.space(380))
    contentHeight: card.fittedContentHeight(content.implicitHeight, Style.space(560))

    // j and k walk, h and l move a slider, Return or Space acts, m mutes.
    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { cursor.nudge(dx, dy) }
      onActivateRequested: if (cursor.shown) cursor.press()
      onCloseRequested: sound.close()
      onTabRequested: function(direction) { sound.switchPanel(direction) }
      onTextKey: function(t) {
        if (t.toLowerCase() === "m" && cursor.shown) cursor.muteHere()
      }

      ScrollView {
        id: scroller
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: content.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        // It scrolls only when there is more than fits.
        Binding {
          target: scroller.contentItem
          property: "interactive"
          value: content.implicitHeight > scroller.height
        }

        function toTop() {
          var view = contentItem
          if (view && view.contentY !== undefined) view.contentY = 0
        }

        // <item> scrolled into view, 6 px clear of the edge. The top of the
        // card stays in view while the cursor is on the output's slider, and
        // a card that would scroll by less than 24 px does not.
        function reveal(item) {
          var view = contentItem
          if (!item || !view || view.contentY === undefined) return
          var room = Math.max(0, (view.contentHeight || 0) - view.height)
          if (room <= Style.space(24) || (cursor.place.section === "output" && cursor.place.index === -1)) {
            view.contentY = 0
            return
          }
          var top = item.mapToItem(view.contentItem || view, 0, 0).y
          var bottom = top + (item.height || 0)
          if (top < view.contentY + 6) view.contentY = Math.max(0, Math.min(room, top - 6))
          else if (bottom > view.contentY + view.height - 6) view.contentY = Math.max(0, Math.min(room, bottom + 6 - view.height))
        }

        Column {
          id: content
          width: scroller.availableWidth
          spacing: Style.space(14)

          // The icon is the output's; the switch alone mutes, and is the
          // cursor's stop above the output's slider. It reads on while
          // anything can be heard, so muting all of it reads as off.
          PanelHero {
            title: "Audio"
            meta: Model.mood(sound.outputLevel, speaker.muted)
            foreground: sound.ink
            fontFamily: sound.typeface
            iconOpacity: speaker.muted ? 0.5 : 1.0
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: sound.speakerGlyph
                color: sound.ink
                font { family: sound.typeface; pixelSize: Style.font.display }
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: muteSwitch
                checked: sound.audible
                hasCursor: cursor.shown && cursor.place.section === "header"
                foreground: sound.ink
                onHovered: function(on) { if (on) cursor.point("header", -1) }
                onToggled: sound.toggleAll()

                PanelToolTip {
                  visible: muteSwitch.containsMouse
                  text: sound.audible ? "Mute" : "Unmute"
                  fontFamily: sound.typeface
                }
              }
            }
          }

          Rule {}

          Column {
            width: parent.width
            spacing: Style.space(6)

            Heading {
              title: "OUTPUT"
              level: sound.outputLevel
              muted: speaker.muted
            }

            ChannelRow {
              section: "output"
              height: speakerSlider.implicitHeight + Style.spacing.controlGap

              VolumeSlider {
                id: speakerSlider
                anchors { fill: parent; leftMargin: Style.space(6); rightMargin: Style.space(6) }
                value: speaker.volume
                opacity: speaker.muted ? 0.5 : 1.0
                enabled: !!sound.defaultSink
                onMoved: function(v) { speaker.setVolume(v) }
                onRightClicked: speaker.toggleMute()
              }
            }

            Repeater {
              model: sound.rows.outputs
              DeviceChoice { section: "output"; width: content.width }
            }
          }

          Rule { visible: sound.hasInputs }

          Column {
            visible: sound.hasInputs
            width: parent.width
            spacing: Style.space(6)

            Heading {
              title: "INPUT"
              level: sound.inputLevel
              muted: mic.muted
            }

            // The input's slider, and under it the level coming in.
            ChannelRow {
              visible: !!sound.defaultSource
              section: "input"
              height: micControls.implicitHeight + Style.spacing.controlGap

              Column {
                id: micControls
                anchors { fill: parent; leftMargin: Style.space(6); rightMargin: Style.space(6) }
                spacing: Style.space(5)

                VolumeSlider {
                  id: micSlider
                  width: micControls.width
                  value: mic.volume
                  opacity: mic.muted ? 0.5 : 1.0
                  enabled: !!sound.defaultSource
                  onMoved: function(v) { mic.setVolume(v) }
                  onRightClicked: mic.toggleMute()
                }

                Rectangle {
                  width: micControls.width
                  height: Math.max(Style.space(5), Style.spacing.xs)
                  color: Util.alpha(sound.ink, 0.18)
                  opacity: mic.muted ? 0.35 : 1.0

                  Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, micPeak.peak))
                    height: parent.height
                    color: sound.ink
                    Behavior on width { NumberAnimation { duration: 70 } }
                  }
                }
              }
            }

            Repeater {
              model: sound.rows.inputs
              DeviceChoice { section: "input"; width: content.width }
            }
          }

          Rule { visible: sound.rows.streams.length > 0 }

          Column {
            visible: sound.rows.streams.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "SOURCES"
              foreground: sound.ink
              fontFamily: sound.typeface
            }

            Repeater {
              model: sound.rows.streams
              AppRow { width: content.width }
            }
          }
        }
      }
    }
  }

  component Rule: PanelSeparator {
    foreground: sound.ink
  }

  component VolumeSlider: PanelSlider {
    bar: sound.bar
    minimum: 0
    maximum: 1
    step: 0.05
  }

  // A section's name, and its volume at the far end, dimmed while muted.
  component Heading: Item {
    id: heading
    property alias title: label.text
    property real level: 0
    property bool muted: false

    width: parent.width
    implicitHeight: Math.max(label.implicitHeight, readout.implicitHeight)

    PanelSectionHeader {
      id: label
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      foreground: sound.ink
      fontFamily: sound.typeface
    }

    Text {
      id: readout
      anchors { right: parent.right; rightMargin: Style.space(6); verticalCenter: parent.verticalCenter }
      textFormat: Text.PlainText
      text: Math.round(heading.level * 100) + "%"
      color: Qt.darker(sound.ink, 1.4)
      font { family: sound.typeface; pixelSize: Style.font.caption; bold: true }
      opacity: heading.muted ? 0.5 : 1.0
    }
  }

  // A stop of the cursor: lit while the cursor is on it, and scrolled into
  // view as the cursor lands there.
  component Spot: CursorSurface {
    id: spot
    property string section: ""
    property int index: -1

    hasCursor: cursor.on(section, index)
    onHasCursorChanged: if (hasCursor) scroller.reveal(spot)
    foreground: sound.ink
  }

  // A channel's slider, lit as a whole by the cursor at row -1.
  component ChannelRow: Spot {
    id: channelRow
    width: parent.width

    HoverHandler {
      onHoveredChanged: if (hovered) cursor.point(channelRow.section, -1)
    }
  }

  // An output or an input: its icon and name, in bold on the default. A
  // click makes it the default.
  component DeviceChoice: Spot {
    id: device
    required property var modelData
    required index
    readonly property bool output: section === "output"
    readonly property var chosen: output ? sound.defaultSink : sound.defaultSource
    readonly property bool isDefault: chosen && modelData && chosen.id === modelData.id

    current: isDefault
    implicitHeight: deviceLine.implicitHeight + Style.spacing.xl

    Row {
      id: deviceLine
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.space(6); rightMargin: Style.space(6) }
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: device.output ? Model.sinkIcon(device.modelData) : Model.sourceIcon(device.modelData)
        color: sound.ink
        font { family: sound.typeface; pixelSize: Style.font.title }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: deviceLine.width - Style.space(22) - Style.space(8)
        textFormat: Text.PlainText
        text: Model.deviceName(device.modelData)
        color: sound.ink
        font { family: sound.typeface; pixelSize: Style.font.body; bold: device.isDefault }
        elide: Text.ElideRight
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) cursor.point(device.section, device.index)
      onClicked: sound.makeDefault(device.modelData, device.output)
    }
  }

  // An application playing: its mute, its name (in bold on the player the
  // media widget shows) and its volume, over a slider of its own, which h
  // and l move too while the cursor is on the row. Up to 150%, as PipeWire
  // allows.
  component AppRow: Spot {
    id: stream
    required property var modelData
    required index
    readonly property real volume: modelData && modelData.audio ? modelData.audio.volume : 0
    readonly property bool muted: modelData && modelData.audio ? modelData.audio.muted : false
    readonly property bool playing: Model.playsFor(modelData, sound.mediaPlayer, sound.players, sound.rows.streams)

    section: "streams"
    current: playing
    implicitHeight: streamLines.implicitHeight + Style.spacing.xl

    Column {
      id: streamLines
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.space(6); rightMargin: Style.space(6) }
      spacing: Style.space(2)

      Row {
        width: streamLines.width
        spacing: Style.space(8)

        Text {
          id: muteMark
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(22)
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: stream.muted ? "󰝟" : "󰕾"
          color: sound.ink
          font { family: sound.typeface; pixelSize: Style.font.title }
          opacity: stream.muted ? 0.5 : 1.0

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: sound.flipMute(stream.modelData)
          }
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: streamLines.width - muteMark.width - percent.width - Style.space(16)
          textFormat: Text.PlainText
          text: Model.streamName(stream.modelData, sound.players, sound.rows.streams)
          color: sound.ink
          font { family: sound.typeface; pixelSize: Style.font.body; bold: stream.playing }
          elide: Text.ElideRight
        }

        Text {
          id: percent
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(36)
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          text: Math.round(stream.volume * 100) + "%"
          color: Qt.darker(sound.ink, 1.5)
          font { family: sound.typeface; pixelSize: Style.font.caption; bold: true }
          opacity: stream.muted ? 0.5 : 1.0
        }
      }

      VolumeSlider {
        width: streamLines.width
        maximum: 1.5
        value: stream.volume
        opacity: stream.muted ? 0.5 : 1.0
        onMoved: function(v) {
          if (stream.modelData && stream.modelData.audio) stream.modelData.audio.volume = v
        }
        onRightClicked: sound.flipMute(stream.modelData)
      }
    }

    // The pointer over the row moves the cursor; its clicks go through to
    // the slider and the mute.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      propagateComposedEvents: true
      onContainsMouseChanged: if (containsMouse) cursor.point("streams", stream.index)
    }
  }
}
