import QtQuick
import qs.Commons

// What everything the bar places is built on: a widget, or a Panel, which is
// a widget with a panel to open. The bar hands each one three things:
//   bar         the Bar it sits in, with its colours and run()
//   moduleName  its name, by which the bar finds its settings and tells its
//               IPC routes from another's
//   settings    its own entry in the layout in shell.json
// and it reads the bar's shape from <vertical> and <barSize>, a horizontal
// bar's while it has none.
Item {
  property QtObject bar: null
  property string moduleName: ""
  property var settings: ({})

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal

  // The setting <name> from the entry; <fallback> where it is missing or
  // null.
  function setting(name, fallback) {
    return (settings ? settings[name] : undefined) ?? fallback
  }
}
