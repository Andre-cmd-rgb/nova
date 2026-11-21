import QtQuick
import qs.Commons
import qs.Ui

// What the bar's CPU, Graphics and Memory widgets share: a glyph at the
// bar's icon size and a percentage at label size, as the battery's widget
// draws them, a tooltip, and a click that opens the system monitor. The
// numbers come from the Readouts service, which reads them once for every
// readout on the bar.
//
// A readout holds its part of the service for as long as it is on the bar,
// which is how the service knows to read at all.
BarWidget {
  id: root

  // "cpu", "memory" or "gpu": the part of the service this reads.
  property string part: ""
  property string glyph: ""
  // The reading, a whole percentage, -1 for none yet.
  property int percent: -1
  property string tip: ""

  // The service, which may come after the widget: serviceFor's answer
  // follows the services the shell has, and the part is held while both
  // are there.
  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor("nova.readouts") : null
  readonly property alias button: button

  ServiceHold {
    service: root.service
    holder: root.part
  }

  // The pointer came onto the readout, for one that looks again at what its
  // tooltip says.
  signal pointerCame()

  // The widest ordinary reading, so that the neighbours do not move as the
  // number goes from 9% to 10%.
  TextMetrics {
    id: widest
    text: "99%"
    font.family: button.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    hasContent: true
    implicitWidth: Math.ceil(content.implicitWidth) + Style.space(9) * 2
    implicitHeight: button.thickness
    tip: root.tip
    onClicked: root.bar.run("nova-launch-or-focus-tui btop")
    onCrossed: over => { if (over) root.pointerCame() }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.space(5)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: root.glyph
        color: button.ink
        // Named, not found by falling back from the bar's font: Memory's
        // stick (U+EFC5) is in the private range fonts such as URW Gothic
        // also fill, with a glyph of their own, and they come first.
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: Style.bar.iconFont
        renderType: Text.NativeRendering
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(implicitWidth, Math.ceil(widest.advanceWidth))
        text: root.percent >= 0 ? root.percent + "%" : "–"
        color: button.ink
        font.family: button.fontFamily
        font.pixelSize: Style.font.bodySmall
        renderType: Text.NativeRendering
      }
    }
  }
}
