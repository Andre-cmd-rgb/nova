import QtQuick

// The keys of a panel driven from the keyboard, turned into what they ask
// for. It wraps the panel's content and sends signals; the panel keeps its
// own cursor and decides what each does:
//   KeyboardPanel {
//     PanelKeyCatcher {
//       anchors.fill: parent
//       onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
//       onActivateRequested: root.activateCursor()
//       onCloseRequested: root.close()
//       onDeleteRequested: root.deleteSelected()
//       onTextKey: function(t) { if (t === "r") root.refresh() }
//
//       Column { ... }
//     }
//   }
//
// The arrows and h, j, k, l move; Return and Enter (which also send
// returnRequested()) and Space activate; Escape closes; Tab and Shift+Tab
// step; x deletes. Any other character goes to textKey() and on to the
// item with the focus.
//
// It sees the keys before the items inside it, even the one with the focus,
// so Up and Down move the cursor rather than scroll a list. A panel with a
// field to type in (network's passphrase) sets <blocked> while the field
// has the focus: then every key goes to the field.
Item {
  id: root

  property bool blocked: false

  signal moveRequested(int dx, int dy)
  signal activateRequested()
  signal returnRequested()
  signal closeRequested()
  signal deleteRequested()
  signal tabRequested(int direction)
  signal textKey(string text)

  focus: true

  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) {
    if (blocked) return
    var key = event.key
    var text = event.text
    if (key === Qt.Key_Escape) {
      root.closeRequested()
    } else if (key === Qt.Key_Tab || key === Qt.Key_Backtab) {
      root.tabRequested(key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier) ? -1 : 1)
    } else if (key === Qt.Key_Down || text === "j") {
      root.moveRequested(0, 1)
    } else if (key === Qt.Key_Up || text === "k") {
      root.moveRequested(0, -1)
    } else if (key === Qt.Key_Right || text === "l") {
      root.moveRequested(1, 0)
    } else if (key === Qt.Key_Left || text === "h") {
      root.moveRequested(-1, 0)
    } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
      root.returnRequested()
      root.activateRequested()
    } else if (key === Qt.Key_Space) {
      root.activateRequested()
    } else if (text === "x" || text === "X") {
      root.deleteRequested()
    } else {
      if (text && text.length === 1) root.textKey(text)
      return
    }
    event.accepted = true
  }
}
