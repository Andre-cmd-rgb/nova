import QtQuick
import Quickshell
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
  id: root
  moduleName: "nova.power"
  ipcTarget: "nova.power"

  // ---------------------------------------------------------------- battery

  readonly property var device: UPower.displayDevice
  readonly property bool present: !!(device && device.isPresent)
  readonly property var stateValues: ({
    Charging: UPowerDeviceState.Charging,
    Discharging: UPowerDeviceState.Discharging,
    FullyCharged: UPowerDeviceState.FullyCharged,
    PendingCharge: UPowerDeviceState.PendingCharge
  })
  readonly property real level: Model.level(device)
  readonly property bool unplugged: present && UPower.onBattery
  readonly property bool holding: Model.holding(device, unplugged, stateValues)
  readonly property bool full: present && device.state === UPowerDeviceState.FullyCharged && !holding
  // Nothing flows: full by UPower's word or by its number, or held.
  readonly property bool topped: full || (!unplugged && level >= 1)
  readonly property bool resting: topped || holding
  readonly property bool charging: present && !UPower.onBattery && !resting
  readonly property string icon: Model.icon(device, unplugged, stateValues)

  // What nova-battery-info printed last, and the power modes.
  property var figures: ({})
  property var modes: []
  property string activeMode: ""

  readonly property bool showPercentage: setting("showPercentage", false) === true
  // The percentage widens the button past an icon's slot, so the open-panel
  // mark takes the width painted rather than a share of the slot.
  readonly property real openPanelIndicatorWidth: showPercentage && !button.vertical ? button.glyphPaintedWidth : 0

  // The mode the keys are on, shown once a key or the pointer has moved it.
  property int modeAt: 0
  property bool cursorActive: false

  function refresh() {
    if (!present) return
    if (!batteryProc.running) batteryProc.running = true
    if (!modesProc.running) modesProc.running = true
  }

  // An answer that comes back empty, as one can around plugging in, keeps
  // what is shown, so the panel does not fold up for a moment.
  function takeFigures(text) {
    var read = Model.fields(text)
    if (Object.keys(read).length > 0) figures = read
  }

  function takeModes(text) {
    var read = Model.modes(text)
    if (read.names.length === 0) return
    modes = read.names
    activeMode = read.active
    modeAt = Model.within(modeAt || 0, modes.length)
    if (opened && !cursorActive && modes.indexOf(activeMode) >= 0) modeAt = modes.indexOf(activeMode)
  }

  function setMode(name) {
    if (!name || modeProc.running) return
    modeProc.command = ["nova-power-profile", "set", name]
    modeProc.running = true
  }

  function stepMode(delta) {
    modeAt = Model.within(modeAt + delta, modes.length)
  }

  function togglePercentage() {
    root.settings = Object.assign({}, root.settings, { showPercentage: !root.showPercentage })
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, root.settings)
  }

  visible: present
  implicitWidth: present ? button.implicitWidth : 0
  implicitHeight: present ? button.implicitHeight : 0

  onOpenedChanged: {
    if (!opened) return
    // With no battery the card stays shut (it opens only with one), and the
    // panel is closed again once this change is through: closing within it
    // would change `opened` while it changes.
    if (!present) {
      Qt.callLater(close)
      return
    }
    refresh()
    modeAt = Math.max(0, modes.indexOf(activeMode))
    cursorActive = false
  }

  onPresentChanged: if (!present) close()

  // The battery service puts back the mode kept for the new power source;
  // it is read a moment after the plug comes or goes, once it has landed.
  Connections {
    target: UPower
    function onOnBatteryChanged() { if (root.opened) modesLater.restart() }
  }

  Timer { id: modesLater; interval: 600; onTriggered: root.refresh() }
  Timer { interval: 5000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  Process {
    id: batteryProc
    command: ["nova-battery-info", "--shell"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.takeFigures(text) }
  }

  Process {
    id: modesProc
    command: ["nova-power-profile", "list", "--active-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.takeModes(text) }
  }

  Process {
    id: modeProc
    onExited: root.refresh()
  }

  // ---------------------------------------------------------------- phrases

  // A word for the current turns every few seconds while the panel is open:
  // one set while it charges, another on the battery, none when full or
  // held. Each change fades the line out and in.
  readonly property var phrases: full ? [] : charging ? chargingPhrases : unplugged ? batteryPhrases : []
  readonly property var chargingPhrases: ["Pumping power", "Injecting electrons", "Pouring juice", "Amassing watts",
    "Hoarding joules", "Sucking volts", "Topping reserves", "Soaking amps", "Inhaling kilowatts"]
  readonly property var batteryPhrases: ["Slurping power", "Spending joules", "Draining watts", "Burning electrons",
    "Sipping juice", "Spending coulombs", "Bleeding amps", "Guzzling volts", "Munching reserves"]
  readonly property bool turning: phrases.length > 0
  property int phraseAt: 0
  readonly property string status: {
    if (full) return "Fully charged"
    if (turning) return phrases[phraseAt % phrases.length]
    return Model.mode(device, unplugged, stateValues)
  }

  // Out of a turning state halfway through a fade, the line is shown whole
  // at once: "Fully charged" is not left dimmed.
  onTurningChanged: {
    if (turning) return
    fade.stop()
    statusLine.opacity = 1.0
  }

  Timer {
    interval: 2800
    running: root.opened && root.turning
    repeat: true
    onTriggered: fade.restart()
  }

  SequentialAnimation {
    id: fade
    PropertyAnimation { target: statusLine; property: "opacity"; to: 0.0; duration: 180; easing.type: Easing.OutQuad }
    ScriptAction {
      script: {
        if (root.phrases.length > 0) root.phraseAt = (root.phraseAt + 1) % root.phrases.length
      }
    }
    PropertyAnimation { target: statusLine; property: "opacity"; to: 1.0; duration: 260; easing.type: Easing.InQuad }
  }

  // ---------------------------------------------------------------- bar

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    readonly property bool withNumber: root.showPercentage && !vertical
    text: withNumber ? Math.round(root.level * 100) + "% " + root.icon : root.icon
    slotSize: Style.bar.iconSlot * (withNumber ? 2 : 1)
    tooltipText: ""
    onPressed: function(which) {
      if (!root.present) return
      if (which === Qt.RightButton) root.togglePercentage()
      else root.toggle()
    }
  }

  // ---------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened && root.present
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    // The arrows and h, j, k, l step through the modes, either way; the
    // first key only shows where the cursor is.
    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) root.cursorActive = true
        else if (dx !== 0) root.stepMode(dx)
        else if (dy !== 0) root.stepMode(dy)
      }
      onActivateRequested: if (root.cursorActive && root.modeAt >= 0 && root.modeAt < root.modes.length) root.setMode(root.modes[root.modeAt])
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: content
        anchors { left: parent.left; right: parent.right; top: parent.top }
        spacing: Style.space(14)

        // The icon, "Battery" over the status, and the percentage.
        Item {
          width: parent.width
          implicitHeight: Math.max(bigIcon.implicitHeight, heading.implicitHeight, percent.implicitHeight)

          Text {
            id: bigIcon
            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
            textFormat: Text.PlainText
            text: root.icon
            color: root.bar.foreground
            font { family: root.bar.fontFamily; pixelSize: Style.font.display }
            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heading
            anchors {
              left: bigIcon.right; leftMargin: Style.space(14)
              right: percent.left; rightMargin: Style.space(10)
              verticalCenter: parent.verticalCenter
            }
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "Battery"
              color: root.bar.foreground
              font { family: root.bar.fontFamily; pixelSize: Style.font.title; bold: true }
              elide: Text.ElideRight
            }

            Text {
              id: statusLine
              width: parent.width
              textFormat: Text.PlainText
              text: root.status.toUpperCase()
              color: Qt.darker(root.bar.foreground, 1.4)
              font { family: root.bar.fontFamily; pixelSize: Style.font.caption; bold: true; letterSpacing: 1.2 }
              elide: Text.ElideRight
            }
          }

          Text {
            id: percent
            anchors { right: parent.right; verticalCenter: parent.verticalCenter }
            textFormat: Text.PlainText
            text: root.figures.percentage || "—"
            color: root.bar.foreground
            font { family: root.bar.fontFamily; pixelSize: Style.font.displayLarge; bold: true }
            Behavior on color { ColorAnimation { duration: 200 } }
          }
        }

        // The charge as a bar, which breathes while it charges.
        Item {
          width: parent.width
          implicitHeight: Style.space(8)

          Rectangle {
            id: track
            anchors.fill: parent
            radius: height / 2
            color: Util.alpha(root.bar.foreground, 0.12)
          }

          Rectangle {
            anchors { left: track.left; verticalCenter: track.verticalCenter }
            width: Math.max(track.height, track.width * root.level)
            height: track.height
            radius: track.radius
            color: root.bar ? root.bar.foreground : Commons.Color.foreground

            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 220 } }

            SequentialAnimation on opacity {
              running: root.charging && !root.full && root.opened
              loops: Animation.Infinite
              alwaysRunToEnd: true
              NumberAnimation { from: 1.0; to: 0.55; duration: 950; easing.type: Easing.InOutSine }
              NumberAnimation { from: 0.55; to: 1.0; duration: 950; easing.type: Easing.InOutSine }
            }
          }
        }

        // The figures, once any have been read. They stay through the moment
        // UPower calls a battery above its limit's start full on plugging in.
        Row {
          visible: root.figures.percentage !== undefined
          width: parent.width
          spacing: Style.space(20)

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            Figure { label: "Battery size"; value: root.figures.size || "" }
            Figure { label: "Charge cycles"; value: root.figures.cycles || "—" }
          }

          Column {
            width: (parent.width - parent.spacing) / 2
            spacing: Style.spacing.labelGap
            Figure {
              label: root.holding ? "Charge limit" : root.unplugged ? "Time left" : "Time to full"
              value: root.holding ? (root.figures.threshold || "-") : root.resting ? "-" : (root.figures.time || "—")
            }
            Figure {
              label: root.holding ? "Battery state" : root.unplugged ? "Discharging" : "Charging"
              value: root.holding ? "Holding" : root.topped ? "-" : (root.figures.rate || "")
            }
          }
        }

        // The power modes, when power-profiles-daemon offers any.
        PanelSeparator {
          visible: root.modes.length > 0
          foreground: root.bar.foreground
        }

        Column {
          visible: root.modes.length > 0
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "POWER PROFILE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Row {
            id: modeRow
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.modes

              Button {
                required property var modelData
                required property int index
                readonly property string name: String(modelData)

                width: root.modes.length > 0 ? (modeRow.width - modeRow.spacing * (root.modes.length - 1)) / root.modes.length : 0
                iconText: Model.modeIcon(name)
                iconSize: Style.font.title
                text: name.charAt(0).toUpperCase() + name.slice(1)
                fontSize: Style.font.bodySmall
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY + Style.space(2)
                bordered: true
                active: root.activeMode === modelData
                hasCursor: root.cursorActive && root.modeAt === index
                onClicked: root.setMode(modelData)
                onHovered: function(on) {
                  if (!on) return
                  root.cursorActive = true
                  root.modeAt = index
                }
              }
            }
          }
        }
      }
    }
  }

  // A figure's name, dimmed, on the left and its value at the far end.
  component Figure: Row {
    property alias label: name.text
    property alias value: amount.text

    width: parent.width
    spacing: Style.space(8)

    Text {
      id: name
      textFormat: Text.PlainText
      color: root.bar.foreground
      opacity: 0.6
      font { family: root.bar.fontFamily; pixelSize: Style.font.bodySmall }
    }

    Item {
      width: Math.max(0, parent.width - name.implicitWidth - amount.implicitWidth - parent.spacing * 2)
      height: 1
    }

    Text {
      id: amount
      textFormat: Text.PlainText
      color: root.bar.foreground
      font { family: root.bar.fontFamily; pixelSize: Style.font.bodySmall }
    }
  }
}
