import QtQuick

// The share of memory in use, from the Readouts service.
ReadoutWidget {
  widgetId: "nova.memory"
  part: "memory"
  glyph: "\u{EFC5}"
  percent: service ? service.memory : -1
  tip: service && service.memoryWords !== "" ? "Memory: " + service.memoryWords : "Memory"
}
