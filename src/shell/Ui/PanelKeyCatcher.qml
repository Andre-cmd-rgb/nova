import QtQuick

// The keys of a panel driven from the keyboard, turned into what they ask
// for. It wraps the panel's content and sends signals; the panel keeps its
// own cursor and decides what each does:
//   KeyboardPanel {
//     PanelKeyCatcher {
//       anchors.fill: parent
//       onMoveRequested: (dx, dy) => root.moveCursor(dx, dy)
//       onActivateRequested: root.activateCursor()
//       onCloseRequested: root.close()
//       onDeleteRequested: root.deleteSelected()
//       onTextKey: t => { if (t === "r") root.refresh() }
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
  id: catcher

  property bool blocked: false

  signal moveRequested(int dx, int dy)
  signal activateRequested()
  signal returnRequested()
  signal closeRequested()
  signal deleteRequested()
  signal tabRequested(int direction)
  signal textKey(string text)

  // Where each moving key points, by its key or by its letter.
  readonly property var _steps: ({
    [Qt.Key_Left]: [-1, 0],
    [Qt.Key_Right]: [1, 0],
    [Qt.Key_Up]: [0, -1],
    [Qt.Key_Down]: [0, 1],
    h: [-1, 0],
    l: [1, 0],
    k: [0, -1],
    j: [0, 1]
  })

  // Sends what <event> asks for; false for a key that asks for nothing here.
  function _answer(event) {
    const step = _steps[event.key] ?? _steps[event.text]
    if (step) {
      moveRequested(step[0], step[1])
      return true
    }
    switch (event.key) {
    case Qt.Key_Escape:
      closeRequested()
      return true
    case Qt.Key_Backtab:
      tabRequested(-1)
      return true
    case Qt.Key_Tab:
      tabRequested(event.modifiers & Qt.ShiftModifier ? -1 : 1)
      return true
    case Qt.Key_Return:
    case Qt.Key_Enter:
      returnRequested()
      activateRequested()
      return true
    case Qt.Key_Space:
      activateRequested()
      return true
    }
    if (event.text !== "x" && event.text !== "X") return false
    deleteRequested()
    return true
  }

  focus: true

  Keys.priority: Keys.BeforeItem
  Keys.onPressed: event => {
    if (blocked) return
    if (_answer(event)) event.accepted = true
    else if (event.text.length === 1) textKey(event.text)
  }
}
