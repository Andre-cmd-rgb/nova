import QtQuick

// The keyboard of a bar panel, wrapped round the panel's content. What every
// panel does with a key is done here: Escape closes <panel>, and Tab and
// Shift+Tab hand over to the panel beside it on the bar. The rest is sent on
// for the panel to decide, as it keeps its own cursor:
//   stepped(dx, dy) an arrow, or h, j, k, l
//   activated(key) Return, Enter or Space (the key, for a panel that tells
//                  them apart)
//   erased()       x
//   struck(text)   any other character, which also goes on to the item with
//                  the focus
//
// It hears the keys before anything inside it, the item with the focus too,
// so that Up and Down move the panel's cursor rather than scroll a list. A
// panel with a field to type in (network's passphrase) sets <typing> while
// the field has the focus, and every key goes to the field.
Item {
  id: keys

  property Item panel: null
  property bool typing: false

  signal stepped(int dx, int dy)
  signal activated(int key)
  signal erased()
  signal struck(string text)

  // h, j, k and l, as the arrows.
  readonly property var _vim: ({ h: [-1, 0], j: [0, 1], k: [0, -1], l: [1, 0] })

  focus: true
  Keys.priority: Keys.BeforeItem
  Keys.onPressed: event => {
    if (typing) return
    event.accepted = true
    const vim = _vim[event.text]
    switch (event.key) {
    case Qt.Key_Escape: if (panel) panel.close(); return
    case Qt.Key_Backtab: if (panel) panel.switchPanel(-1); return
    case Qt.Key_Tab: if (panel) panel.switchPanel(event.modifiers & Qt.ShiftModifier ? -1 : 1); return
    case Qt.Key_Return:
    case Qt.Key_Enter:
    case Qt.Key_Space: activated(event.key); return
    case Qt.Key_Left: stepped(-1, 0); return
    case Qt.Key_Right: stepped(1, 0); return
    case Qt.Key_Up: stepped(0, -1); return
    case Qt.Key_Down: stepped(0, 1); return
    }
    if (vim) stepped(vim[0], vim[1])
    else if (event.text === "x" || event.text === "X") erased()
    else {
      event.accepted = false
      if (event.text.length === 1) struck(event.text)
    }
  }
}
