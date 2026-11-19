import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Calculator.js" as Calculator
import "Keypad.js" as Keypad

// Calculator: the sum as it is typed, its answer under it as it changes,
// and the keys, in a window of its own size; the scientific keys beside
// them, and the sums worked out before, at a click. qalc works each sum
// out, as it does the menu's (Calculator.js, Qalc.qml), with the angle the
// angle key says; Keypad.js is what each key does.
//
// Summoned by the shell, from the menu's answer (Ctrl+Return), the apps or
// the CLI; `expression` is a sum to start with:
//   nova-shell shell summon nova.calculator '{"expression":"5 km in miles"}'
//
// The basic or scientific keys, the angle's unit, whether the history shows
// and the history itself are kept in $XDG_STATE_HOME/nova/calculator.json.
Item {
  id: root

  // Injected by nova-shell.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "nova.calculator"
  property bool closingFromHost: false

  // ---- what calculator.json keeps -----------------------------------------

  property string mode: "basic"
  property string angle: "deg"
  property bool showsHistory: false
  property var history: []

  // ---- the display --------------------------------------------------------

  // What is typed (Keypad.js), and whether 2nd is on.
  property var calc: Keypad.blank()
  property bool second: false
  // qalc's answers, by the sum as qalc read it, for this opening and this
  // angle; those of runs before freshFrom were for another angle.
  property var answers: ({})
  property int freshFrom: 0
  // The answer shown under the sum, kept while the next is worked out so
  // that it does not blink at each key.
  property var preview: null
  // The sum = was pressed on, while its answer comes; whether it had none.
  property string awaited: ""
  property bool failed: false
  // The key the keyboard pressed last, lit a moment as if clicked.
  property string flashed: ""

  readonly property bool previewShown: !calc.done && !failed && preview !== null && !Keypad.same(calc.typed, preview.label)

  // ---- sizes --------------------------------------------------------------

  readonly property int pad: Style.space(14)
  readonly property int gap: Style.space(8)
  readonly property int keyWidth: Style.space(58)
  readonly property int keyHeight: Style.space(46)
  readonly property int headerHeight: Style.space(32)
  readonly property int displayHeight: Style.space(116)
  readonly property int historyWidth: Style.space(240)
  readonly property int basicWidth: 4 * keyWidth + 3 * gap
  readonly property int scientificWidth: 3 * keyWidth + 2 * gap
  readonly property int keysHeight: 6 * keyHeight + 5 * gap
  readonly property int mainWidth: (mode === "scientific" ? scientificWidth + gap : 0) + basicWidth

  readonly property int bigSize: Math.round(Style.font.displayLarge * 1.55)
  readonly property int digitSize: Math.round(Style.font.heading * 1.3)
  readonly property int functionSize: Math.round(Style.font.heading * 1.1)
  readonly property int scienceSize: Style.font.subtitle

  // ---- lifecycle ----------------------------------------------------------

  function open(payloadJson) {
    closingFromHost = false
    var payload = {}
    try {
      payload = JSON.parse(String(payloadJson || "{}")) || {}
    } catch (e) {
      // An unparseable payload asks for nothing.
    }
    var asked = Keypad.tidy(payload.expression)
    if (asked) {
      second = false
      calc = Keypad.pasted(Keypad.blank(), asked)
    }
    // Open already, on another workspace: it comes to this one. A window is
    // shown on the workspace it is opened on, so it is closed and opened anew.
    if (window.visible && elsewhere()) close()
    window.visible = true
    Qt.callLater(focusKeys)
  }

  function elsewhere() {
    // Hyprland's to answer, and asked only where there is one: without,
    // Quickshell warns that it has no Hyprland to connect to.
    if (!Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")) return false
    var focused = Hyprland.focusedWorkspace
    return focused !== null && Util.onAnotherWorkspace(Hyprland.toplevels.values, window.title, focused.id)
  }

  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(root.pluginId)
    else window.visible = false
  }

  function focusKeys() {
    keys.forceActiveFocus()
  }

  // ---- the keys -----------------------------------------------------------

  // A key clicked or typed: = and the switches are the window's, the rest
  // Keypad's.
  function tap(id) {
    flashed = id
    flash.restart()
    if (id === "=") equals()
    else if (id === "2nd") second = !second
    else if (id === "angle") turnAngle()
    else calc = Keypad.press(calc, second && Keypad.SECOND[id] ? Keypad.SECOND[id] : id)
  }

  function label(key) {
    if (key.id === "C") return Keypad.clearsEntry(calc) ? "C" : "AC"
    if (key.id === "angle") return angle === "deg" ? "Deg" : "Rad"
    return second && key.second ? key.second : key.label
  }

  // Esc clears the display, and closes the window once there is nothing to
  // clear.
  function dismiss() {
    flashed = "C"
    flash.restart()
    if (calc.typed !== "" || calc.previous !== "") calc = Keypad.blank()
    else requestClose()
  }

  // Return, Enter and = work the sum out; Backspace takes a key back,
  // Delete clears, Esc clears and then closes; Ctrl+C copies the answer and
  // Ctrl+V pastes a sum; the rest types as the keys do, or as it is (a
  // unit's letters). False for a key that does nothing here.
  function press(event) {
    var control = (event.modifiers & Qt.ControlModifier) !== 0
    if (control && event.key === Qt.Key_C) copy()
    else if (control && event.key === Qt.Key_V) paste()
    else if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return false
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.text === "=") tap("=")
    else if (event.key === Qt.Key_Escape) dismiss()
    else if (event.key === Qt.Key_Backspace) tap("⌫")
    else if (event.key === Qt.Key_Delete) tap("C")
    else {
      var id = Keypad.keyFor(event.text, (event.modifiers & Qt.KeypadModifier) !== 0)
      if (id) tap(id)
      else if (/^[^\x00-\x1f\x7f]+$/.test(event.text)) calc = Keypad.written(calc, event.text)
      else return false
    }
    return true
  }

  function turnAngle() {
    angle = angle === "deg" ? "rad" : "deg"
    answers = ({})
    freshFrom = calculator.round + 1
    save()
    refresh()
  }

  onCalcChanged: {
    failed = false
    awaited = ""
    refresh()
  }

  // ---- qalc ---------------------------------------------------------------

  function qalcForm(text) {
    return Calculator.qalcForm(Calculator.written(text))
  }

  // The answer under the sum: none for a number alone, which is its own,
  // and for an answer; else qalc's, at once when it has given it already.
  function refresh() {
    var wanted = calc.done ? "" : Keypad.ready(calc.typed)
    if (!wanted || Keypad.plain(wanted)) {
      preview = null
      return
    }
    var sum = qalcForm(wanted)
    if (answers.hasOwnProperty(sum)) preview = answers[sum]
    else calculator.ask(sum)
  }

  // = works the sum out, waiting for qalc if it has not answered yet; a
  // number alone is its own answer, and goes into no history.
  function equals() {
    var sum = Keypad.toWorkOut(calc)
    if (!sum) return
    if (Keypad.plain(sum)) {
      if (!calc.done) calc = { typed: sum, previous: "", done: true }
      return
    }
    var form = qalcForm(sum)
    awaited = sum
    if (answers.hasOwnProperty(form)) finish()
    else calculator.ask(form)
  }

  function finish() {
    var sum = awaited
    var found = answers[qalcForm(sum)]
    awaited = ""
    if (!found) {
      failed = true
      return
    }
    if (!Keypad.same(sum, found.label)) {
      history = Keypad.added(history, { expression: sum, result: found.label })
      save()
    }
    calc = { typed: found.label, previous: sum, done: true }
  }

  function answered(sum, found, round) {
    if (round < freshFrom) return
    var next = Object.assign({}, answers)
    next[sum] = found
    answers = next
    var wanted = calc.done ? "" : Keypad.ready(calc.typed)
    if (wanted && !Keypad.plain(wanted) && qalcForm(wanted) === sum) preview = found
    if (awaited && qalcForm(awaited) === sum) finish()
  }

  Qalc {
    id: calculator
    settings: ["angle " + root.angle]
    onAnswered: (sum, found, round) => root.answered(sum, found, round)
  }

  // ---- the clipboard ------------------------------------------------------

  // Ctrl+C copies the answer, with a plain minus: the one = gave, the one
  // shown under the sum, or the number typed.
  function copy() {
    var text = calc.done ? calc.typed : previewShown ? preview.copy : Keypad.ready(calc.typed)
    if (text) Util.execArgv(["wl-copy", "--", text.replace(/−/g, "-")])
  }

  // Ctrl+V types what was copied, after the sum.
  function paste() {
    if (!pasting.running) pasting.running = true
  }

  Process {
    id: pasting
    command: ["wl-paste", "--no-newline", "--type", "text"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.calc = Keypad.pasted(root.calc, text)
    }
  }

  // ---- history and the rest kept ------------------------------------------

  function recall(entry) {
    calc = Keypad.recalled(calc, entry)
  }

  function read(text) {
    var kept = {}
    try {
      kept = JSON.parse(text) || {}
    } catch (e) {
      // A file that is not JSON keeps nothing.
    }
    mode = kept.mode === "scientific" ? "scientific" : "basic"
    angle = kept.angle === "rad" ? "rad" : "deg"
    showsHistory = kept.showHistory === true
    history = Keypad.historyFrom(kept.history)
  }

  function save() {
    keptFile.setText(JSON.stringify({ mode: mode, angle: angle, showHistory: showsHistory, history: history }, null, 2) + "\n")
  }

  // The folder it goes in, which a new account may not have yet.
  Process {
    running: true
    command: ["mkdir", "-p", Commons.Color.stateHome + "/nova"]
  }

  // Read as the window is made, before it opens at the size its keys
  // take; written whole at each change, and before the window can go.
  FileView {
    id: keptFile
    path: Commons.Color.stateHome + "/nova/calculator.json"
    blockLoading: true
    blockWrites: true
    atomicWrites: true
    printErrors: false
  }

  Component.onCompleted: read(keptFile.text())

  Timer {
    id: flash
    interval: 120
    onTriggered: root.flashed = ""
  }

  // ---- window -------------------------------------------------------------

  FloatingWindow {
    id: window
    title: "Calculator"
    visible: false
    color: Commons.Color.background
    implicitWidth: (root.showsHistory ? root.historyWidth + 1 : 0) + root.pad + root.mainWidth + root.pad
    implicitHeight: root.pad + root.headerHeight + root.displayHeight + root.gap + root.keysHeight + root.pad
    // Its size is its keys', not the user's to change: fixed, the compositor
    // also takes the new size when the scientific keys or the history come
    // or go, where an implicit size alone it keeps to the first.
    minimumSize: Qt.size(implicitWidth, implicitHeight)
    maximumSize: Qt.size(implicitWidth, implicitHeight)

    onVisibleChanged: {
      if (visible) return
      if (!root.closingFromHost && root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    }

    FocusScope {
      id: keys
      anchors.fill: parent
      focus: true

      Keys.onPressed: function (event) {
        if (root.press(event)) event.accepted = true
      }

      // ---- the history, at the left when it shows -----------------------
      Rectangle {
        id: historyColumn
        visible: root.showsHistory
        width: root.historyWidth
        height: parent.height
        color: Util.alpha(Commons.Color.foreground, 0.03)

        Text {
          id: historyTitle
          x: root.pad
          height: root.pad + root.headerHeight
          verticalAlignment: Text.AlignVCenter
          text: "History"
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
          textFormat: Text.PlainText
        }

        ListView {
          id: past
          anchors.top: historyTitle.bottom
          anchors.bottom: clearHistory.top
          anchors.bottomMargin: root.gap
          width: parent.width
          clip: true
          model: root.history
          boundsBehavior: Flickable.StopAtBounds

          delegate: Rectangle {
            id: entry
            required property var modelData
            width: ListView.view.width
            height: Style.space(52)
            color: picker.containsMouse ? Style.hoverFill : "transparent"

            Column {
              anchors.verticalCenter: parent.verticalCenter
              x: root.pad
              width: parent.width - 2 * root.pad
              spacing: Style.space(2)

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignRight
                text: entry.modelData.expression
                color: Commons.Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideLeft
                textFormat: Text.PlainText
              }
              Text {
                width: parent.width
                horizontalAlignment: Text.AlignRight
                text: entry.modelData.result
                color: Commons.Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
                elide: Text.ElideLeft
                textFormat: Text.PlainText
              }
            }

            MouseArea {
              id: picker
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.recall(entry.modelData)
            }
          }

          TouchpadScroll {
            anchors.fill: parent
            flickable: past
          }
        }

        Text {
          anchors.centerIn: past
          visible: root.history.length === 0
          text: "No History"
          color: Commons.Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          textFormat: Text.PlainText
        }

        Button {
          id: clearHistory
          anchors.right: parent.right
          anchors.rightMargin: root.pad
          anchors.bottom: parent.bottom
          anchors.bottomMargin: root.pad
          text: "Clear"
          bordered: true
          enabled: root.history.length > 0
          opacity: enabled ? 1 : 0.4
          onClicked: {
            root.history = []
            root.save()
          }
        }
      }

      Rectangle {
        id: historyRule
        visible: root.showsHistory
        anchors.left: historyColumn.right
        width: 1
        height: parent.height
        color: Qt.alpha(Commons.Color.foreground, 0.08)
      }

      // ---- the display and the keys -------------------------------------
      Item {
        id: main
        x: (root.showsHistory ? root.historyWidth + 1 : 0) + root.pad
        y: root.pad
        width: root.mainWidth
        height: parent.height - 2 * root.pad

        Item {
          id: header
          width: parent.width
          height: root.headerHeight

          Button {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰋚"
            bordered: true
            selected: root.showsHistory
            tooltipText: "History"
            onClicked: {
              root.showsHistory = !root.showsHistory
              root.save()
            }
          }

          ButtonGroup {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            options: [{ value: "basic", label: "Basic" }, { value: "scientific", label: "Scientific" }]
            value: root.mode
            tabStop: false
            onChanged: function (value) {
              root.mode = value
              root.save()
            }
          }
        }

        Item {
          id: display
          anchors.top: header.bottom
          width: parent.width
          height: root.displayHeight

          // The angle's unit, while the sum has a function that takes one.
          Text {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.topMargin: Style.space(8)
            visible: Keypad.angled(root.calc.done ? root.calc.previous : root.calc.typed)
            text: root.angle === "deg" ? "Deg" : "Rad"
            color: Commons.Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
          }

          // The sum = worked out, over its answer.
          Text {
            anchors.right: parent.right
            anchors.left: parent.left
            anchors.leftMargin: Style.space(32)
            anchors.bottom: big.top
            horizontalAlignment: Text.AlignRight
            text: root.calc.done && root.calc.previous ? root.calc.previous + " =" : ""
            color: Commons.Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.subtitle
            elide: Text.ElideLeft
            textFormat: Text.PlainText
          }

          // The sum, as large as fits, and past that its end; the brackets
          // it has not closed yet show closed, fainter.
          Item {
            id: big
            anchors.bottom: answer.top
            width: parent.width
            height: Math.round(root.bigSize * 1.3)
            clip: true

            readonly property string shown: root.calc.typed === "" ? "0" : root.calc.typed
            readonly property string closing: ")".repeat(Keypad.opens(root.calc.typed))
            readonly property int fitted: measure.advanceWidth > width
              ? Math.max(Style.font.heading, Math.floor(root.bigSize * width / measure.advanceWidth)) : root.bigSize

            TextMetrics {
              id: measure
              font.family: Style.font.family
              font.pixelSize: root.bigSize
              text: big.shown + big.closing
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: big.shown.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
                + (big.closing ? "<font color=\"" + Commons.Color.muted + "\">" + big.closing + "</font>" : "")
              color: Commons.Color.foreground
              font.family: Style.font.family
              font.pixelSize: big.fitted
              textFormat: Text.StyledText
            }
          }

          // The answer while typing, or Error when = found none.
          Text {
            id: answer
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(4)
            width: parent.width
            height: Math.round(Style.font.heading * 1.6)
            horizontalAlignment: Text.AlignRight
            verticalAlignment: Text.AlignVCenter
            text: root.failed ? "Error" : root.previewShown ? root.preview.label : ""
            color: root.failed ? Commons.Color.urgent : Commons.Color.muted
            font.family: Style.font.family
            font.pixelSize: Math.round(Style.font.heading * 1.25)
            elide: Text.ElideLeft
            textFormat: Text.PlainText
          }
        }

        // The scientific keys at the left, the basic ones at the right.
        Item {
          id: keypad
          anchors.top: display.bottom
          anchors.topMargin: root.gap
          width: parent.width
          height: root.keysHeight

          Repeater {
            model: root.mode === "scientific" ? Keypad.SCIENTIFIC : []

            Key {
              required property var modelData
              x: modelData.col * (root.keyWidth + root.gap)
              y: modelData.row * (root.keyHeight + root.gap)
              width: root.keyWidth
              height: root.keyHeight
              label: root.label(modelData)
              kind: modelData.kind
              lit: modelData.id === "2nd" && root.second
              flashed: root.flashed === modelData.id
              fontSize: root.scienceSize
              onActivated: root.tap(modelData.id)
            }
          }

          Repeater {
            model: Keypad.BASIC

            Key {
              required property var modelData
              readonly property int cols: modelData.cols || 1
              readonly property int rows: modelData.rows || 1
              x: (root.mode === "scientific" ? root.scientificWidth + root.gap : 0) + modelData.col * (root.keyWidth + root.gap)
              y: modelData.row * (root.keyHeight + root.gap)
              width: cols * root.keyWidth + (cols - 1) * root.gap
              height: rows * root.keyHeight + (rows - 1) * root.gap
              label: root.label(modelData)
              kind: modelData.kind
              flashed: root.flashed === modelData.id
              fontSize: modelData.kind === "function" ? root.functionSize : root.digitSize
              onActivated: root.tap(modelData.id)
            }
          }
        }
      }
    }
  }
}
