import QtQuick
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Hyprland's workspaces 1 to 10: 1 to 5 always, the others while they
// exist, and 10 as 0, as its key is. The focused one shows as a dot, one
// with no windows faded; a click goes to it.
BarWidget {
  id: widget
  widgetId: "nova.workspaces"

  // Hyprland's workspaces by number.
  readonly property var present: {
    var byNumber = {}
    Array.prototype.forEach.call(Hyprland.workspaces.values, function(workspace) {
      if (!(workspace.id in byNumber)) byNumber[workspace.id] = workspace
    })
    return byNumber
  }
  readonly property var numbers: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10].filter(function(n) { return n <= 5 || n in present })
  // Room after the last one, before the next widget.
  readonly property real gap: Style.spaceReal(1.5)

  implicitWidth: buttons.implicitWidth + gap
  implicitHeight: buttons.implicitHeight

  Row {
    id: buttons
    spacing: Style.space(1)

    Repeater {
      model: widget.numbers

      BarButton {
        required property int modelData
        readonly property var workspace: widget.present[modelData] || null
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData

        bar: widget.bar
        text: focused ? "\u{F14FB}" : String(modelData % 10)
        opacity: focused || (workspace !== null && workspace.toplevels.values.length > 0) ? 1 : 0.5
        implicitWidth: Style.space(20)
        implicitHeight: widget.thickness
        margin: 6

        onClicked: {
          if (widget.bar) widget.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + modelData + "\" })"))
        }
      }
    }
  }
}
