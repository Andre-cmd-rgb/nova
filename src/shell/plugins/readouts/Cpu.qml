import QtQuick

// The processor's busy share, from the Readouts service.
ReadoutWidget {
  widgetId: "nova.cpu"
  part: "cpu"
  glyph: "\u{F0EE0}"
  percent: service ? service.cpu : -1
  tip: percent >= 0 ? "CPU: " + percent + "% in use" : "CPU"
}
