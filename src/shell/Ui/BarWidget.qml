import QtQuick
import qs.Commons

// What every bar widget is built on. The bar sets three properties on each
// widget it places:
//   bar         the Bar the widget sits in, with its colours and run()
//   moduleName  the widget's name, by which the bar finds its settings and
//               tells its IPC routes from another widget's
//   settings    the widget's own entry from the layout in shell.json
// A widget adds whatever else it needs.
Item {
  id: root

  property QtObject bar: null
  property string moduleName: ""
  property var settings: ({})

  // The bar's shape, read by most widgets to lay themselves out across or
  // along it; a widget with no bar yet takes a horizontal one.
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal

  // Calls <method> on every instance of this widget, on every monitor's bar.
  function broadcast(method) {
    var widgets = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < widgets.length; i++) {
      var widget = widgets[i]
      if (widget && typeof widget[method] === "function") widget[method]()
    }
  }

  // The setting <name> from the widget's entry, <fallback> when it is not
  // there or is null.
  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }
}
