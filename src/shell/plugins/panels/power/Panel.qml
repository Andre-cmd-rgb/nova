import QtQuick
import Quickshell.Io
import Quickshell.Services.UPower
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The battery on the bar: its charge as an icon, and the percentage beside it
// once a right click (or `nova-shell nova.power togglePercentage`) asks for
// it. A click opens the panel: the charge, a bar of it, the figures
// nova-battery-info gives, and the power modes nova-power-profile offers,
// picked with the pointer or the keys. With no battery there is no widget.
Panel {
  id: power
  moduleName: "nova.power"
  ipcTarget: "nova.power"

  visible: present
  implicitWidth: present ? button.implicitWidth : 0
  implicitHeight: present ? button.implicitHeight : 0

  // ------------------------------------------------------------ the battery

  readonly property var device: UPower.displayDevice
  readonly property bool present: !!(device && device.isPresent)
  readonly property bool unplugged: present && UPower.onBattery
  readonly property real level: Model.level(device)
  // UPower's state in the rules' words.
  readonly property string upowerState: {
    switch (device?.state) {
    case UPowerDeviceState.Charging: return "charging"
    case UPowerDeviceState.FullyCharged: return "full"
    case UPowerDeviceState.PendingCharge: return "pending"
    }
    return ""
  }
  readonly property string flow: Model.flow(device, unplugged, upowerState)
  readonly property string glyph: Model.icon(flow, level)

  readonly property bool percentShown: setting("showPercentage") === true
  readonly property bool numbered: percentShown && !vertical
  // The percentage widens the button past an icon's slot, so the open-panel
  // mark takes the width painted rather than a share of the slot.
  readonly property real openPanelIndicatorWidth: numbered ? button.glyphPaintedWidth : 0

  function togglePercentage() {
    const entry = Object.assign({}, settings, { showPercentage: !percentShown })
    settings = entry
    bar?.shell?.updateEntryInline(moduleName, entry)
  }

  // ------------------------------------------------- the figures and modes

  // What nova-battery-info printed last, by field; the modes, and the one
  // in use.
  property var facts: ({})
  property var modes: []
  property string liveMode: ""
  readonly property var figures: Model.figures(facts, flow, unplugged)
  // The mode the keys are on, shown once a key or the pointer moves it.
  property int cursor: 0
  property bool cursorShown: false

  // Without a battery there is nothing to open. Each opening reads both
  // again and puts the cursor, hidden, on the mode in use.
  function open() {
    if (opened || !present) return
    refresh()
    cursor = Math.max(0, modes.indexOf(liveMode))
    cursorShown = false
    controller.show()
  }

  function refresh() {
    if (!present) return
    battery.ask()
    profiles.ask()
  }

  // An answer that comes back empty, as one can around plugging in, keeps
  // what is shown, so the panel does not fold up for a moment.
  function takeFacts(text) {
    const read = Model.fields(text)
    if (Object.keys(read).length > 0) facts = read
  }

  // Until it is shown, the cursor waits on the mode in use.
  function takeModes(text) {
    const read = Model.modes(text)
    if (read.names.length === 0) return
    modes = read.names
    liveMode = read.active
    const live = modes.indexOf(liveMode)
    cursor = opened && !cursorShown && live >= 0 ? live : Model.within(cursor, modes.length)
  }

  // The first move only shows the cursor; the next ones step it, either way.
  function nudge(dx, dy) {
    if (!cursorShown) cursorShown = true
    else cursor = Model.within(cursor + (dx || dy), modes.length)
  }

  function pointAt(index) {
    cursorShown = true
    cursor = index
  }

  function useMode(name) {
    if (name && !switcher.running) switcher.exec(["nova-power-profile", "set", name])
  }

  onPresentChanged: if (!present) close()

  // The battery service puts back the mode kept for the new power source;
  // it is read a moment after the plug comes or goes, once it has landed.
  onUnpluggedChanged: if (opened) settle.restart()

  Timer { id: settle; interval: 600; onTriggered: power.refresh() }
  Timer { interval: 5000; running: power.opened; repeat: true; onTriggered: power.refresh() }

  Reader {
    id: battery
    command: ["nova-battery-info", "--shell"]
    onAnswered: text => power.takeFacts(text)
  }

  Reader {
    id: profiles
    command: ["nova-power-profile", "list", "--active-state"]
    onAnswered: text => power.takeModes(text)
  }

  Process {
    id: switcher
    onExited: power.refresh()
  }

  // ---------------------------------------------------------------- the bar

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: power.bar
    text: power.numbered ? Math.round(power.level * 100) + "% " + power.glyph : power.glyph
    slotSize: Style.bar.iconSlot * (power.numbered ? 2 : 1)
    onPressed: which => {
      if (which === Qt.RightButton) power.togglePercentage()
      else power.toggle()
    }
  }

  // -------------------------------------------------------------- the panel

  KeyboardPanel {
    id: popup
    anchorItem: button
    owner: power
    bar: power.bar
    open: power.opened
    focusTarget: keys
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(sheet.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onMoveRequested: (dx, dy) => power.nudge(dx, dy)
      onActivateRequested: if (power.cursorShown) power.useMode(power.modes[power.cursor])
      onCloseRequested: power.close()
      onTabRequested: direction => power.switchPanel(direction)

      Column {
        id: sheet
        anchors { left: parent.left; right: parent.right; top: parent.top }
        spacing: Style.space(14)

        // The icon, "Battery" over the line that says what it does, and
        // the percentage.
        Item {
          width: parent.width
          implicitHeight: Math.max(bigGlyph.implicitHeight, heading.implicitHeight, percent.implicitHeight)

          Big {
            id: bigGlyph
            anchors.left: parent.left
            text: power.glyph
            font.pixelSize: Style.font.display
          }

          Column {
            id: heading
            anchors {
              left: bigGlyph.right; leftMargin: Style.space(14)
              right: percent.left; rightMargin: Style.space(10)
              verticalCenter: parent.verticalCenter
            }
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "Battery"
              color: power.bar.foreground
              font { family: power.bar.fontFamily; pixelSize: Style.font.title; bold: true }
              elide: Text.ElideRight
            }

            Saying { width: parent.width }
          }

          Big {
            id: percent
            anchors.right: parent.right
            text: power.facts.percentage || "—"
            font { pixelSize: Style.font.displayLarge; bold: true }
          }
        }

        // The charge, which breathes while it charges.
        Rectangle {
          id: track
          width: parent.width
          height: Style.space(8)
          radius: height / 2
          color: Util.alpha(power.bar.foreground, 0.12)

          Rectangle {
            anchors { top: parent.top; bottom: parent.bottom }
            width: Math.max(track.height, track.width * power.level)
            radius: height / 2
            color: power.bar ? power.bar.foreground : Commons.Color.foreground

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 220 } }

            SequentialAnimation on opacity {
              running: power.flow === "charging" && power.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }
        }

        // The figures, once any have been read. They stay through the moment
        // UPower calls a battery above its limit's start full on plugging in.
        Grid {
          visible: power.facts.percentage !== undefined
          width: parent.width
          columns: 2
          columnSpacing: Style.space(20)
          rowSpacing: Style.spacing.labelGap

          Figure { pair: power.figures[0] }
          Figure { pair: power.figures[1] }
          Figure { pair: power.figures[2] }
          Figure { pair: power.figures[3] }
        }

        // The power modes, when power-profiles-daemon offers any.
        PanelSeparator {
          visible: power.modes.length > 0
          foreground: power.bar.foreground
        }

        Column {
          visible: power.modes.length > 0
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "POWER PROFILE"
            foreground: power.bar.foreground
            fontFamily: power.bar.fontFamily
          }

          Row {
            id: choices
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: power.modes

              Button {
                required property string modelData
                required property int index

                width: (choices.width - choices.spacing * (power.modes.length - 1)) / power.modes.length
                iconText: Model.modeIcon(modelData)
                iconSize: Style.font.title
                text: modelData.charAt(0).toUpperCase() + modelData.slice(1)
                fontSize: Style.font.bodySmall
                foreground: power.bar.foreground
                fontFamily: power.bar.fontFamily
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: modelData === power.liveMode
                hasCursor: power.cursorShown && index === power.cursor
                onClicked: power.useMode(modelData)
                onHovered: on => { if (on) power.pointAt(index) }
              }
            }
          }
        }
      }
    }
  }

  // A command whose whole output is its answer. Asked again while it runs,
  // it answers once.
  component Reader: Process {
    id: reader
    signal answered(string text)
    function ask() { if (!running) running = true }
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: reader.answered(text) }
  }

  // The hero's large text, the icon and the percentage, in the bar's colour,
  // which it follows in a fade.
  component Big: Text {
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    color: power.bar.foreground
    font.family: power.bar.fontFamily
    Behavior on color { ColorAnimation { duration: 200 } }
  }

  // The line under "Battery". While the current flows its phrase turns every
  // 2.8 s the panel is open, fading out and back in.
  component Saying: Text {
    id: saying
    property int turn: 0
    readonly property bool turning: Model.phrases(power.flow).length > 0

    textFormat: Text.PlainText
    text: Model.line(power.flow, turn).toUpperCase()
    color: Qt.darker(power.bar.foreground, 1.4)
    font { family: power.bar.fontFamily; pixelSize: Style.font.caption; bold: true; letterSpacing: 1.2 }
    elide: Text.ElideRight

    // Out of turning halfway through a fade, the line shows whole at once:
    // "Fully charged" is not left dimmed.
    onTurningChanged: {
      if (turning) return
      swap.stop()
      opacity = 1
    }

    Timer { interval: 2800; running: power.opened && saying.turning; repeat: true; onTriggered: swap.restart() }

    SequentialAnimation {
      id: swap
      PropertyAnimation { target: saying; property: "opacity"; to: 0.0; duration: 180; easing.type: Easing.OutQuad }
      ScriptAction { script: saying.turn += 1 }
      PropertyAnimation { target: saying; property: "opacity"; to: 1.0; duration: 260; easing.type: Easing.InQuad }
    }
  }

  // A figure under the charge bar, a column wide: its name, dimmed, at the
  // left and its value at the right, or after the name where it is too long.
  component Figure: Item {
    property var pair: ["", ""]
    readonly property real gap: Style.space(8)

    width: (parent.width - Style.space(20)) / 2
    implicitHeight: Math.max(name.implicitHeight, amount.implicitHeight)

    Text {
      id: name
      textFormat: Text.PlainText
      text: parent.pair[0]
      color: power.bar.foreground
      opacity: 0.6
      font { family: power.bar.fontFamily; pixelSize: Style.font.bodySmall }
    }

    Text {
      id: amount
      x: parent.width - name.implicitWidth - implicitWidth > 2 * parent.gap ? parent.width - implicitWidth : name.implicitWidth + parent.gap
      textFormat: Text.PlainText
      text: parent.pair[1]
      color: power.bar.foreground
      font { family: power.bar.fontFamily; pixelSize: Style.font.bodySmall }
    }
  }
}
