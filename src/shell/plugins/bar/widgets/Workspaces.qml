import QtQuick
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

// Hyprland's workspaces 1 to 10: 1 to 5 always, the others while they
// exist, and 10 as 0, as its key is. The focused one shows as a dot, one
// with no windows faded; a click goes to it.
BarWidget {
  id: widget
  moduleName: "nova.workspaces"

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
  readonly property real gap: vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: buttons.implicitWidth + gap
  implicitHeight: buttons.implicitHeight

  // One row, or one column on a side bar. Only the columns are set: with the
  // rows set too, the two change one after the other as the bar turns, and
  // for that moment the grid has room for one button and warns.
  Grid {
    id: buttons
    columns: widget.vertical ? 1 : widget.numbers.length
    rowSpacing: widget.vertical ? Style.space(2) : 0
    columnSpacing: widget.vertical ? 0 : Style.space(1)

    Repeater {
      model: widget.numbers

      WidgetButton {
        required property int modelData
        readonly property var workspace: widget.present[modelData] || null
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData

        bar: widget.bar
        text: focused ? "\u{F14FB}" : String(modelData % 10)
        opacity: focused || (workspace !== null && workspace.toplevels.values.length > 0) ? 1 : 0.5
        fixedWidth: widget.vertical ? widget.barSize : Style.space(20)
        fixedHeight: widget.barSize
        horizontalMargin: 6
        verticalPadding: 6

        onPressed: {
          if (widget.bar) widget.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + modelData + "\" })"))
        }
      }
    }
  }
}
