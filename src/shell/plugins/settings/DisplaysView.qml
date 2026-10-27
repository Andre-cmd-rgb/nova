import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "DisplaysModel.js" as Model

// Displays' page in Settings, over `nova monitor`: each display's resolution,
// refresh rate, scale and rotation, where it sits next to the others, and
// whether it is on. A change applies at once and goes back by itself unless
// it is kept, so a mode a display cannot show, which leaves it black, undoes
// itself. Kept, it is a rule after ~/.config/hypr/monitors.lua's.
Column {
  id: root
  spacing: Style.space(22)

  // `nova monitor list --json`, as `nova-settings state` reads it.
  property var listing: ({})
  readonly property var displays: listing.displays || []
  readonly property var pending: listing.pending || null
  readonly property var enabledDisplays: displays.filter(function (d) { return d.enabled })
  readonly property var labels: Model.labels(displays)

  // A `nova monitor` command, which the window runs and then reads the state.
  signal command(var argv)
  // The clock ran out and the change went back by itself: the window reads
  // the state again.
  signal expired()

  property real now: Date.now()
  // The clock already reported run out, so a state that still shows it is
  // not read again every second.
  property real expiredAt: 0
  readonly property int secondsLeft: pending ? Model.secondsLeft(pending.until, now) : 0

  onPendingChanged: now = Date.now()

  Timer {
    interval: 1000
    repeat: true
    running: root.pending !== null
    onTriggered: {
      root.now = Date.now()
      if (root.now / 1000 > root.pending.until + 1 && root.expiredAt !== root.pending.until) {
        root.expiredAt = root.pending.until
        root.expired()
      }
    }
  }

  function set(display, setting, value, other) {
    var argv = ["nova-monitor", "set", display.name, setting]
    if (value !== undefined) argv.push(value)
    if (other !== undefined) argv.push(other)
    command(argv)
  }

  Rectangle {
    visible: root.pending !== null
    width: parent.width
    height: keep.implicitHeight + Style.space(24)
    radius: Style.cornerRadius
    color: Qt.alpha(Commons.Color.accent, 0.12)
    border.width: 1
    border.color: Qt.alpha(Commons.Color.accent, 0.4)

    Line {
      id: keep
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.space(14)
      label: "Keep these display settings?"
      detail: Model.countdown(root.secondsLeft)
      Row {
        spacing: Style.space(8)
        Button { text: "Go Back"; bordered: true; onClicked: root.command(["nova-monitor", "revert"]) }
        Button { text: "Keep"; bordered: true; selected: true; onClicked: root.command(["nova-monitor", "keep"]) }
      }
    }
  }

  Caption {
    width: parent.width
    visible: root.displays.length === 0
    text: "No displays: Hyprland did not answer."
  }

  Section {
    visible: root.enabledDisplays.length > 1
    title: "ARRANGEMENT"

    Item {
      id: arrangement
      width: parent.width
      height: Style.space(140)

      Repeater {
        model: Model.layout(root.enabledDisplays, arrangement.width, arrangement.height)
        delegate: Rectangle {
          id: screen
          required property var modelData
          // A hair apart, so two displays edge to edge read as two.
          x: modelData.x + 1
          y: modelData.y + 1
          width: Math.max(2, modelData.width - 2)
          height: Math.max(2, modelData.height - 2)
          radius: Math.max(2, Style.cornerRadius / 2)
          color: Qt.alpha(Commons.Color.foreground, 0.06)
          border.width: modelData.focused ? 2 : 1
          border.color: modelData.focused ? Commons.Color.accent : Qt.alpha(Commons.Color.foreground, 0.25)

          Text {
            anchors.centerIn: parent
            width: parent.width - Style.space(8)
            text: root.labels[screen.modelData.name] || screen.modelData.name
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }
        }
      }
    }
    Caption {
      width: parent.width
      text: "Outlined, the display in use. Position, under each display, moves it."
    }
  }

  Repeater {
    model: root.displays

    delegate: Section {
      id: section
      required property var modelData
      readonly property var d: modelData
      readonly property string resolution: d.width + "x" + d.height
      readonly property var others: root.enabledDisplays.filter(function (o) { return o.name !== section.d.name })
      // The display Position is next to, picked where there are several.
      property string otherName: ""
      readonly property var other: Model.pick(others, otherName)

      width: root.width
      title: (root.labels[d.name] || d.name).toUpperCase()

      Toggle {
        width: parent.width
        visible: root.displays.length > 1
        // Never the only display on.
        enabled: !(section.d.enabled && root.enabledDisplays.length === 1)
        opacity: enabled ? 1 : 0.5
        label: "Use this display"
        description: section.d.internal
          ? "The computer's own screen, which goes off by itself when the lid closes with a display plugged in."
          : "Plugged into " + section.d.name + "."
        checked: section.d.enabled
        onClicked: root.set(section.d, checked ? "off" : "on")
      }

      Line {
        visible: section.d.enabled
        label: "Resolution"
        Dropdown {
          id: resolutionChoice
          width: Style.spacing.dropdownWidth
          showLabel: false
          options: Model.resolutions(section.d.modes)
          value: section.resolution
          onChanged: function (value) {
            // Choosing lets go of the binding; it follows the display again,
            // so a change gone back shows as gone back.
            resolutionChoice.value = Qt.binding(function () { return section.resolution })
            var mode = Model.modeAt(section.d.modes, value, section.d.refresh)
            if (mode !== "" && value !== section.resolution) root.set(section.d, "mode", mode)
          }
        }
      }

      Line {
        visible: section.d.enabled
        label: "Refresh rate"
        Dropdown {
          id: rateChoice
          readonly property string current: Model.rateValue(section.d.modes, section.resolution, section.d.refresh)
          width: Style.spacing.dropdownWidth
          showLabel: false
          options: Model.rates(section.d.modes, section.resolution)
          value: current
          onChanged: function (value) {
            rateChoice.value = Qt.binding(function () { return rateChoice.current })
            if (value !== rateChoice.current) root.set(section.d, "mode", value)
          }
        }
      }

      Line {
        visible: section.d.enabled
        label: "Scale"
        detail: "Looks like " + section.d.logicalWidth + " × " + section.d.logicalHeight
        ButtonGroup {
          id: scaleChoice
          options: Model.scaleOptions(section.d.scales, section.d.scale)
          value: Model.scaleValue(section.d.scales, section.d.scale)
          onChanged: function (value) { if (value !== scaleChoice.value) root.set(section.d, "scale", value) }
        }
      }

      Line {
        visible: section.d.enabled
        label: "Rotation"
        ButtonGroup {
          id: rotationChoice
          options: Model.rotations
          value: Model.rotation(section.d.transform)
          onChanged: function (value) { if (value !== rotationChoice.value) root.set(section.d, "rotate", value) }
        }
      }

      Line {
        visible: section.d.enabled && section.other !== null
        label: "Position"
        detail: section.other ? "Next to " + (root.labels[section.other.name] || section.other.name) : ""
        Row {
          spacing: Style.space(8)
          Dropdown {
            id: otherChoice
            anchors.verticalCenter: parent.verticalCenter
            visible: section.others.length > 1
            width: Style.spacing.dropdownWidth
            showLabel: false
            options: section.others.map(function (o) { return { value: o.name, label: root.labels[o.name] || o.name } })
            value: section.other ? section.other.name : ""
            onChanged: function (value) {
              section.otherName = value
              otherChoice.value = Qt.binding(function () { return section.other ? section.other.name : "" })
            }
          }
          ButtonGroup {
            id: placeChoice
            anchors.verticalCenter: parent.verticalCenter
            options: Model.places
            value: Model.relation(section.d, section.other)
            onChanged: function (value) {
              if (section.other && value !== placeChoice.value) root.set(section.d, "position", value, section.other.name)
            }
          }
        }
      }

      Line {
        visible: section.d.saved
        label: "Kept in Settings"
        detail: "Over what ~/.config/hypr/monitors.lua says for it."
        Button { text: "Reset"; bordered: true; onClicked: root.command(["nova-monitor", "reset", section.d.name]) }
      }
    }
  }

  Caption {
    width: parent.width
    visible: root.displays.length > 0
    text: "A change shows at once, and goes back by itself after 15 seconds unless you keep it. Kept, it wins over ~/.config/hypr/monitors.lua; Reset hands a display back to that file."
  }
}
