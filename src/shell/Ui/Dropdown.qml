import QtQuick
import qs.Commons
import qs.Commons as Commons

// One choice from a list: a field showing the chosen option, that opens
// the list below itself. The list is a DropdownPopup in
// [popups]' background and border, not the platform's combo box. <options>
// are strings, or { value, label } objects that show the label and choose
// the value, or both; one with no label shows its value.
//
// <value> is the owner's to set, as a ButtonGroup's is: a choice only sends
// changed() with the value chosen, so a field bound to a setting keeps
// following it, and shows what the setting holds when a change fails.
//
// The field is a Tab stop; Return, Enter, Space or Down opens or closes the
// list, Escape closes it, and so does a click. Its face is in the focus
// state with the focus, in hover-cursor under the pointer, else normal. In
// the list, Up and Down (k and j) move, Return and Enter choose, Escape
// closes.
Item {
  id: dropdown

  property string value: ""
  property var options: []
  property color foreground: Commons.Color.popups.text
  property color background: Commons.Color.popups.background
  property color popupBorder: Commons.Color.popups.border
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family
  property int rowHeight: Style.spacing.controlHeight
  property int popupRowHeight: Style.spacing.popupRowHeight

  readonly property var popupBorderSpec: Border.popupSpec(popupBorder, Style.normalBorderWidth)

  signal changed(string value)

  function open() { list.open() }
  function close() { list.close() }
  function toggle() { list.opened ? list.close() : list.open() }

  function optionValue(o) {
    return o && typeof o === "object" ? String(o.value) : String(o)
  }

  function optionLabel(o) {
    if (!o || typeof o !== "object") return String(o)
    return String(o.label !== undefined ? o.label : o.value)
  }

  // The chosen option's label, or the value itself when no option has it.
  function currentLabel() {
    var at = indexOf(value)
    return at < 0 ? value : optionLabel(options[at])
  }

  function indexOf(wanted) {
    for (var i = 0; i < options.length; i++) {
      if (optionValue(options[i]) === wanted) return i
    }
    return -1
  }

  // Sends the option at <index> to the owner, and closes the list.
  function choose(index) {
    if (index < 0 || index >= options.length) return
    changed(optionValue(options[index]))
    list.close()
  }

  implicitWidth: Style.spacing.dropdownWidth
  implicitHeight: rowHeight

  ControlFace {
    id: field

    readonly property string _state: activeFocus ? "focus" : hover.hovered ? "hover-cursor" : "normal"

    width: parent.width
    height: dropdown.rowHeight
    radius: Style.cornerRadius
    tint: dropdown.foreground
    tintAccent: dropdown.accent
    fillState: _state
    edgeState: _state

    activeFocusOnTab: true
    Keys.onPressed: function (event) {
      switch (event.key) {
      case Qt.Key_Return:
      case Qt.Key_Enter:
      case Qt.Key_Space:
      case Qt.Key_Down:
        dropdown.toggle()
        break
      case Qt.Key_Escape:
        if (!list.opened) return
        list.close()
        break
      default:
        return
      }
      event.accepted = true
    }

    HoverHandler {
      id: hover
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      x: field.borderLeft + Style.spacing.controlPaddingX
      width: chevron.x - x - field.borderRight - Style.spacing.md
      textFormat: Text.PlainText
      text: dropdown.currentLabel()
      color: dropdown.foreground
      font.family: dropdown.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    Text {
      id: chevron
      anchors.verticalCenter: parent.verticalCenter
      x: field.width - width - field.borderRight - Style.spacing.controlGap
      text: "\u{F0140}"
      color: Qt.darker(dropdown.foreground, 1.2)
      font.family: dropdown.fontFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: {
        field.forceActiveFocus()
        dropdown.toggle()
      }
    }

    DropdownPopup {
      id: list
      owner: dropdown
      y: field.height + Style.spacing.xxs
      width: field.width
    }
  }
}
