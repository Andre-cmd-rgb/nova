import QtQuick
import Quickshell.Services.SystemTray
import qs.Commons
import qs.Ui
import "TrayIcons.js" as TrayIcons

// Settings → Menu Bar's tray icons: each icon in the tray now, by its app's
// name (two apps that share an icon's Id each have their own), and each one
// hidden, with a switch that shows it in the bar or hides it there. An icon's
// own menu ends with Quit, so hiding one lives here, with the rest of what
// the bar shows. The switch runs `nova bar set nova.tray`,
// the tray widget's own `hidden` setting, and its `names` first, so that a
// hidden icon is listed by its app's name once the app has gone.
Section {
  id: root
  title: "TRAY ICONS"

  // The state's bar: hiddenTray, the icons hidden (TrayKey.js's keys), and
  // hiddenTrayNames.
  property var bar: ({})
  // The icons that ask to be seen now (a passive one is not in the bar):
  // the tray's, or a test's stand-ins.
  property var items: SystemTray.items.values.filter(item => item.status !== Status.Passive)
  // A nova bar command, which the window runs and then reads the state.
  // <changes>: what it sets, by its path in the state, shown at once.
  signal command(var argv, var changes)

  readonly property var rows: TrayIcons.rows(items, bar.hiddenTray, bar.hiddenTrayNames)

  visible: rows.length > 0

  function hide(row) {
    const item = TrayIcons.itemOf(root.items, row.id) || { title: row.name }
    const names = TrayIcons.named(root.bar.hiddenTrayNames, row.id, item)
    const hidden = TrayIcons.hide(root.bar.hiddenTray, row.id)
    root.command(["nova", "bar", "set", "nova.tray", "names", JSON.stringify(names), "--json"], { "bar.hiddenTrayNames": names })
    root.command(["nova", "bar", "set", "nova.tray", "hidden", JSON.stringify(hidden), "--json"], { "bar.hiddenTray": hidden })
  }

  function show(row) {
    const hidden = TrayIcons.show(root.bar.hiddenTray, row.id, root.items)
    root.command(["nova", "bar", "set", "nova.tray", "hidden", JSON.stringify(hidden), "--json"], { "bar.hiddenTray": hidden })
  }

  Repeater {
    model: root.rows
    delegate: Toggle {
      required property var modelData
      width: parent.width
      label: modelData.name
      detail: modelData.here ? "" : "Not running"
      checked: !modelData.hidden
      onClicked: checked ? root.hide(modelData) : root.show(modelData)
    }
  }
}
