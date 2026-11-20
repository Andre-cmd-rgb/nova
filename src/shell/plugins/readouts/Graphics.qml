import QtQuick

// The busy share of the graphics card that draws the desktop, from the
// Readouts service, and in the tooltip whether any other card is on. The
// other cards may have woken or gone to sleep since the last look, so the
// service looks again as the pointer comes, and the tooltip is asked for
// again once it has the answer.
ReadoutWidget {
  id: root
  widgetId: "nova.graphics"
  part: "gpu"
  glyph: "\u{F08AE}"
  percent: service ? service.graphics : -1
  tip: service ? service.graphicsWords : "Graphics"

  onPointerCame: if (service) service.refreshCards()

  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onCardsRead() {
      if (root.button.pointedAt) root.bar.tip.ask(root.button, root.tip)
    }
  }
}
