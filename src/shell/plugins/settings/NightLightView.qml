import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The night light's part of the Displays page: its switch, the schedule
// that switches it by itself, and how warm it makes the screen. The
// schedule and the warmth are nova nightlight's, kept in shell.json; the
// shell's night light service follows them, and does the switching.
Section {
  id: root

  property var shell: null
  // shell.json's nightlight, as Settings' state has it.
  property var settings: ({})
  // A `nova nightlight` command, which the window runs and then reads the
  // state.
  signal command(var argv)

  readonly property var service: shell ? shell.serviceFor("nova.nightlight") : null
  readonly property string schedule: settings.schedule === "sunset" || settings.schedule === "hours" ? settings.schedule : "off"
  readonly property int night: {
    var kelvin = Math.round(Number(settings.temperature))
    return kelvin >= 2500 && kelvin <= 5500 ? kelvin : 4000
  }
  readonly property var place: service ? service.place : null
  readonly property var sun: place ? service.sun(Date.now()) : null

  function clock(time) {
    return Qt.formatTime(new Date(time), "HH:mm")
  }

  title: "NIGHT LIGHT"
  visible: service !== null
  // The weather's place may have been set since the shell last looked.
  Component.onCompleted: if (service) service.locate()

  Toggle {
    width: parent.width
    label: "Night Light"
    detail: "A warmer screen, easier on the eyes at night."
    checked: !!root.service && root.service.enabled
    onClicked: if (root.service) root.service.setNightlight(!root.service.enabled)
  }

  Line {
    label: "Schedule"
    detail: root.schedule === "off" ? "It comes on only by hand."
      : root.schedule === "hours" ? "Every day, by the clock."
      : !root.place ? "No place to go by: choose the weather's place, in its card in the bar."
      : !root.sun ? "The sun does not set and rise in " + root.place.name + " today."
      : "Today the sun rises at " + root.clock(root.sun.rise) + " and sets at " + root.clock(root.sun.set) + " in " + root.place.name + "."
    ButtonGroup {
      options: [{ value: "off", label: "Off" }, { value: "sunset", label: "Sunset to Sunrise" }, { value: "hours", label: "Set Hours" }]
      value: root.schedule
      onChanged: function (value) { if (value !== root.schedule) root.command(["nova-nightlight-schedule", value]) }
    }
  }

  HoursLine {
    visible: root.schedule === "hours"
    from: root.settings.from || "22:00"
    to: root.settings.to || "07:00"
    onPicked: function (from, to) { root.command(["nova-nightlight-schedule", from, to]) }
  }

  Line {
    label: "Warmth"
    detail: 5500 - Math.round(warmth.knobAt) * 100 + " K"
    // In steps of 100 K, from 5500 K on the left to 2500 K, the warmest.
    LevelSlider {
      id: warmth
      width: Style.space(220)
      from: 0
      to: 30
      wheelStep: 1
      whole: true
      value: (5500 - root.night) / 100
      onLetGo: at => root.command(["nova-nightlight-warmth", String(5500 - Math.round(at) * 100)])
    }
  }

  Caption {
    width: parent.width
    visible: root.schedule !== "off"
    text: "Switched by hand, from the bar, the keys or the menu, it stays so until the schedule's next turn."
  }
}
