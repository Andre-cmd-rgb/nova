import QtQuick
import qs.Commons
import qs.Commons as Commons

// A row of bordered buttons of which one is chosen: the bar's position, a
// theme's preset. It sends changed() with the value of the option taken.
// <options> are strings, each its own label, or { value, label, icon,
// tooltip } objects, or both.
//
// The row is one stop for Tab, not one per button. With the focus on it,
// Left and Right (or h and l) walk the buttons, starting from the chosen
// one, and Return, Enter or Space takes the one walked to. A panel with its
// own cursor sets <cursorIndex> instead and follows the pointer through
// hovered(); either lights the button it is on.
Row {
  id: root

  property var options: []
  property string value: ""
  property color foreground: Commons.Color.foreground
  property color background: Commons.Color.background
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.body
  property bool focusable: true

  // The panel cursor's button; -1 for none.
  property int cursorIndex: -1

  // The button the keys have walked to while the row has the focus; -1
  // without it.
  property int _focusedIndex: -1

  signal changed(string value)
  signal hovered(int index, bool isHovered)

  function optionValue(o) {
    return o && typeof o === "object" ? String(o.value) : String(o)
  }

  function optionLabel(o) {
    return o && typeof o === "object" && o.label !== undefined ? String(o.label) : String(o)
  }

  function optionIcon(o) {
    return o && typeof o === "object" && o.icon ? String(o.icon) : ""
  }

  function optionTooltip(o) {
    return o && typeof o === "object" && o.tooltip ? String(o.tooltip) : ""
  }

  // The chosen option's place, -1 when <value> is none of them.
  function selectedOptionIndex() {
    for (var i = 0; i < options.length; i++) {
      if (optionValue(options[i]) === value) return i
    }
    return -1
  }

  function activateFocused() {
    if (_focusedIndex >= 0 && _focusedIndex < options.length) changed(optionValue(options[_focusedIndex]))
  }

  spacing: Style.spacing.md
  activeFocusOnTab: focusable

  onActiveFocusChanged: _focusedIndex = activeFocus ? Math.max(0, selectedOptionIndex()) : -1

  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) {
    var from = Math.max(0, _focusedIndex)
    if (event.key === Qt.Key_Left || event.key === Qt.Key_H || event.text === "h") {
      _focusedIndex = Math.max(0, from - 1)
    } else if (event.key === Qt.Key_Right || event.key === Qt.Key_L || event.text === "l") {
      _focusedIndex = Math.min(options.length - 1, from + 1)
    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
      activateFocused()
    } else {
      return
    }
    event.accepted = true
  }

  Repeater {
    model: root.options

    delegate: Button {
      required property var modelData
      required property int index

      text: root.optionLabel(modelData)
      iconText: root.optionIcon(modelData)
      tooltipText: root.optionTooltip(modelData)
      selected: root.optionValue(modelData) === root.value
      hasCursor: root.cursorIndex === index || (root.activeFocus && root._focusedIndex === index)
      // Every button has its border, so the row reads as separate choices.
      bordered: true
      foreground: root.foreground
      background: root.background
      accent: root.accent
      fontFamily: root.fontFamily
      fontSize: root.fontSize

      onClicked: root.changed(root.optionValue(modelData))
      onHovered: function(isHovered) { root.hovered(index, isHovered) }
    }
  }
}
