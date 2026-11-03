import QtQuick
import QtQuick.Window
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

// Any number of choices from a list: a field like Dropdown's that opens a
// list of checkboxes under a filter, with a refresh button when the options
// come from a command. A click on a row checks or unchecks it.
//
// The options are <options> (strings, or { value, label, description }
// objects), followed by what <optionsCommand>, an argv list, prints: a JSON
// array when its output starts with "[", else one option a line. The command
// runs again as the list opens and on the refresh button.
//
// <values> is the choice, always a list of strings; changed() sends it on
// every change.
Item {
  id: root

  property string label: ""
  property var values: []
  property var options: []
  property var optionsCommand: []
  property string optionsCommandCwd: ""
  property string placeholderText: "Search..."
  property string emptyText: "No options"
  property string noSelectionText: "None selected"
  property string triggerLabel: ""
  property bool showLabel: true

  property color foreground: Commons.Color.popups.text
  property color background: Commons.Color.popups.background
  property color popupBorder: Commons.Color.popups.border
  property color accent: Commons.Color.accent
  readonly property var popupBorderSpec: Border.localOrSurfaceSpec("popups", "border", popupBorder, Commons.Color.popups.border, Style.normalBorderWidth)
  property string fontFamily: Style.font.family
  property int rowHeight: Style.spacing.controlHeight
  property int popupRowHeight: Style.spacing.popupRowHeight
  property int popupMinHeight: Style.spacing.searchablePopupMinHeight

  property bool hasCursor: false

  readonly property bool popupOpen: list.opened

  // The options from <options> and the command together, each as
  // { value, label, description }, without repeats or empty values.
  property var resolvedOptions: []
  property bool loadingOptions: false
  property string optionsError: ""

  // The options the filter lets through.
  property var filtered: resolvedOptions

  // Counts the command's runs, so the output of a run that has been
  // replaced is dropped, and a run that hangs is given up after
  // <refreshTimeoutMs>.
  property int refreshSeq: 0
  readonly property int refreshTimeoutMs: 6000

  signal changed(var values)
  signal hovered(bool isHovered)

  function open() { list.open() }
  function close() { list.close() }
  function toggle() {
    if (list.opened) list.close()
    else list.open()
  }

  function normalizeOption(o) {
    if (!o || typeof o !== "object") {
      var text = String(o)
      return { value: text, label: text, description: "" }
    }
    return {
      value: String(o.value),
      label: String(o.label !== undefined ? o.label : o.value),
      description: o.description ? String(o.description) : ""
    }
  }

  // A real array from anything with a numeric length but a string, which a
  // list from a QML schema can be without passing Array.isArray.
  function arrayFrom(v) {
    if (!v || typeof v === "string" || typeof v.length !== "number") return []
    var items = []
    for (var i = 0; i < v.length; i++) items.push(v[i])
    return items
  }

  function normalizeAll(arr) {
    var seen = {}
    var all = []
    arrayFrom(arr).forEach(function(o) {
      var option = normalizeOption(o)
      if (!option.value || seen[option.value]) return
      seen[option.value] = true
      all.push(option)
    })
    return all
  }

  function valueSet() {
    var set = {}
    arrayFrom(values).forEach(function(v) { set[String(v)] = true })
    return set
  }

  function isSelected(value) {
    return !!valueSet()[String(value)]
  }

  function toggleValue(value) {
    var text = String(value)
    var next = arrayFrom(values)
    var at = next.indexOf(text)
    if (at === -1) next.push(text)
    else next.splice(at, 1)
    root.values = next
    changed(next)
  }

  // The chosen options' labels, up to three; "<n> selected" past that, and
  // "" for none.
  function selectionLabel() {
    var chosen = arrayFrom(values)
    if (chosen.length === 0) return ""
    if (chosen.length > 3) return chosen.length + " selected"
    var labels = {}
    resolvedOptions.forEach(function(o) { labels[o.value] = o.label })
    return chosen.map(function(v) { return labels[String(v)] || String(v) }).join(", ")
  }

  function recomputeFiltered() {
    var query = filter.text.toLowerCase()
    if (!query) {
      root.filtered = resolvedOptions
      return
    }
    root.filtered = resolvedOptions.filter(function(o) {
      return o.label.toLowerCase().indexOf(query) !== -1
        || o.description.toLowerCase().indexOf(query) !== -1
        || o.value.toLowerCase().indexOf(query) !== -1
    })
  }

  function rebuildFromStatic() {
    root.resolvedOptions = normalizeAll(options)
    recomputeFiltered()
  }

  // The command's output as { options, error }. Output that starts with "["
  // must be JSON: broken, it is an error, not lines that would show as an
  // option of broken text. Anything else is one option a non-empty line.
  function parseCommandOutput(text) {
    var raw = String(text || "").trim()
    if (raw === "") return { options: [], error: "" }
    if (raw.charAt(0) === "[") {
      try {
        return { options: JSON.parse(raw), error: "" }
      } catch (e) {
        return { options: [], error: "Options command emitted invalid JSON" }
      }
    }
    var lines = raw.split(/\r?\n/).map(function(line) { return line.trim() })
    return { options: lines.filter(function(line) { return line !== "" }), error: "" }
  }

  function refresh() {
    var command = arrayFrom(optionsCommand)
    if (command.length === 0) {
      rebuildFromStatic()
      return
    }
    root.refreshSeq++
    root.loadingOptions = true
    root.optionsError = ""
    optionsProcess.command = command
    optionsProcess.workingDirectory = optionsCommandCwd
    optionsProcess.running = false
    optionsProcess.running = true
    refreshTimeout.restart()
  }

  implicitWidth: Style.spacing.searchableDropdownWidth
  implicitHeight: showLabel && label !== "" ? rowHeight + Style.spacing.huge : rowHeight

  onOptionsChanged: {
    if (arrayFrom(optionsCommand).length === 0) rebuildFromStatic()
  }
  onOptionsCommandChanged: refresh()
  Component.onCompleted: refresh()

  Timer {
    id: refreshTimeout
    interval: root.refreshTimeoutMs
    repeat: false
    onTriggered: {
      if (!root.loadingOptions) return
      optionsProcess.running = false
      root.loadingOptions = false
      root.optionsError = "Options command timed out"
    }
  }

  Process {
    id: optionsProcess

    // The run this process is, from <refreshSeq> as it started.
    property int seq: 0

    running: false
    command: []

    onRunningChanged: {
      if (running) seq = root.refreshSeq
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (optionsProcess.seq !== root.refreshSeq) return
        var result = root.parseCommandOutput(text)
        if (result.error) {
          // The static options stay, alone.
          root.optionsError = result.error
          root.resolvedOptions = root.normalizeAll(root.options)
        } else {
          root.resolvedOptions = root.normalizeAll(root.arrayFrom(root.options).concat(result.options))
        }
        root.recomputeFiltered()
        root.loadingOptions = false
        refreshTimeout.stop()
      }
    }

    onExited: function(exitCode, exitStatus) {
      if (seq !== root.refreshSeq) return
      refreshTimeout.stop()
      if (exitCode === 0) return
      root.loadingOptions = false
      root.optionsError = "Options command exited " + exitCode
    }
  }

  DropdownField {
    id: face
    anchors.fill: parent
    label: root.label
    showLabel: root.showLabel
    text: root.selectionLabel() || root.triggerLabel || root.noSelectionText
    textColor: root.selectionLabel() ? root.foreground : Qt.darker(root.foreground, 1.5)
    foreground: root.foreground
    accent: root.accent
    fontFamily: root.fontFamily
    rowHeight: root.rowHeight
    hasCursor: root.hasCursor
    popupItem: list
    onHovered: function(isHovered) { root.hovered(isHovered) }

    DropdownPopup {
      id: list

      property real _anchorX: 0
      property real _anchorY: 0
      property real _availableBelow: 0
      readonly property real _windowHeight: parent ? parent.height : 0
      readonly property real _idealContent: matches.contentHeight + Style.space(50)
      readonly property real _maxRowsHeight: root.popupRowHeight * 6 + 5 * Style.spacing.labelGap + Style.space(50)

      // Places the list under the field, in the window's coordinates, with
      // the room left below it. A binding on mapToItem would not follow a
      // scroll or a resize above the field, so this runs as the list opens
      // and whenever the field moves or changes size.
      function reposition() {
        if (!parent) return
        var at = face.field.mapToItem(parent, 0, face.field.height + Style.spacing.xxs)
        _anchorX = at.x
        _anchorY = at.y
        _availableBelow = Math.max(0, _windowHeight - _anchorY - Style.space(12))
      }

      // In the window's own content, out of reach of any parent that clips.
      parent: face.field.Window.window ? face.field.Window.window.contentItem : face.field
      x: _anchorX
      y: _anchorY
      width: face.field.width
      // No taller than the room below the field, even when that is less
      // than <popupMinHeight>: past the window's edge it would be cut off.
      implicitHeight: Math.min(_availableBelow, _idealContent, _maxRowsHeight)
      borderSpec: root.popupBorderSpec
      fill: root.background

      onOpened: {
        reposition()
        filter.text = ""
        root.refresh()
        root.recomputeFiltered()
        Qt.callLater(function() { filter.forceActiveFocus() })
      }
      onClosed: filter.text = ""

      Connections {
        target: face.field
        function onXChanged() { list.reposition() }
        function onYChanged() { list.reposition() }
        function onWidthChanged() { list.reposition() }
        function onHeightChanged() { list.reposition() }
      }

      contentItem: Column {
        spacing: 0

        Item {
          id: header
          width: parent.width
          height: root.popupRowHeight + Style.spacing.controlPaddingX

          Row {
            anchors.fill: parent
            anchors.margins: Style.spacing.md
            spacing: Style.spacing.rowGap

            TextField {
              id: filter
              width: parent.width - refreshButton.width - parent.spacing
              height: parent.height
              placeholderText: root.placeholderText
              foreground: root.foreground
              accent: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body

              onTextChanged: {
                root.recomputeFiltered()
                if (matches.count > 0) matches.currentIndex = 0
              }

              // Down goes to the first row, Return checks it.
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
                    matches.toggleCurrent()
                  }
                } else {
                  return
                }
                event.accepted = true
              }
            }

            BorderSurface {
              id: refreshButton
              visible: root.arrayFrom(root.optionsCommand).length > 0
              enabled: !root.loadingOptions
              width: parent.height
              height: parent.height
              radius: Style.cornerRadius
              color: refreshHover.hovered ? Style.hoverFillFor(root.foreground, root.accent) : Style.normalFillFor(root.foreground, root.accent)
              borderSpec: Border.controlSpec(refreshHover.hovered ? "hover-cursor" : "normal", root.foreground, root.accent)

              // While the command runs, the icon is an hourglass that turns.
              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: root.loadingOptions ? "󰦖" : "󰑐"
                color: root.foreground
                font { family: root.fontFamily; pixelSize: Style.font.body }

                RotationAnimator on rotation {
                  running: root.loadingOptions
                  from: 0
                  to: 360
                  duration: 800
                  loops: Animation.Infinite
                }
              }

              HoverHandler { id: refreshHover }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.refresh()
              }
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
            text: root.loadingOptions ? "Loading…" : root.optionsError !== "" ? root.optionsError : root.emptyText
            color: Qt.darker(root.foreground, 1.6)
            font { family: root.fontFamily; pixelSize: Style.font.body }
          }

          ListView {
            id: matches

            function toggleCurrent() {
              if (currentIndex >= 0 && currentIndex < root.filtered.length) root.toggleValue(root.filtered[currentIndex].value)
            }

            anchors.fill: parent
            spacing: Style.spacing.labelGap
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            model: root.filtered
            currentIndex: -1
            keyNavigationEnabled: false

            // Down stops at the last row; Up from the first goes back to
            // the filter. Return, Enter and Space check the row.
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
              } else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Space) {
                matches.toggleCurrent()
              } else {
                return
              }
              event.accepted = true
            }

            delegate: Rectangle {
              id: row

              required property var modelData
              required property int index
              readonly property bool selected: root.isSelected(modelData.value)
              readonly property bool lit: index === matches.currentIndex

              width: matches.width
              height: Math.max(root.popupRowHeight, line.implicitHeight + Style.spacing.rowPaddingX)
              color: lit ? Style.hoverFillFor(root.foreground, root.accent) : "transparent"

              Row {
                id: line
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.controlPaddingX
                anchors.rightMargin: Style.spacing.controlPaddingX
                spacing: Style.spacing.rowGap

                BorderSurface {
                  id: box
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(16)
                  height: Style.space(16)
                  radius: Math.max(2, Style.cornerRadius / 2)
                  color: row.selected ? Style.selectedFillFor(root.foreground, root.accent) : "transparent"
                  borderSpec: Border.controlSpec(row.selected ? "selected" : "normal", root.foreground, root.accent)

                  Text {
                    anchors.centerIn: parent
                    visible: row.selected
                    text: "✓"
                    color: Style.selectedStateColor(root.foreground, root.accent)
                    font { family: root.fontFamily; pixelSize: Math.round(box.height * 0.85); bold: true }
                  }
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - box.width - parent.spacing
                  spacing: Style.spacing.xxs

                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: row.modelData.label
                    color: row.lit ? Style.hoverStateColor(root.foreground, root.accent) : root.foreground
                    font { family: root.fontFamily; pixelSize: Style.font.body }
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    visible: text !== ""
                    textFormat: Text.PlainText
                    text: row.modelData.description
                    color: Qt.darker(root.foreground, 1.5)
                    font { family: root.fontFamily; pixelSize: Style.font.caption }
                    elide: Text.ElideRight
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: matches.currentIndex = row.index
                onClicked: root.toggleValue(row.modelData.value)
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
