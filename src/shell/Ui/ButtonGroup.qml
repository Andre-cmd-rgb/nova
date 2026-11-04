import QtQuick
import qs.Commons
import qs.Commons as Commons

// A row of bordered buttons of which one is the chosen: the bar's position,
// a display's scale. A click sends changed() with the option's value. An
// option is a string, its own value and label, or a { value, label }
// object; one with no label shows its value.
//
// The row is a single Tab stop. With the focus, Left and Right (h and l)
// walk the buttons, from the chosen one, lighting each as the pointer
// would, and Return, Enter or Space takes the button walked to.
Row {
  id: group

  property var options: []
  property string value: ""
  property color foreground: Commons.Color.foreground
  property color background: Commons.Color.background
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.body
  property bool focusable: true

  // The button the keys have walked to; -1 while the row has no focus.
  property int _walked: -1

  signal changed(string value)

  function _isEntry(o) {
    return !!o && typeof o === "object"
  }

  function optionValue(o) {
    return String(_isEntry(o) ? o.value : o)
  }

  function optionLabel(o) {
    if (!_isEntry(o)) return String(o)
    return String(o.label !== undefined ? o.label : o.value)
  }

  // The chosen option's place; -1 when <value> is none of them.
  function selectedOptionIndex() {
    for (var i = 0; i < options.length; i++) {
      if (optionValue(options[i]) === value) return i
    }
    return -1
  }

  spacing: Style.spacing.md
  activeFocusOnTab: focusable

  onActiveFocusChanged: _walked = activeFocus ? Math.max(0, selectedOptionIndex()) : -1

  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function (event) {
    var key = event.key
    var from = Math.max(0, _walked)
    if (key === Qt.Key_Left || key === Qt.Key_H || event.text === "h") _walked = Math.max(0, from - 1)
    else if (key === Qt.Key_Right || key === Qt.Key_L || event.text === "l") _walked = Math.min(options.length - 1, from + 1)
    else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Space) {
      if (_walked >= 0 && _walked < options.length) changed(optionValue(options[_walked]))
    } else return
    event.accepted = true
  }

  Repeater {
    model: group.options

    // Every button keeps its border, so the row reads as separate choices.
    Button {
      required property var modelData
      required property int index

      text: group.optionLabel(modelData)
      selected: group.optionValue(modelData) === group.value
      hasCursor: group.activeFocus && index === group._walked
      bordered: true
      foreground: group.foreground
      background: group.background
      accent: group.accent
      fontFamily: group.fontFamily
      fontSize: group.fontSize

      onClicked: group.changed(group.optionValue(modelData))
    }
  }
}
