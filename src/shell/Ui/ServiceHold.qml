import QtQuick

// <holder>'s hold on <service>, a service built on BarWidgetService: held
// while both are there, let go when the service changes (switched off and on
// again, a new object) and when the hold goes with its holder.
QtObject {
  property var service: null
  property var holder: null

  // The service held now.
  property var held: null

  function keep() {
    if (held === service) return
    if (held) held.release(holder)
    held = service
    if (held) held.hold(holder)
  }

  onServiceChanged: keep()
  Component.onCompleted: keep()
  Component.onDestruction: if (held) held.release(holder)
}
