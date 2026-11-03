import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The display on the bar: one screen or two as its icon, and the wheel over
// it sets the brightness. A click opens the panel: the brightness, the size
// of text everywhere (nova-display-text-size), the focused display's scale,
// and, with two displays or more, each one to turn on or off. The pointer
// and the keys share one cursor through it all.
Panel {
  id: display
  moduleName: "nova.monitor"
  ipcTarget: "nova.monitor"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // -------------------------------------------------------------- the state

  // nova-monitor-state's last answer. The brightness shown is the panel's
  // own from when it sets one to the next answer.
  property var told: Model.readState("")
  property int level: 0
  readonly property bool lit: told.hasBacklight
  readonly property string focusName: told.focused
  readonly property var outputs: told.displays
  readonly property int lightCount: told.enabled
  readonly property var focusedOutput: outputs.find(output => output && output.focused) || null

  // The scales offered, as the focused display takes them.
  readonly property var presets: ["1", "1.25", "1.6", "2", "3", "4"]
  readonly property var scales: focusedOutput
    ? Model.scalesFor(presets, focusedOutput.width, focusedOutput.height) : presets
  readonly property int scaleInUse: focusedOutput
    ? Model.scaleIndex(scales, told.scale, focusedOutput.width, focusedOutput.height) : -1

  // A preset as the focused display ends up at it.
  function scaleLabel(preset) {
    return (focusedOutput ? Model.snapScale(preset, focusedOutput.width, focusedOutput.height) : Model.scaleText(preset)) + "x"
  }

  function refresh() {
    probe.ask()
  }

  function take(text) {
    const read = Model.readState(text)
    level = read.brightness
    told = read
    keepCursor()
  }

  Component.onCompleted: refresh()

  // Read when the panel opens and every 5 s while it is open; the bar's
  // icon counts Quickshell's screens and needs none of it.
  Timer { interval: 5000; running: display.opened; repeat: true; onTriggered: display.refresh() }

  Reader {
    id: probe
    command: ["nova-monitor-state"]
    onAnswered: text => display.take(text)
  }

  // --------------------------------------------------------- the brightness

  // Touchpad scrolling smaller than a notch, carried to the next event.
  property real wheelRest: 0
  // Where the brightness slider's knob is while it is held.
  readonly property real shownLevel: lightRow.held ? lightRow.knobAt : level

  // The level set stands: it is not read back once set, which could catch
  // the backlight mid-change and show an empty answer as 0. The poll while
  // open picks up a change made elsewhere.
  function setLevel(value) {
    const percent = Model.percent(value)
    level = percent
    dimmer.ask(percent)
  }

  // While the slider is dragged, shown at once and set once it rests.
  function previewLevel(value) {
    level = Model.percent(value)
    rest.restart()
  }

  Timer { id: rest; interval: 180; onTriggered: display.setLevel(display.level) }

  Queue {
    id: dimmer
    onTurn: percent => {
      display.level = percent
      dimmer.exec(["nova-brightness-display", "--no-osd", "--monitor", display.focusName, percent + "%"])
    }
  }

  // `nova-shell nova.monitor brightness <percent>`.
  function brightnessIpc(value) {
    const text = String(value).trim()
    // Number("") is 0, which would turn the screen down as far as it goes.
    if (text === "" || !isFinite(Number(text))) return "error: not a number: " + value
    setLevel(Number(text))
    return "got " + level
  }

  // `nova-shell nova.monitor state`.
  function stateIpc() {
    return JSON.stringify({ brightness: level, brightnessAvailable: lit, focusedMonitor: focusName, scale: told.scale, displays: outputs })
  }

  // ---------------------------------------------------------- the text size

  // The slider's stops, in pixels; nova-display-text-size takes any size
  // from 9 to 20.
  readonly property var sizes: [9, 10, 11, 12, 14, 16, 20]
  // The stop a key moved to, shown until Style's base size has caught up
  // with it; -1 while the slider follows the base size.
  property int sizeHeld: -1
  readonly property int sizeStop: sizeHeld >= 0 ? sizeHeld : Model.nearestStop(sizes, Style.font.baseSize)
  // The base size may be off the stops when set from the command line.
  readonly property int sizePx: sizeHeld >= 0 ? sizes[sizeHeld] : Style.font.baseSize
  readonly property int baseSize: Style.fontBaseSize
  // A new size reflows the panel under a still pointer, and the hover that
  // follows must not pull the cursor off the slider: for 300 ms the pointer
  // moves no cursor.
  property bool reflowing: false

  function holdPointer() {
    reflowing = true
    pointerBack.restart()
  }

  function stepSize(steps) {
    const stop = Math.max(0, Math.min(sizes.length - 1, sizeStop + steps))
    holdPointer()
    sizeHeld = stop
    sizer.ask(sizes[stop])
  }

  onBaseSizeChanged: {
    holdPointer()
    if (Model.nearestStop(sizes, baseSize) === sizeHeld) sizeHeld = -1
  }

  Timer { id: pointerBack; interval: 300; onTriggered: display.reflowing = false }

  // Style reads the new size from the file nova-display-text-size writes.
  Queue {
    id: sizer
    onTurn: px => sizer.exec(["nova-display-text-size", String(px)])
  }

  // ------------------------------------------------------------ the displays

  // Hyprland's Lua config turns `hyprctl keyword` away, so a display goes on
  // or off through its hl.monitor call. The last one on stays on.
  function flip(output) {
    if (!output?.name || (output.enabled && lightCount <= 1)) return
    change(["hyprctl", "eval", Model.displayCall(output.name, output.enabled)])
  }

  function useScale(value) {
    change(["nova-hyprland-monitor-scaling", value])
  }

  // One change at a time; the state is read again after each.
  function change(command) {
    if (!changer.running) changer.exec(command)
  }

  Process {
    id: changer
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running) display.refresh()
  }

  // -------------------------------------------------------------- the cursor

  // A section and a row in it, shown once a key or the pointer has moved
  // it. A slider is row -1 of its section.
  property bool cursorShown: false
  property string cursorSection: "scale"
  property int cursorRow: 0
  readonly property var shownSections: Model.sections(lit, outputs.length)
  readonly property var rowCounts: ({ scale: scales.length, monitors: outputs.length })

  function lights(section, row) {
    return cursorShown && cursorSection === section && cursorRow === row
  }

  // The section first, then the row, as every move of the cursor goes.
  function place(spot) {
    cursorSection = spot.section
    cursorRow = spot.index
  }

  function pointAt(section, row) {
    if (reflowing) return
    cursorShown = true
    place(Model.at(section, row))
  }

  // Once the whole answer is in, and the sections and rows shown have
  // followed it, the cursor is kept on one of them.
  function keepCursor() {
    place(Model.clamp(Model.at(cursorSection, cursorRow), shownSections, rowCounts))
  }

  // The first key only shows the cursor. Then j and k walk the sections and
  // the displays; h and l move the brightness by 5, the text size a stop,
  // or the cursor along the scales.
  function steer(dx, dy) {
    if (!cursorShown) cursorShown = true
    else if (dy !== 0) place(Model.move(Model.at(cursorSection, cursorRow), dy, shownSections, rowCounts))
    else if (dx !== 0) slide(dx)
  }

  function slide(dx) {
    if (cursorSection === "brightness") {
      if (lit) setLevel(level + dx * 5)
    } else if (cursorSection === "textsize") {
      stepSize(dx)
    } else if (cursorSection === "scale") {
      cursorRow = Model.along(cursorRow, dx, scales.length)
    }
  }

  function pick() {
    if (cursorSection === "monitors") flip(outputs[cursorRow])
    else if (cursorSection === "scale" && cursorRow in scales) useScale(scales[cursorRow])
  }

  // The row the cursor lands on scrolled into view, 6 px clear of the edge,
  // when the displays make the card taller than it may be.
  function reveal(item) {
    const list = scroller.contentItem
    const top = item.mapToItem(list.contentItem, 0, 0).y
    const bottom = top + item.height
    if (top < list.contentY + 6) list.contentY = Math.max(0, top - 6)
    else if (bottom > list.contentY + list.height - 6) list.contentY = bottom + 6 - list.height
  }

  // Each opening reads the state again and puts the cursor, hidden, on the
  // brightness, or on the first scale without a backlight.
  function open() {
    if (opened) return
    controller.show()
    refresh()
    place(lit ? Model.at("brightness", -1) : Model.at("scale", 0))
    cursorShown = false
  }

  // ----------------------------------------------------------------- the bar

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: display.bar
    text: Model.screensIcon(Quickshell.screens.length)
    onPressed: display.toggle()
    // The wheel steps the brightness by 5, and the OSD shows it.
    onWheelMoved: delta => {
      if (!display.lit) return
      const turned = Util.wheelSteps(display.wheelRest, delta)
      display.wheelRest = turned.remainder
      if (turned.steps === 0) return
      display.setLevel(display.level + turned.steps * 5)
      display.bar?.shell?.summon("nova.osd", JSON.stringify({ icon: "brightness", value: display.level }))
    }
  }

  // --------------------------------------------------------------- the panel

  KeyboardPanel {
    id: popup
    anchorItem: button
    owner: display
    bar: display.bar
    open: display.opened
    focusTarget: keys
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(sheet.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onMoveRequested: (dx, dy) => display.steer(dx, dy)
      onActivateRequested: if (display.cursorShown) display.pick()
      onCloseRequested: display.close()
      onTabRequested: direction => display.switchPanel(direction)

      ScrollView {
        id: scroller
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: sheet.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        // It scrolls only when there is more than fits.
        Binding { target: scroller.contentItem; property: "interactive"; value: sheet.implicitHeight > scroller.height }

        Column {
          id: sheet
          width: scroller.availableWidth
          spacing: Style.space(14)

          PanelHero {
            title: "Display"
            meta: display.lit ? Model.mood(display.shownLevel) : "Fixed brightness"
            foreground: display.bar.foreground
            fontFamily: display.bar.fontFamily
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: Model.screensIcon(display.outputs.length)
                color: display.bar.foreground
                font { family: display.bar.fontFamily; pixelSize: Style.font.display }
              }
            }
          }

          PanelSeparator {
            visible: display.lit
            foreground: display.bar.foreground
          }

          Section {
            visible: display.lit
            spacing: Style.space(6)
            title: "BRIGHTNESS"
            reading: Math.round(display.shownLevel) + "%"

            SliderRow {
              id: lightRow
              section: "brightness"
              minimum: 1
              maximum: 100
              value: display.level
              onDragged: value => display.previewLevel(value)
              onLetGo: value => {
                rest.stop()
                display.setLevel(value)
              }
            }
          }

          PanelSeparator { foreground: display.bar.foreground }

          Section {
            spacing: Style.space(6)
            title: "TEXT SIZE"
            reading: (sizeRow.held ? display.sizes[Math.round(sizeRow.knobAt)] : display.sizePx) + "px"

            SliderRow {
              id: sizeRow
              section: "textsize"
              minimum: 0
              maximum: display.sizes.length - 1
              tickCount: display.sizes.length
              value: display.sizeStop
              onLetGo: value => sizer.ask(display.sizes[Math.round(value)])
            }
          }

          PanelSeparator { foreground: display.bar.foreground }

          // The scale is the focused display's, named when there are more.
          Section {
            spacing: Style.space(10)
            title: "SCALE"
            reading: display.focusName
            readingShown: display.focusName !== "" && display.lightCount > 1

            Row {
              id: pills
              width: parent.width
              spacing: Style.spacing.xs

              Repeater {
                model: display.scales

                Button {
                  required property string modelData
                  required property int index

                  width: (pills.width - pills.spacing * (display.scales.length - 1)) / display.scales.length
                  text: display.scaleLabel(modelData)
                  fontSize: Style.font.caption
                  foreground: display.bar.foreground
                  fontFamily: display.bar.fontFamily
                  horizontalPadding: Style.spacing.sm
                  bordered: true
                  active: index === display.scaleInUse
                  hasCursor: display.lights("scale", index)
                  onClicked: display.useScale(modelData)
                  onHovered: on => { if (on) display.pointAt("scale", index) }
                }
              }
            }
          }

          PanelSeparator {
            visible: display.outputs.length > 1
            foreground: display.bar.foreground
          }

          Column {
            visible: display.outputs.length > 1
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "DISPLAYS"
              foreground: display.bar.foreground
              fontFamily: display.bar.fontFamily
            }

            Repeater {
              model: display.outputs
              OutputRow { width: sheet.width }
            }
          }

          // Room under the last section.
          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }
    }
  }

  // A command whose whole output is its answer. Asked again while it runs,
  // it answers once.
  component Reader: Process {
    id: reader
    signal answered(string text)
    function ask() { if (!running) running = true }
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: reader.answered(text) }
  }

  // A command run one at a time: asked while it runs, it takes its turn
  // again once done, for the last value asked.
  component Queue: Process {
    property var waiting: null
    signal turn(var value)
    function ask(value) {
      if (running) {
        waiting = value
        return
      }
      waiting = null
      turn(value)
    }
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: if (!running && waiting !== null) ask(waiting)
  }

  // A section's name, and what it is set to at the far end.
  component Heading: Item {
    property alias title: name.text
    property alias reading: readout.text
    property alias readingShown: readout.visible

    width: parent.width
    implicitHeight: Math.max(name.implicitHeight, readout.implicitHeight)

    PanelSectionHeader {
      id: name
      anchors { left: parent.left; verticalCenter: parent.verticalCenter }
      foreground: display.bar.foreground
      fontFamily: display.bar.fontFamily
    }

    Text {
      id: readout
      anchors { right: parent.right; rightMargin: Style.space(6); verticalCenter: parent.verticalCenter }
      textFormat: Text.PlainText
      color: Qt.darker(display.bar.foreground, 1.4)
      font { family: display.bar.fontFamily; pixelSize: Style.font.caption; bold: true }
    }
  }

  // A section under its heading, what it holds below.
  component Section: Column {
    property alias title: heading.title
    property alias reading: heading.reading
    property alias readingShown: heading.readingShown

    width: parent.width

    Heading { id: heading }
  }

  // A slider whose row the cursor lights as a whole, at row -1 of its
  // section.
  component SliderRow: CursorSurface {
    id: sliderRow
    required property string section
    property alias minimum: knob.minimum
    property alias maximum: knob.maximum
    property alias tickCount: knob.tickCount
    property alias value: knob.value
    readonly property alias held: knob.dragging
    readonly property alias knobAt: knob.liveValue
    signal dragged(real value)
    signal letGo(real value)

    width: parent.width
    height: knob.implicitHeight + Style.spacing.controlGap
    hasCursor: display.lights(section, -1)
    onHasCursorChanged: if (hasCursor) display.reveal(sliderRow)
    foreground: display.bar.foreground

    PanelSlider {
      id: knob
      anchors { fill: parent; leftMargin: Style.space(6); rightMargin: Style.space(6) }
      bar: display.bar
      step: 1
      integer: true
      onMoved: value => sliderRow.dragged(value)
      onReleased: value => sliderRow.letGo(value)
    }

    HoverHandler {
      onHoveredChanged: if (hovered) display.pointAt(sliderRow.section, -1)
    }
  }

  // A display: its name, "focused" on the focused one, and a tick while it
  // is on. A click turns it off or on; the last one on is dimmed and stays.
  component OutputRow: CursorSurface {
    id: outputRow
    required property var modelData
    required property int index
    readonly property bool switchable: modelData && (!modelData.enabled || display.lightCount > 1)

    implicitHeight: line.implicitHeight + Style.spacing.xl
    hasCursor: display.lights("monitors", index)
    onHasCursorChanged: if (hasCursor) display.reveal(outputRow)
    current: modelData && modelData.focused
    foreground: display.bar.foreground
    opacity: switchable ? 1.0 : 0.45

    Row {
      id: line
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.space(6); rightMargin: Style.space(6) }
      spacing: Style.space(8)

      Text {
        id: mark
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(22)
        horizontalAlignment: Text.AlignHCenter
        text: Model.screensIcon(1)
        color: display.bar.foreground
        font { family: display.bar.fontFamily; pixelSize: Style.font.title }
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - mark.width - tick.width - Style.space(16)
        textFormat: Text.PlainText
        text: outputRow.modelData.name + (outputRow.modelData.focused ? " · focused" : "")
        color: display.bar.foreground
        font { family: display.bar.fontFamily; pixelSize: Style.font.body }
        elide: Text.ElideRight
      }

      Text {
        id: tick
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(14)
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        text: outputRow.modelData.enabled ? "󰄬" : ""
        color: display.bar.foreground
        font { family: display.bar.fontFamily; pixelSize: Style.font.subtitle }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: outputRow.switchable ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) display.pointAt("monitors", outputRow.index)
      onClicked: display.flip(outputRow.modelData)
    }
  }
}
