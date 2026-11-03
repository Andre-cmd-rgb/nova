import QtQuick
import qs.Commons
import qs.Commons as Commons

// One choice from a list, in a field that opens a list under itself. The
// list is a surface of the theme's popups, in [popups]' background and
// border, rather than the platform's combo box. <options> are strings, or
// { value, label } objects showing the label and choosing the value, or
// both; changed() sends the value chosen.
//
// Keys: Tab comes to the field; Return, Enter, Space or Down opens it; in
// the list, Up and Down (or k and j) move and Return chooses; Escape closes.
// SearchableDropdown is this with a filter to type in.
Item {
  id: root

  property string label: ""
  property string value: ""
  property var options: []

  property color foreground: Commons.Color.popups.text
  property color background: Commons.Color.popups.background
  property color popupBorder: Commons.Color.popups.border
  property color accent: Commons.Color.accent
  readonly property var popupBorderSpec: Border.localOrSurfaceSpec("popups", "border", popupBorder, Commons.Color.popups.border, Style.normalBorderWidth)
  property string fontFamily: Style.font.family
  property int rowHeight: Style.spacing.controlHeight
  property int popupRowHeight: Style.spacing.popupRowHeight
  property bool showLabel: true
  // The panel cursor is on the field.
  property bool hasCursor: false

  // Whether the list is open, and so has the keys: a panel with its own
  // key catcher stands it down meanwhile, or j and k would move both.
  readonly property bool popupOpen: list.opened

  signal changed(string value)
  signal hovered(bool isHovered)

  function open() { list.open() }
  function close() { list.close() }
  function toggle() {
    if (list.opened) list.close()
    else list.open()
  }

  function optionValue(o) {
    return o && typeof o === "object" ? String(o.value) : String(o)
  }

  function optionLabel(o) {
    return o && typeof o === "object" ? String(o.label) : String(o)
  }

  // The chosen option's label; the value itself when no option has it.
  function currentLabel() {
    for (var i = 0; i < options.length; i++) {
      if (optionValue(options[i]) === value) return optionLabel(options[i])
    }
    return value
  }

  implicitWidth: Style.spacing.dropdownWidth
  implicitHeight: showLabel && label !== "" ? rowHeight + Style.spacing.huge : rowHeight

  DropdownField {
    id: face
    anchors.fill: parent
    label: root.label
    showLabel: root.showLabel
    text: root.currentLabel()
    foreground: root.foreground
    accent: root.accent
    fontFamily: root.fontFamily
    rowHeight: root.rowHeight
    hasCursor: root.hasCursor
    popupItem: list
    onHovered: function(isHovered) { root.hovered(isHovered) }

    DropdownPopup {
      id: list
      x: 0
      y: face.field.height + Style.spacing.xxs
      width: face.field.width
      // Eight rows at most; past that, the list scrolls.
      implicitHeight: Math.min(root.options.length * root.popupRowHeight + Math.max(0, root.options.length - 1) * Style.spacing.labelGap + Style.spacing.xxs,
        root.popupRowHeight * 8 + 7 * Style.spacing.labelGap + Style.spacing.xxs)
      borderSpec: root.popupBorderSpec
      fill: root.background

      // The list opens on the chosen option.
      onOpened: {
        rows.currentIndex = Math.max(0, rows.indexOfValue(root.value))
        rows.forceActiveFocus()
      }

      contentItem: ListView {
        id: rows

        function indexOfValue(v) {
          for (var i = 0; i < root.options.length; i++) {
            if (root.optionValue(root.options[i]) === v) return i
          }
          return -1
        }

        function selectCurrent() {
          if (currentIndex < 0 || currentIndex >= root.options.length) return
          var chosen = root.optionValue(root.options[currentIndex])
          root.value = chosen
          root.changed(chosen)
          list.close()
        }

        implicitHeight: contentHeight
        spacing: Style.spacing.labelGap
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.options
        currentIndex: -1

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          var key = event.key
          if (key === Qt.Key_Escape) list.close()
          else if (key === Qt.Key_Down || event.text === "j") rows.currentIndex = Math.min(root.options.length - 1, rows.currentIndex + 1)
          else if (key === Qt.Key_Up || event.text === "k") rows.currentIndex = Math.max(0, rows.currentIndex - 1)
          else if (key === Qt.Key_Return || key === Qt.Key_Enter) rows.selectCurrent()
          else return
          event.accepted = true
        }

        delegate: Rectangle {
          id: row

          required property var modelData
          required property int index
          readonly property bool lit: index === rows.currentIndex

          width: rows.width
          height: root.popupRowHeight
          color: lit ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"

          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.spacing.controlPaddingX
            anchors.rightMargin: Style.spacing.controlPaddingX
            textFormat: Text.PlainText
            text: root.optionLabel(row.modelData)
            color: row.lit ? Style.hoverStateColor(root.foreground, root.accent) : root.foreground
            font { family: root.fontFamily; pixelSize: Style.font.body }
            elide: Text.ElideRight
          }

          // The pointer moves the list's cursor; a click chooses.
          MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onPositionChanged: rows.currentIndex = row.index
            onClicked: rows.selectCurrent()
          }
        }
      }
    }
  }
}
