import QtQuick
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Hyprland's workspaces 1 to 10: the first five always, the rest while they
// exist, 10 shown as 0 like its key. The focused one is a dot, an empty one
// is faded, and a click focuses it.
BarWidget {
  id: root
  moduleName: "nova.workspaces"

  readonly property var numbers: {
    var shown = [1, 2, 3, 4, 5]
    var all = Hyprland.workspaces.values
    for (var i = 0; i < all.length; i++) {
      var id = all[i].id
      if (id > 0 && id <= 10 && shown.indexOf(id) === -1) shown.push(id)
    }
    return shown.sort(function(a, b) { return a - b })
  }
  // A gap after the last, before the next widget.
  readonly property real gap: vertical ? 0 : Style.spaceReal(1.5)

  function workspace(number) {
    var all = Hyprland.workspaces.values
    for (var i = 0; i < all.length; i++) {
      if (all[i].id === number) return all[i]
    }
    return null
  }

  implicitWidth: grid.implicitWidth + gap
  implicitHeight: grid.implicitHeight

  Grid {
    id: grid
    rows: root.vertical ? -1 : 1
    columns: root.vertical ? 1 : -1
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.numbers

      WidgetButton {
        required property int modelData
        readonly property var workspace: root.workspace(modelData)
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData

        bar: root.bar
        text: focused ? "󱓻" : (modelData === 10 ? "0" : String(modelData))
        opacity: focused || (workspace !== null && workspace.toplevels.values.length > 0) ? 1 : 0.5
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : Style.space(20)
        fixedHeight: root.barSize

        onPressed: {
          if (root.bar) root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + modelData + "\" })"))
        }
      }
    }
  }
}
