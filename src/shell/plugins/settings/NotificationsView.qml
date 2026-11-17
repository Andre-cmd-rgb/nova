import QtQuick
import qs.Ui

// The Notifications page: do-not-disturb's switch, and the hours it holds by
// itself every day. The hours are nova notification schedule's, kept in
// shell.json; the shell's notifications follow them, and do the switching.
// Nova's answers to what you just did still show, and so do urgent
// notifications sent by scripts; a switch by hand holds until the schedule's
// next turn.
Section {
  id: root

  property var shell: null
  // shell.json's doNotDisturb, as Settings' state has it.
  property var settings: ({})
  // A `nova notification schedule` command, which the window runs and then
  // reads the state.
  // <changes>: what it sets, by its path in what this view was given, which
  // Settings shows at once (SettingsState); null for none.
  signal command(var argv, var changes)

  readonly property var service: shell ? shell.serviceFor("nova.notifications") : null
  readonly property bool scheduled: settings.schedule === "hours"

  title: "DO NOT DISTURB"
  visible: service !== null

  Toggle {
    width: parent.width
    label: "Do Not Disturb"
    checked: !!root.service && root.service.doNotDisturb
    onClicked: if (root.service) root.service.setDoNotDisturb(!root.service.doNotDisturb)
  }

  Line {
    label: "Schedule"
    ButtonGroup {
      options: [{ value: "off", label: "Off" }, { value: "hours", label: "Set Hours" }]
      value: root.scheduled ? "hours" : "off"
      onChanged: function (value) { if (value !== (root.scheduled ? "hours" : "off")) root.command(["nova-notification-schedule", value], { schedule: value }) }
    }
  }

  HoursLine {
    visible: root.scheduled
    from: root.settings.from || "22:00"
    to: root.settings.to || "07:00"
    onPicked: function (end, time) { root.command(["nova-notification-schedule", end, time], null) }
  }
}
