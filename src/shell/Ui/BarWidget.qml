import QtQuick
import qs.Commons

// What everything the bar places is built on: a widget, or a Panel, which is
// a widget with a panel to open. The bar hands each one three things:
//   bar       the Bar it sits in, with its colours and run()
//   widgetId  its id in the layout, by which the bar finds its settings
//             and its IPC target
//   settings  its own entry in the layout in shell.json
// and it reads the bar's shape from <vertical> and <thickness>, a horizontal
// bar's while it has none.
Item {
  property QtObject bar: null
  property string widgetId: ""
  property var settings: ({})

  readonly property bool vertical: bar?.vertical ?? false
  readonly property int thickness: bar?.thickness ?? Style.bar.sizeHorizontal

  // The entry's <name>, or <fallback> where it has none or null.
  function setting(name, fallback) {
    return settings?.[name] ?? fallback
  }
}
