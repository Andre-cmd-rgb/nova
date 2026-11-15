import QtQuick
import qs.Commons
import qs.Commons as Commons
import "Options.js" as Options

// A row of bordered buttons, one of them the chosen: the bar's edge, a
// display's scale. <options> as Options.js reads them; <value> is the
// caller's to set, and a click only sends changed() with the option's value.
//
// The row is one Tab stop (unless <tabStop> is false). With the focus, Left
// and Right, or h and l, walk along the buttons from the chosen one, each
// lit as the pointer would light it, and Return, Enter or Space takes the one
// walked to.
Row {
  id: group

  property var options: []
  property string value: ""
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family
  property real fontSize: Style.font.body
  property bool tabStop: true

  // Where the keys have walked; -1 while the row has no focus.
  property int _at: -1

  signal changed(string value)

  function _walk(step) {
    _at = Math.min(options.length - 1, Math.max(0, Math.max(0, _at) + step))
  }

  spacing: Style.spacing.md
  activeFocusOnTab: tabStop
  onActiveFocusChanged: _at = activeFocus ? Math.max(0, Options.find(options, value)) : -1

  Keys.priority: Keys.BeforeItem
  Keys.onPressed: event => {
    if (event.key === Qt.Key_Left || event.key === Qt.Key_H || event.text === "h") _walk(-1)
    else if (event.key === Qt.Key_Right || event.key === Qt.Key_L || event.text === "l") _walk(1)
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
      if (_at >= 0 && _at < options.length) changed(Options.valueOf(options[_at]))
    } else return
    event.accepted = true
  }

  Repeater {
    model: group.options

    // Each keeps its border, so that the row reads as separate choices.
    Button {
      required property var modelData
      required property int index

      text: Options.labelOf(modelData)
      selected: Options.valueOf(modelData) === group.value
      hasCursor: group.activeFocus && index === group._at
      bordered: true
      restColor: Commons.Color.background
      foreground: group.foreground
      accent: group.accent
      fontFamily: group.fontFamily
      fontSize: group.fontSize

      onClicked: group.changed(Options.valueOf(modelData))
    }
  }
}
