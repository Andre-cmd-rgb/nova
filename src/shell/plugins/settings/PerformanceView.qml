import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "UndervoltModel.js" as Model

// Performance's page in Settings: the CPU's undervolt, over `nova power
// undervolt`, with the core's offset and the cache's each its own. A depth
// is chosen on the sliders and set with Apply, which asks for the
// administrator's password, as the command does; dragging alone sets
// nothing, so a slider passed over on the way never reaches the CPU.
Column {
  id: root
  spacing: Style.space(22)

  // `nova power undervolt status --json`, as `nova-settings state` reads it.
  property var undervolt: ({})
  readonly property bool isSet: Model.isSet(undervolt)

  // The depths on the sliders, in millivolts (0 or below): what is set,
  // until a slider moves.
  property int wantCore: isSet ? undervolt.core : 0
  property int wantCache: isSet ? undervolt.cache : 0
  readonly property bool changed: Model.changed(undervolt, wantCore, wantCache)
  // Once what is set is what the sliders say (an Apply landed), they follow
  // it again.
  onUndervoltChanged: if (!changed) revert()

  // A `nova-power-undervolt` command, which the window runs and then reads
  // the state.
  signal command(var argv)

  function revert() {
    wantCore = Qt.binding(function () { return root.isSet ? root.undervolt.core : 0 })
    wantCache = Qt.binding(function () { return root.isSet ? root.undervolt.cache : 0 })
  }

  component Depth: Line {
    id: depth
    property int offset: 0
    signal picked(int offset)
    detail: Model.mv(-Math.round(slider.liveValue))
    PanelSlider {
      id: slider
      width: Style.space(260)
      minimum: 0
      maximum: 120
      step: 5
      integer: true
      tickCount: 13
      value: -depth.offset
      onReleased: function (value) { depth.picked(-Math.round(value)) }
    }
  }

  Section {
    title: "UNDERVOLT"

    Line {
      label: Model.headline(root.undervolt)
      detail: Model.detail(root.undervolt)
      Row {
        spacing: Style.space(8)
        Button {
          visible: root.undervolt.state === "held" || root.undervolt.state === "pending"
          text: "Apply Again"
          bordered: true
          onClicked: root.command(["nova-power-undervolt", "on"])
        }
        Button {
          visible: root.isSet
          text: "Turn Off"
          bordered: true
          onClicked: root.command(["nova-power-undervolt", "off"])
        }
      }
    }

    Depth {
      label: "Core"
      offset: root.wantCore
      onPicked: function (offset) { root.wantCore = offset }
    }

    Depth {
      label: "Cache"
      offset: root.wantCache
      onPicked: function (offset) { root.wantCache = offset }
    }

    Line {
      visible: root.changed
      label: root.wantCore === 0 && root.wantCache === 0 ? "Off" : Model.describe(root.wantCore, root.wantCache)
      Row {
        spacing: Style.space(8)
        Button { text: "Revert"; bordered: true; onClicked: root.revert() }
        Button {
          text: "Apply"
          bordered: true
          selected: true
          onClicked: root.command(Model.applyCommand(root.wantCore, root.wantCache))
        }
      }
    }
  }
}
