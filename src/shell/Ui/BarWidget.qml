import QtQuick
import qs.Commons

// What everything the bar places is built on: a widget, or a Panel, which is
// a widget with a panel to open. The bar hands each one three things:
//   bar       the Bar it sits in, with its colours and run()
//   widgetId  its id in the layout, by which the bar finds its settings
//             and its IPC target
//   settings  its own entry in the layout in shell.json
// and it reads the bar's <thickness>, the default one while it has none.
//
// Each screen's bar has a copy of every widget. The work behind a widget
// (asking for the weather, watching a radio, polling a modem) is a service's,
// done once for all the copies, never in the copy: the widget names it in
// <sharedId>, finds it through the bar's shell as <shared>, and holds it for
// as long as the copy lives (the service's hold and release, handed the copy,
// whose settings and panel the service may read). A service works while a
// copy holds it, and rests while none does.
Item {
  id: widget

  property QtObject bar: null
  property string widgetId: ""
  property var settings: ({})

  readonly property int thickness: bar?.thickness ?? Style.bar.sizeHorizontal

  // The entry's <name>, or <fallback> where it has none or null.
  function setting(name, fallback) {
    return settings?.[name] ?? fallback
  }

  property string sharedId: ""
  readonly property var shared: sharedId !== "" && bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(sharedId) : null

  property ServiceHold sharedHold: ServiceHold {
    service: widget.shared
    holder: widget
  }
}
