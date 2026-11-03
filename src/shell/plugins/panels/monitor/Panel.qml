import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// The display on the bar: one screen or two as its icon, and the wheel over
// it sets the brightness. A click opens the panel: the brightness, the size
// of text everywhere (nova-display-text-size), the focused display's scale,
// and, with two displays or more, each one to turn on or off. The pointer
// and the keys share one cursor through it all.
Panel {
  id: root
  moduleName: "nova.monitor"
  ipcTarget: "nova.monitor"

  // ---------------------------------------------------------------- state

  // What nova-monitor-state printed last.
  property bool hasBacklight: false
  property int brightness: 0
  property string focusedMonitor: ""
  property string currentScale: ""
  property var displays: []
  property int enabledCount: 0

  readonly property var focusedDisplay: displays.find(function(d) { return d && d.focused }) || null

  // The scales offered, as the focused display takes them.
  readonly property var scalePresets: ["1", "1.25", "1.6", "2", "3", "4"]
  readonly property var scaleValues: focusedDisplay
    ? Model.scalesFor(scalePresets, focusedDisplay.width, focusedDisplay.height) : scalePresets
  readonly property int activeScale: focusedDisplay
    ? Model.scaleIndex(scaleValues, currentScale, focusedDisplay.width, focusedDisplay.height) : -1

  // The scale a preset gives the focused display.
  function shownScale(preset) {
    return focusedDisplay ? Model.snapScale(preset, focusedDisplay.width, focusedDisplay.height) : Model.scaleText(preset)
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  // Once the whole answer is in, and the sections and rows shown have
  // followed it, the cursor is kept on one of them.
  function takeState(text) {
    var read = Model.readState(text)
    hasBacklight = read.hasBacklight
    brightness = read.brightness
    focusedMonitor = read.focused
    currentScale = read.scale
    displays = read.displays
    enabledCount = read.enabled
    clampCursor()
  }

  Component.onCompleted: refresh()

  // Read on opening and every 5 s while open; the bar's icon counts
  // Quickshell's screens and needs none of it.
  Timer { interval: 5000; running: root.opened; repeat: true; onTriggered: root.refresh() }

  Process {
    id: stateProc
    command: ["nova-monitor-state"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.takeState(text) }
  }

  // ---------------------------------------------------------------- brightness

  // The level asked for last, sent once the one before has been set.
  property int pendingBrightness: 0
  property bool brightnessQueued: false
  // Touchpad scrolling smaller than a notch, carried to the next event.
  property real wheelRest: 0

  function setBrightness(value) {
    var p = Model.percent(value)
    brightness = p
    pendingBrightness = p
    if (brightnessProc.running) {
      brightnessQueued = true
      return
    }
    brightnessQueued = false
    brightnessProc.command = ["nova-brightness-display", "--no-osd", "--monitor", focusedMonitor, p + "%"]
    brightnessProc.running = true
  }

  // While the slider is dragged, shown at once and set once it rests.
  function previewBrightness(value) {
    brightness = Model.percent(value)
    brightnessSettle.restart()
  }

  function showBrightnessOsd(p) {
    if (!bar || !bar.shell) return
    bar.shell.summon("nova.osd", JSON.stringify({ icon: "brightness", value: p }))
  }

  // `nova-shell nova.monitor brightness <percent>`.
  function brightnessIpc(value) {
    var text = String(value).trim()
    var n = Number(text)
    // Number("") is 0, which would turn the screen down as far as it goes.
    if (text === "" || !isFinite(n)) return "error: not a number: " + value
    setBrightness(n)
    return "got " + pendingBrightness
  }

  // `nova-shell nova.monitor state`.
  function stateIpc() {
    return JSON.stringify({
      brightness: brightness,
      brightnessAvailable: hasBacklight,
      focusedMonitor: focusedMonitor,
      scale: currentScale,
      displays: displays
    })
  }

  Timer { id: brightnessSettle; interval: 180; onTriggered: root.setBrightness(root.brightness) }

  // The level just written stands: it is not read back once set, which
  // could catch the backlight mid-change and show an empty answer as 0.
  // The poll while open picks up a change made elsewhere.
  Process {
    id: brightnessProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running && root.brightnessQueued) root.setBrightness(root.pendingBrightness)
  }

  // ---------------------------------------------------------------- displays

  // Hyprland's Lua config turns `hyprctl keyword` away, so a display goes on
  // or off through its hl.monitor call. The last one on stays on.
  function toggleDisplay(name, on) {
    if (!name) return
    if (on && enabledCount <= 1) return
    displayProc.command = ["hyprctl", "eval", Model.displayCall(name, on)]
    if (!displayProc.running) displayProc.running = true
  }

  function setScale(value) {
    displayProc.command = ["nova-hyprland-monitor-scaling", value]
    if (!displayProc.running) displayProc.running = true
  }

  Process {
    id: displayProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) root.refresh()
  }

  // ---------------------------------------------------------------- text size

  // The slider's stops, in pixels; nova-display-text-size takes any size
  // from 9 to 20.
  readonly property var textStops: [9, 10, 11, 12, 14, 16, 20]
  // The stop picked, shown until Style's base size has caught up with it;
  // -1 follows the base size.
  property int textPicked: -1
  readonly property int textIndex: textPicked >= 0 ? textPicked : Model.nearestStop(textStops, Style.font.baseSize)
  // The base size may be off the stops when set from the command line.
  readonly property int textPx: textPicked >= 0 ? textStops[textPicked] : Style.font.baseSize
  // A size asked for while one is being written waits for it; of a quick
  // run of them, only the last.
  property int textQueued: 0
  // A new text size reflows the panel under a still pointer, and the hover
  // that follows must not pull the cursor off the slider. Set for a moment.
  property bool reflowing: false

  function markReflowing() {
    reflowing = true
    reflowSettle.restart()
  }

  function setTextSize(px) {
    if (textProc.running) {
      textQueued = px
      return
    }
    textProc.command = ["nova-display-text-size", String(px)]
    textProc.running = true
  }

  function stepTextSize(steps) {
    var i = Math.max(0, Math.min(textStops.length - 1, textIndex + steps))
    markReflowing()
    textPicked = i
    setTextSize(textStops[i])
  }

  // Style reads the new size from the file nova-display-text-size writes.
  Process {
    id: textProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running || root.textQueued === 0) return
      var px = root.textQueued
      root.textQueued = 0
      root.setTextSize(px)
    }
  }

  Timer { id: reflowSettle; interval: 300; onTriggered: root.reflowing = false }

  Connections {
    target: Style
    function onFontBaseSizeChanged() {
      root.markReflowing()
      if (root.textPicked >= 0 && Model.nearestStop(root.textStops, Style.font.baseSize) === root.textPicked)
        root.textPicked = -1
    }
  }

  // ---------------------------------------------------------------- cursor

  // Shown once the pointer or a key has moved it; it starts on the
  // brightness, or on the first scale without a backlight.
  property bool cursorActive: false
  property string focusSection: "scale"
  property int selectedIndex: 0
  readonly property var sections: Model.sections(hasBacklight, displays.length)
  readonly property var counts: ({ scale: scaleValues.length, monitors: displays.length })

  // Section first, then index, as every change of the cursor goes.
  function go(next) {
    focusSection = next.section
    selectedIndex = next.index
  }

  function point(section, index) {
    if (reflowing) return
    cursorActive = true
    go(Model.at(section, index))
  }

  function moveCursor(delta) {
    go(Model.move(Model.at(focusSection, selectedIndex), delta, sections, counts))
  }

  // h and l: the brightness in steps of 5, the text size a stop, the scale
  // the next preset.
  function nudge(delta) {
    if (focusSection === "brightness") {
      if (hasBacklight) setBrightness(brightness + delta * 5)
    } else if (focusSection === "textsize") {
      stepTextSize(delta)
    } else if (focusSection === "scale") {
      selectedIndex = Model.along(selectedIndex, delta, scaleValues.length)
    }
  }

  function activateCursor() {
    if (focusSection === "scale" && selectedIndex >= 0 && selectedIndex < scaleValues.length) {
      setScale(scaleValues[selectedIndex])
    } else if (focusSection === "monitors" && selectedIndex >= 0 && selectedIndex < displays.length) {
      var d = displays[selectedIndex]
      if (d) toggleDisplay(d.name, d.enabled)
    }
  }

  function clampCursor() {
    go(Model.clamp(Model.at(focusSection, selectedIndex), sections, counts))
  }

  // The row the cursor lands on scrolled into view, 6 px clear of the edge,
  // when the displays make the card taller than it may be.
  function ensureCursorVisible(item) {
    var flick = scrollArea.contentItem
    var top = item.mapToItem(flick.contentItem, 0, 0).y
    var bottom = top + item.height
    if (top < flick.contentY + 6) flick.contentY = Math.max(0, top - 6)
    else if (bottom > flick.contentY + flick.height - 6) flick.contentY = bottom + 6 - flick.height
  }

  onOpenedChanged: {
    if (!opened) return
    refresh()
    go(hasBacklight ? Model.at("brightness", -1) : Model.at("scale", 0))
    cursorActive = false
  }

  // ---------------------------------------------------------------- bar

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Quickshell.screens.length > 1 ? "󰍺" : "󰍹"
    onPressed: root.toggle()
    onWheelMoved: function(delta) {
      if (!root.hasBacklight) return
      var wheel = Util.wheelSteps(root.wheelRest, delta)
      root.wheelRest = wheel.remainder
      if (wheel.steps === 0) return
      root.setBrightness(root.brightness + wheel.steps * 5)
      root.showBrightnessOsd(root.brightness)
    }
  }

  // ---------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(560))

    // j and k walk the sections and the displays; h and l move a slider or
    // along the scales. The first key only shows the cursor.
    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) root.cursorActive = true
        else if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.nudge(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: content.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        // It scrolls only when there is more than fits.
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: content.implicitHeight > scrollArea.height
        }

        Column {
          id: content
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          PanelHero {
            title: "Display"
            meta: root.hasBacklight ? Model.mood(brightnessPart.slider.dragging ? brightnessPart.slider.liveValue : root.brightness)
              : "Fixed brightness"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.displays.length > 1 ? "󰍺" : "󰍹"
                color: root.bar.foreground
                font { family: root.bar.fontFamily; pixelSize: Style.font.display }
              }
            }
          }

          PanelSeparator {
            visible: root.hasBacklight
            foreground: root.bar.foreground
          }

          SliderPart {
            id: brightnessPart
            visible: root.hasBacklight
            section: "brightness"
            title: "BRIGHTNESS"
            reading: Math.round(slider.dragging ? slider.liveValue : root.brightness) + "%"
            slider.minimum: 1
            slider.maximum: 100
            slider.value: root.brightness
            onMoved: function(v) { root.previewBrightness(v) }
            onReleased: function(v) {
              brightnessSettle.stop()
              root.setBrightness(v)
            }
          }

          PanelSeparator { foreground: root.bar.foreground }

          SliderPart {
            section: "textsize"
            title: "TEXT SIZE"
            reading: (slider.dragging ? root.textStops[Math.round(slider.liveValue)] : root.textPx) + "px"
            slider.minimum: 0
            slider.maximum: root.textStops.length - 1
            slider.tickCount: root.textStops.length
            slider.value: root.textIndex
            onReleased: function(v) { root.setTextSize(root.textStops[Math.round(v)]) }
          }

          PanelSeparator { foreground: root.bar.foreground }

          Column {
            width: parent.width
            spacing: Style.space(10)

            // The scale is the focused display's, named when there are more.
            Heading {
              title: "SCALE"
              reading: root.focusedMonitor
              readingShown: root.focusedMonitor !== "" && root.enabledCount > 1
            }

            Row {
              id: scaleRow
              width: parent.width
              spacing: Style.spacing.xs

              Repeater {
                model: root.scaleValues

                Button {
                  required property string modelData
                  required property int index

                  width: (scaleRow.width - scaleRow.spacing * (root.scaleValues.length - 1)) / root.scaleValues.length
                  text: root.shownScale(modelData) + "x"
                  fontSize: Style.font.caption
                  foreground: root.bar.foreground
                  fontFamily: root.bar.fontFamily
                  horizontalPadding: Style.spacing.sm
                  verticalPadding: Style.spacing.controlPaddingY
                  bordered: true
                  active: root.activeScale === index
                  hasCursor: root.cursorActive && root.focusSection === "scale" && root.selectedIndex === index
                  onClicked: root.setScale(modelData)
                  onHovered: function(on) { if (on) root.point("scale", index) }
                }
              }
            }
          }

          PanelSeparator {
            visible: root.displays.length > 1
            foreground: root.bar.foreground
          }

          Column {
            visible: root.displays.length > 1
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "DISPLAYS"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            Repeater {
              model: root.displays
              DisplayRow { width: content.width }
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  // A section's name, and what it is set to at the far end.
  component Heading: Item {
    property alias title: label.text
    property alias reading: readout.text
    property alias readingShown: readout.visible

    width: parent.width
    implicitHeight: Math.max(label.implicitHeight, readout.implicitHeight)

    PanelSectionHeader {
      id: label
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      foreground: root.bar.foreground
      fontFamily: root.bar.fontFamily
    }

    Text {
      id: readout
      anchors { right: parent.right; rightMargin: Style.space(6); verticalCenter: parent.verticalCenter }
      textFormat: Text.PlainText
      color: Qt.darker(root.bar.foreground, 1.4)
      font { family: root.bar.fontFamily; pixelSize: Style.font.caption; bold: true }
    }
  }

  // A slider under its heading. The cursor lights the slider's row as a
  // whole, at index -1 of <section>.
  component SliderPart: Column {
    id: part
    property string section
    property alias title: heading.title
    property alias reading: heading.reading
    readonly property alias slider: knob
    signal moved(real value)
    signal released(real value)

    width: parent.width
    spacing: Style.space(6)

    Heading { id: heading }

    CursorSurface {
      id: row
      width: parent.width
      height: knob.implicitHeight + Style.spacing.controlGap
      hasCursor: root.cursorActive && root.focusSection === part.section && root.selectedIndex === -1
      onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(row)
      foreground: root.bar.foreground

      PanelSlider {
        id: knob
        anchors { fill: parent; leftMargin: Style.space(6); rightMargin: Style.space(6) }
        bar: root.bar
        step: 1
        integer: true
        onMoved: function(v) { part.moved(v) }
        onReleased: function(v) { part.released(v) }
      }

      HoverHandler {
        onHoveredChanged: if (hovered) root.point(part.section, -1)
      }
    }
  }

  // A display: its name, "focused" on the focused one, and a tick while it
  // is on. A click turns it off or on; the last one on is dimmed and stays.
  component DisplayRow: CursorSurface {
    id: line
    required property var modelData
    required property int index
    readonly property bool canToggle: modelData && (!modelData.enabled || root.enabledCount > 1)

    implicitHeight: inner.implicitHeight + Style.spacing.xl
    hasCursor: root.cursorActive && root.focusSection === "monitors" && root.selectedIndex === index
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(line)
    current: modelData && modelData.focused
    foreground: root.bar.foreground
    opacity: canToggle ? 1.0 : 0.45

    Row {
      id: inner
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.space(6); rightMargin: Style.space(6) }
      spacing: Style.space(8)

      Text {
        id: glyph
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        text: "󰍹"
        color: root.bar.foreground
        font { family: root.bar.fontFamily; pixelSize: Style.font.title }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - glyph.width - tick.width - Style.space(16)
        textFormat: Text.PlainText
        text: line.modelData.name + (line.modelData.focused ? " · focused" : "")
        color: root.bar.foreground
        font { family: root.bar.fontFamily; pixelSize: Style.font.body }
        elide: Text.ElideRight
      }

      Text {
        id: tick
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(14)
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        text: line.modelData.enabled ? "󰄬" : ""
        color: root.bar.foreground
        font { family: root.bar.fontFamily; pixelSize: Style.font.subtitle }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: line.canToggle ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) root.point("monitors", line.index)
      onClicked: if (line.canToggle) root.toggleDisplay(line.modelData.name, line.modelData.enabled)
    }
  }
}
