import QtQuick
import qs.Commons
import qs.Ui

// A badge while an update waits, a new Nova or app updates, with what it is
// as its tooltip; a click opens Settings on Updates. The asking is the
// plugin's service's (SystemUpdateCheck.qml), one for every screen's copy:
// nova-update-check every six hours, and again once an update run says it
// is done. nova-shell nova.system-update refresh asks now, and clear puts
// the badge away until the next answer.
BarWidget {
  id: root
  widgetId: "nova.system-update"
  sharedId: "nova.system-update"

  // What waits, in the tooltip's words; "" while nothing does.
  readonly property string waiting: shared ? shared.waiting : ""

  function refresh() {
    shared?.refresh()
  }

  function clear() {
    shared?.clear()
  }

  visible: waiting !== ""
  implicitWidth: badge.implicitWidth
  implicitHeight: badge.implicitHeight

  BarIcon {
    id: badge
    anchors.fill: parent
    bar: root.bar
    glyph: "\uf021"
    slot: Style.bar.statusSlot
    fontSize: Style.font.caption
    tip: root.waiting
    onClicked: root.bar?.run("nova-settings updates")
  }
}
