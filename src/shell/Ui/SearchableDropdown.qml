import QtQuick
import qs.Commons
import qs.Commons as Commons

// Dropdown with a filter: the list opens under a field to type in, and
// shows only the options whose label or description holds what is typed,
// in any case. For lists too long to read through. <options> are strings,
// or { value, label, description } objects; the filter empties as the list
// closes.
//
// Keys: Tab comes to the field; Return, Enter, Space or Down opens it, with
// the filter taking the typing. Down from the filter goes to the first
// match, Up from the first match back to the filter; Return chooses, Escape
// closes.
Item {
  id: root

  property string label: ""
  property string value: ""
  property var options: []
  property string placeholderText: "Search..."
  property string emptyText: "No matches"
  property string triggerLabel: ""

  property color foreground: Commons.Color.popups.text
  property color background: Commons.Color.popups.background
  property color popupBorder: Commons.Color.popups.border
  property color accent: Commons.Color.accent
  readonly property var popupBorderSpec: Border.localOrSurfaceSpec("popups", "border", popupBorder, Commons.Color.popups.border, Style.normalBorderWidth)
  property string fontFamily: Style.font.family
  property int rowHeight: Style.spacing.controlHeight
  property int popupRowHeight: Style.spacing.popupRowHeight
  property int popupMinHeight: Style.spacing.searchablePopupMinHeight
  property bool showLabel: true
  // The panel cursor is on the field.
  property bool hasCursor: false

  // Whether the list is open, and so has the keys, the typing included: a
  // panel with its own key catcher stands it down meanwhile.
  readonly property bool popupOpen: list.opened

  // The options the filter lets through.
  property var filtered: options

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

  function optionDescription(o) {
    return o && typeof o === "object" && o.description ? String(o.description) : ""
  }

  function currentLabel() {
    for (var i = 0; i < options.length; i++) {
      if (optionValue(options[i]) === value) return optionLabel(options[i])
    }
    return value
  }

  function recomputeFiltered() {
    var query = filter.text.toLowerCase()
    if (!query) {
      filtered = options
      return
    }
    var found = []
    for (var i = 0; i < options.length; i++) {
      var o = options[i]
      if (optionLabel(o).toLowerCase().indexOf(query) !== -1 || optionDescription(o).toLowerCase().indexOf(query) !== -1) found.push(o)
    }
    filtered = found
  }

  implicitWidth: Style.spacing.searchableDropdownWidth
  implicitHeight: showLabel && label !== "" ? rowHeight + Style.spacing.huge : rowHeight

  onOptionsChanged: recomputeFiltered()

  DropdownField {
    id: face
    anchors.fill: parent
    label: root.label
    showLabel: root.showLabel
    text: root.currentLabel() || root.triggerLabel || root.placeholderText
    textColor: root.currentLabel() || root.triggerLabel ? root.foreground : Qt.darker(root.foreground, 1.5)
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
      // Six rows at most under the filter, never less than <popupMinHeight>.
      implicitHeight: Math.max(root.popupMinHeight,
        Math.min(matches.contentHeight + Style.space(50), root.popupRowHeight * 6 + 5 * Style.spacing.labelGap + Style.space(50)))
      borderSpec: root.popupBorderSpec
      fill: root.background

      onOpened: {
        filter.text = ""
        root.recomputeFiltered()
        Qt.callLater(function() { filter.forceActiveFocus() })
      }
      onClosed: filter.text = ""

      contentItem: Column {
        spacing: 0

        Item {
          id: header
          width: parent.width
          height: root.popupRowHeight + Style.spacing.controlPaddingX

          TextField {
            id: filter
            anchors.fill: parent
            anchors.margins: Style.spacing.md
            placeholderText: root.placeholderText
            foreground: root.foreground
            accent: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body

            onTextChanged: {
              root.recomputeFiltered()
              if (matches.count > 0) matches.currentIndex = 0
            }

            // Down goes to the first match, Return takes it.
            Keys.onPressed: function(event) {
              var key = event.key
              if (key === Qt.Key_Escape) {
                list.close()
              } else if (key === Qt.Key_Down) {
                if (matches.count > 0) {
                  matches.currentIndex = 0
                  matches.forceActiveFocus()
                }
              } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
                if (matches.count > 0) {
                  matches.currentIndex = 0
                  matches.selectCurrent()
                }
              } else {
                return
              }
              event.accepted = true
            }
          }
        }

        Rectangle {
          width: parent.width
          height: 1
          color: Util.alpha(root.foreground, 0.10)
        }

        Item {
          width: parent.width
          height: list.height - header.height - Style.spacing.xxs - 1

          Text {
            anchors.centerIn: parent
            visible: matches.count === 0
            textFormat: Text.PlainText
            text: root.emptyText
            color: Qt.darker(root.foreground, 1.6)
            font { family: root.fontFamily; pixelSize: Style.font.body }
          }

          ListView {
            id: matches

            function selectCurrent() {
              if (currentIndex < 0 || currentIndex >= root.filtered.length) return
              var chosen = root.optionValue(root.filtered[currentIndex])
              root.value = chosen
              root.changed(chosen)
              list.close()
            }

            anchors.fill: parent
            spacing: Style.spacing.labelGap
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.filtered
            currentIndex: -1
            keyNavigationEnabled: false

            // Down stops at the last match; Up from the first goes back to
            // the filter.
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              var key = event.key
              if (key === Qt.Key_Escape) {
                list.close()
              } else if (key === Qt.Key_Down || event.text === "j") {
                if (matches.currentIndex < matches.count - 1) matches.currentIndex++
              } else if (key === Qt.Key_Up || event.text === "k") {
                if (matches.currentIndex <= 0) filter.forceActiveFocus()
                else matches.currentIndex--
              } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
                matches.selectCurrent()
              } else {
                return
              }
              event.accepted = true
            }

            delegate: Rectangle {
              id: row

              required property var modelData
              required property int index
              readonly property bool lit: index === matches.currentIndex

              width: matches.width
              height: Math.max(root.popupRowHeight, lines.implicitHeight + Style.spacing.rowPaddingX)
              color: lit ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"

              Column {
                id: lines
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.controlPaddingX
                anchors.rightMargin: Style.spacing.controlPaddingX
                spacing: Style.spacing.xxs

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.optionLabel(row.modelData)
                  color: row.lit ? Style.hoverStateColor(root.foreground, root.accent) : root.foreground
                  font { family: root.fontFamily; pixelSize: Style.font.body }
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  visible: text !== ""
                  textFormat: Text.PlainText
                  text: root.optionDescription(row.modelData)
                  color: Qt.darker(root.foreground, 1.5)
                  font { family: root.fontFamily; pixelSize: Style.font.caption }
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: matches.currentIndex = row.index
                onClicked: matches.selectCurrent()
              }
            }
          }

          // The touchpad scrolls the list as GTK does.
          TouchpadScroll {
            anchors.fill: matches
            flickable: matches
          }
        }
      }
    }
  }
}
