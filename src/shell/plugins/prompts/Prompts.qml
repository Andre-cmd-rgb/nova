import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "PromptsModel.js" as Model

// Nova's own dialogs: what nova-sessiond needs from the person at the
// computer, asked on a card over the dimmed screen, the polkit card's twin:
// an encrypted drive's passphrase, a Bluetooth pairing's code, a printer's
// user name and password. A duty connects to $XDG_RUNTIME_DIR/nova/prompts.sock, in the
// user's private runtime folder, and one connection is one dialog
// (PromptsModel.js has the lines each way; prompt.rs the duty's side).
//
// One card at a time: a second dialog waits for the first to end. The card
// has the question's title on a tab above it, and on it the fields to type
// in, or a code to compare and the answers Cancel and the duty's own, or
// Cancel alone while the duty waits (a code typed on the other device), or
// the duty's answer alone (a message). It may have a list to choose one of,
// in sections (a screen or a window to share), and a switch or two under it
// (unlock this keyring at login). Return answers, Escape cancels, Tab goes to
// the next field; the arrows up and down choose in the list, and Space turns
// the switch. Answered, it says "Checking..." until the duty says it is done,
// or that the answer was wrong: then it shakes, in the error colours, its
// secret fields emptied.
//
// What is typed is only ever the fields' text. It goes to the duty on Return
// and the secret fields are emptied then, and whenever a question starts or
// ends.
Item {
  id: root

  // Injected by nova-shell.
  property var shell: null
  property var manifest: null

  // The [polkit] section of the theme's shell.toml: the two cards are one.
  readonly property QtObject colors: Commons.Color.polkit
  readonly property string family: Style.font.menuFamily
  readonly property int lineHeight: Math.max(Style.space(42), Style.spacing.controlHeight)
  readonly property int padding: Style.spacing.panelPadding
  readonly property string folder: Quickshell.env("XDG_RUNTIME_DIR") + "/nova"

  // ---------------------------------------------------------------- state

  // The dialogs open with a question, oldest first; the card is the first's.
  property var dialogs: []
  readonly property var current: dialogs.length > 0 ? dialogs[0] : null
  // The question on the card, kept while the card lingers after its end.
  property var ask: null
  property bool checking: false
  property bool wrong: false
  property string wrongText: ""
  // The answer to a yes or no under the pointer or the arrows: 0 Cancel, 1 the duty's.
  property int choice: 1
  // What is chosen in the list, by id, and how each switch is.
  property string chosenId: ""
  property var toggleStates: []
  property bool leaving: false
  property int shake: 0

  readonly property bool shown: ask !== null && (current !== null || leaving)
  readonly property var fields: ask ? ask.fields : []
  readonly property var choices: ask ? ask.choices : []
  readonly property var toggles: ask ? ask.toggles : []
  readonly property int chosenIndex: {
    for (var i = 0; i < choices.length; i++) if (choices[i].id === chosenId) return i
    return -1
  }
  readonly property color tint: wrong ? colors.textError : colors.accent
  readonly property color ink: wrong ? colors.textError : colors.text
  readonly property bool hasText: ask !== null && ask.text !== ""
  readonly property bool hasCode: ask !== null && ask.code !== ""
  // A yes or no has the duty's answer as well as Cancel; a wait, Cancel alone.
  readonly property bool hasAccept: ask !== null && ask.accept !== ""

  // The card's window, made while it is shown and gone after (null then):
  // it is up the moment a question comes, and holds nothing in between.
  readonly property var surface: cardLoader.item

  readonly property int cardWidth: Math.min(Style.space(choices.length > 0 ? 440 : hasCode || fields.length === 0 ? 380 : 340),
    Math.max(Style.space(260), (surface ? surface.width : 0) - Style.gapsOut * 2))

  // The next dialog's question at once; with none, the card lingers a
  // moment on the last one, and goes.
  onCurrentChanged: if (current) present()

  // ---------------------------------------------------------------- the dialogs

  function heard(dialog, line) {
    var said = Model.parse(line)
    if (!said) return
    if (said.type === "ask") {
      dialog.ask = said
      if (dialogs.indexOf(dialog) < 0) dialogs = dialogs.concat([dialog])
      else if (dialog === current) present()
    } else if (said.type === "wrong") {
      if (dialog === current) refused(said.text)
    } else if (said.type === "done") {
      finish(dialog)
    }
  }

  // The dialog is over. A card that has just said "wrong" shakes to the end
  // first.
  function finish(dialog) {
    if (dialog === current && wrong) {
      dialog.ending = true
      return
    }
    drop(dialog)
    dialog.connected = false
  }

  function drop(dialog) {
    if (dialogs.indexOf(dialog) < 0) return
    if (dialog === current) leave()
    dialogs = dialogs.filter(function (d) { return d !== dialog })
  }

  // The card for the first dialog's question, from the start. Its fields
  // are made anew for it, empty but for a value of their own.
  function present() {
    lingering.stop()
    leaving = false
    checking = false
    wrong = false
    wrongFor.stop()
    ask = current.ask
    choice = hasAccept ? 1 : 0
    chosenId = ask.chosen
    toggleStates = ask.toggles.map(function (t) { return t.value })
    Qt.callLater(takeKeys)
  }

  function texts() {
    var all = []
    if (!surface) return all
    for (var i = 0; i < surface.fieldLines.count; i++) {
      var line = surface.fieldLines.itemAt(i)
      all.push(line ? line.input.text : "")
    }
    return all
  }

  // The secret fields emptied, while there is a card.
  function clearSecrets() {
    if (!surface) return
    for (var i = 0; i < surface.fieldLines.count; i++) {
      var line = surface.fieldLines.itemAt(i)
      if (line && fields[i].secret) line.input.text = ""
    }
  }

  // The keys go to the first field not typed in, else the last; with no
  // field, to the card.
  function takeKeys() {
    if (!shown || !surface) return
    var lines = surface.fieldLines
    for (var i = 0; i < lines.count; i++) {
      var line = lines.itemAt(i)
      if (line && (line.input.text === "" || i === lines.count - 1)) {
        line.input.forceActiveFocus()
        return
      }
    }
    surface.keyCatcher.forceActiveFocus()
  }

  function next(from) {
    if (!surface) return
    var line = surface.fieldLines.itemAt((from + 1) % Math.max(1, surface.fieldLines.count))
    if (line) line.input.forceActiveFocus()
  }

  // ---------------------------------------------------------------- the answer

  function answer() {
    if (!current || checking || wrong || leaving) return
    var typed = texts()
    if (!Model.answerable(fields, typed)) {
      takeKeys()
      return
    }
    current.write(Model.answerLine(fields, typed, choices.length > 0 ? chosenId : "", toggles, toggleStates))
    current.flush()
    checking = true
    clearSecrets()
    if (surface) surface.keyCatcher.forceActiveFocus()
  }

  function cancel() {
    if (!current) return
    // A message has one answer, which Escape gives too.
    if (ask && ask.alone) {
      answer()
      return
    }
    var dialog = current
    dialog.write(Model.cancelLine())
    dialog.flush()
    drop(dialog)
    dialog.connected = false
  }

  function choose(which) {
    if (which === 1 && hasAccept) answer()
    else if (which === 0 && !(ask && ask.alone)) cancel()
  }

  // The next or the one before in the list, kept in view.
  function chooseNext(step) {
    if (choices.length === 0 || checking) return
    var at = Math.max(0, Math.min(choices.length - 1, chosenIndex + step))
    chosenId = choices[at].id
    if (surface) surface.choiceList.positionViewAtIndex(at, ListView.Contain)
  }

  function flip(which) {
    if (which < 0 || which >= toggles.length || checking) return
    var next = toggleStates.slice()
    next[which] = !next[which]
    toggleStates = next
  }

  function refused(text) {
    checking = false
    wrong = true
    wrongText = text
    clearSecrets()
    wrongFor.restart()
    shaking.restart()
    Qt.callLater(takeKeys)
  }

  function leave() {
    leaving = true
    checking = false
    lingering.restart()
  }

  Timer {
    id: lingering
    interval: 300
    onTriggered: {
      root.leaving = false
      if (!root.current) root.ask = null
    }
  }

  Timer {
    id: wrongFor
    interval: 1200
    onTriggered: {
      root.wrong = false
      var dialog = root.current
      if (dialog && dialog.ending) {
        root.drop(dialog)
        dialog.connected = false
      } else {
        Qt.callLater(root.takeKeys)
      }
    }
  }

  // A shake of the head: left, right, and back.
  SequentialAnimation {
    id: shaking
    NumberAnimation { target: root; property: "shake"; to: -8; duration: 35; easing.type: Easing.OutQuad }
    NumberAnimation { target: root; property: "shake"; to: 8; duration: 50; easing.type: Easing.InOutQuad }
    NumberAnimation { target: root; property: "shake"; to: 0; duration: 55; easing.type: Easing.OutQuad }
  }

  // ---------------------------------------------------------------- the socket

  // The runtime folder may not be there yet as the shell starts.
  Process {
    command: ["mkdir", "-p", "-m", "700", root.folder]
    running: true
    onExited: server.active = true
  }

  SocketServer {
    id: server
    active: false
    path: root.folder + "/prompts.sock"

    handler: Socket {
      id: dialog

      // The question it asks, once it has.
      property var ask: null
      // The duty said done while the card shook: it goes after.
      property bool ending: false

      parser: SplitParser {
        onRead: data => root.heard(dialog, data)
      }
      onConnectedChanged: {
        if (!connected) root.drop(dialog)
      }
    }
  }

  // ---------------------------------------------------------------- the card

  LazyLoader {
    id: cardLoader
    active: root.shown

    PanelWindow {
      id: cardWindow
      visible: true
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      WlrLayershell.namespace: "nova-prompts"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
      exclusionMode: ExclusionMode.Ignore

      // What the card's logic reaches of it.
      property alias fieldLines: fieldLines
      property alias keyCatcher: keyCatcher
      property alias choiceList: choiceList

      // Made as a question comes: the keys go to it then.
      Component.onCompleted: Qt.callLater(root.takeKeys)

      Rectangle {
        anchors.fill: parent
        color: root.colors.scrim
      }

      // A click anywhere gives the keys back to the card; it cancels nothing.
      MouseArea {
        anchors.fill: parent
        onClicked: root.takeKeys()
      }

      BorderSurface {
        id: card
        anchors.centerIn: parent
        anchors.horizontalCenterOffset: root.shake
        width: root.cardWidth
        height: inset.top + content.implicitHeight + inset.bottom
        radius: Style.cornerRadius
        color: root.colors.background
        frame: root.wrong
          ? Border.surfaceSpec("polkit", "border-error", root.colors.borderError, Math.max(1, Style.space(2)), "border-alpha")
          : Border.surfaceSpec("polkit", "border", root.colors.border, Math.max(1, Style.space(2)), "border-alpha")
        padding: root.padding

        MouseArea {
          anchors.fill: parent
          onClicked: root.takeKeys()
        }

        // The card's own keys, when no field has them: Escape cancels, Return
        // answers, the arrows and Tab choose between a yes or no's answers.
        Item {
          id: keyCatcher
          anchors.fill: parent
          focus: true
          Keys.priority: Keys.BeforeItem
          Keys.onPressed: function (event) {
            switch (event.key) {
            case Qt.Key_Escape:
              root.cancel()
              break
            case Qt.Key_Return:
            case Qt.Key_Enter:
              if (root.fields.length === 0) root.choose(root.choice)
              else root.answer()
              break
            case Qt.Key_Left:
            case Qt.Key_Right:
            case Qt.Key_Tab:
            case Qt.Key_Backtab:
              if (root.fields.length > 0) return
              if (root.hasAccept && !root.ask.alone) root.choice = 1 - root.choice
              break
            case Qt.Key_Up:
            case Qt.Key_Down:
              if (root.choices.length === 0) return
              root.chooseNext(event.key === Qt.Key_Down ? 1 : -1)
              break
            case Qt.Key_Space:
              if (root.toggles.length === 0) return
              root.flip(0)
              break
            default:
              return
            }
            event.accepted = true
          }
        }

        Row {
          id: content
          x: card.inset.left
          y: card.inset.top
          width: card.width - card.inset.left - card.inset.right
          spacing: Style.space(14)

          // What it is about.
          Text {
            id: glyph
            width: Style.space(26)
            height: root.lineHeight
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            textFormat: Text.PlainText
            text: Model.glyph(root.ask ? root.ask.glyph : "")
            color: root.tint
            font.family: root.family
            font.pixelSize: Style.font.iconLarge
          }

          Column {
            width: parent.width - glyph.width - parent.spacing
            spacing: Style.space(6)

            // A code to compare, or to type on the other device, large.
            Text {
              width: parent.width
              visible: root.hasCode
              height: visible ? root.lineHeight : 0
              verticalAlignment: Text.AlignVCenter
              textFormat: Text.PlainText
              text: root.ask ? root.ask.code : ""
              color: root.ink
              font.family: root.family
              font.pixelSize: Math.round(Style.font.iconLarge * 1.3)
              font.letterSpacing: Style.space(3)
              font.bold: true
            }

            // What it asks, in a line or two; alone, as high as the glyph's
            // line at the least, and level with it.
            Item {
              width: parent.width
              visible: root.hasText
              height: visible ? (root.hasCode ? words.implicitHeight : Math.max(root.lineHeight, words.implicitHeight)) : 0

              Text {
                id: words
                width: parent.width
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: root.ask ? root.ask.text : ""
                wrapMode: Text.WordWrap
                color: root.colors.text
                opacity: 0.72
                font.family: root.family
                font.pixelSize: Style.font.bodySmall
              }
            }

            Repeater {
              id: fieldLines
              model: root.fields

              // A line to type in: dots for a secret, unless shown; what it is
              // for while it is empty, or how the answer went.
              Item {
                id: line
                required property var modelData
                required property int index
                readonly property alias input: field
                width: parent.width
                height: root.lineHeight

                Component.onCompleted: field.text = modelData.secret ? "" : modelData.value

                TextInput {
                  id: field
                  anchors.fill: parent
                  verticalAlignment: TextInput.AlignVCenter
                  clip: true
                  enabled: root.shown
                  readOnly: root.checking || root.wrong
                  echoMode: line.modelData.secret ? TextInput.Password : TextInput.Normal
                  passwordCharacter: "•"
                  cursorVisible: activeFocus && !root.checking && !root.wrong
                  color: root.ink
                  selectionColor: Util.alpha(root.colors.accent, 0.45)
                  selectedTextColor: root.colors.text
                  font.family: root.family
                  font.pixelSize: Style.font.iconLarge
                  onAccepted: {
                    if (line.index < root.fields.length - 1 && text !== "") root.next(line.index)
                    else root.answer()
                  }
                  Keys.onPressed: function (event) {
                    if (event.key === Qt.Key_Escape) {
                      root.cancel()
                    } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                      root.next(event.key === Qt.Key_Tab ? line.index : line.index + root.fields.length - 2)
                    } else {
                      return
                    }
                    event.accepted = true
                  }
                }

                Text {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  visible: field.text.length === 0
                  textFormat: Text.PlainText
                  text: root.wrong && line.modelData.secret ? "Wrong"
                    : root.checking && line.index === root.fields.length - 1 ? "Checking..."
                    : line.modelData.label
                  color: root.ink
                  opacity: root.wrong && line.modelData.secret ? 1 : 0.36
                  font.family: root.family
                  font.pixelSize: Style.font.iconLarge
                  elide: Text.ElideRight
                }

                // The empty field's cursor, which the words above would cover.
                Rectangle {
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.max(1, Style.space(2))
                  height: Style.space(24)
                  visible: field.activeFocus && field.text.length === 0 && !root.checking && !root.wrong
                  color: root.ink
                }

                MouseArea {
                  anchors.fill: parent
                  acceptedButtons: Qt.LeftButton
                  onClicked: field.forceActiveFocus()
                }
              }
            }

            // One of a list, in sections: a heading over the first of each.
            ListView {
              id: choiceList
              width: parent.width
              visible: root.choices.length > 0
              height: visible ? Math.min(contentHeight, Style.space(330)) : 0
              clip: true
              interactive: contentHeight > height
              boundsBehavior: Flickable.StopAtBounds
              model: root.choices

              delegate: Column {
                id: entry
                required property var modelData
                required property int index
                readonly property bool chosen: root.chosenId === modelData.id
                width: choiceList.width

                Text {
                  width: parent.width
                  visible: entry.modelData.section !== "" && (entry.index === 0 || root.choices[entry.index - 1].section !== entry.modelData.section)
                  height: visible ? Style.space(26) : 0
                  verticalAlignment: Text.AlignBottom
                  bottomPadding: Style.space(4)
                  textFormat: Text.PlainText
                  text: entry.modelData.section
                  color: root.colors.text
                  opacity: 0.55
                  font.family: root.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Rectangle {
                  width: parent.width
                  height: Style.space(38)
                  radius: Style.cornerRadius
                  color: entry.chosen ? Util.alpha(root.colors.accent, 0.2) : pointer.containsMouse ? Util.alpha(root.colors.text, 0.06) : "transparent"
                  border.width: entry.chosen ? Style.normalBorderWidth : 0
                  border.color: root.colors.accent

                  Text {
                    id: mark
                    x: Style.space(10)
                    width: Style.space(22)
                    anchors.verticalCenter: parent.verticalCenter
                    horizontalAlignment: Text.AlignHCenter
                    textFormat: Text.PlainText
                    text: entry.modelData.glyph ? Model.glyph(entry.modelData.glyph) : ""
                    color: entry.chosen ? root.colors.accent : root.colors.text
                    font.family: root.family
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    anchors.left: mark.right
                    anchors.leftMargin: Style.space(10)
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: entry.modelData.label + (entry.modelData.detail ? "  ·  " + entry.modelData.detail : "")
                    color: entry.chosen ? root.colors.accent : root.colors.text
                    elide: Text.ElideRight
                    font.family: root.family
                    font.pixelSize: Style.font.bodySmall
                  }

                  MouseArea {
                    id: pointer
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (!root.checking) root.chosenId = entry.modelData.id
                    onDoubleClicked: {
                      if (root.checking) return
                      root.chosenId = entry.modelData.id
                      root.answer()
                    }
                  }
                }
              }
            }

            // A switch or two, with what each is for.
            Repeater {
              model: root.toggles

              Item {
                id: switchLine
                required property var modelData
                required property int index
                width: parent.width
                height: Style.space(36)

                ToggleSwitch {
                  id: knob
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  checked: root.toggleStates[switchLine.index] === true
                  foreground: root.colors.text
                  onToggled: root.flip(switchLine.index)
                }

                Text {
                  anchors.left: knob.right
                  anchors.leftMargin: Style.space(10)
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: switchLine.modelData.label
                  wrapMode: Text.WordWrap
                  color: root.colors.text
                  font.family: root.family
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  anchors.fill: parent
                  anchors.leftMargin: knob.width
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.flip(switchLine.index)
                }
              }
            }

            // A yes or no: Cancel, and the duty's answer, chosen at first.
            Row {
              anchors.right: parent.right
              visible: root.fields.length === 0
              topPadding: Style.space(6)
              spacing: Style.space(10)

              Answer { which: 0; label: root.ask ? root.ask.cancel : "Cancel"; visible: !(root.ask && root.ask.alone) }
              Answer {
                which: 1
                visible: root.hasAccept
                label: root.checking ? "Checking..." : root.ask ? root.ask.accept : ""
              }
            }
          }
        }
      }

      // What the question is about, on a tab above the card; what was wrong,
      // while the card says so.
      Rectangle {
        anchors.horizontalCenter: card.horizontalCenter
        anchors.bottom: card.top
        anchors.bottomMargin: Style.space(10)
        width: Math.min(label.implicitWidth + Style.space(24), cardWindow.width - Style.gapsOut * 2)
        height: Style.space(28)
        radius: Style.cornerRadius
        color: root.colors.background

        Text {
          id: label
          anchors.fill: parent
          anchors.leftMargin: Style.space(12)
          anchors.rightMargin: Style.space(12)
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          textFormat: Text.PlainText
          text: root.wrong && root.wrongText !== "" ? root.wrongText : root.ask ? root.ask.title : ""
          color: root.wrong ? root.colors.textError : root.colors.text
          font.family: root.family
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideMiddle
        }
      }
    }
  }

  // An answer to a yes or no, outlined faintly; filled while chosen, the
  // duty's in the accent colour.
  component Answer: BorderSurface {
    id: answer

    required property int which
    required property string label
    readonly property bool chosen: root.choice === which && !root.checking
    readonly property color strength: which === 1 ? root.colors.accent : root.colors.text

    width: Math.max(Style.space(88), words.implicitWidth + Style.space(24))
    height: Style.space(34)
    color: chosen ? Util.alpha(strength, 0.2) : "transparent"
    frame: Border.flat(chosen ? strength : Util.alpha(strength, 0.45), Style.normalBorderWidth)

    Text {
      id: words
      anchors.centerIn: parent
      text: answer.label
      textFormat: Text.PlainText
      color: answer.chosen ? answer.strength : root.colors.text
      font.family: root.family
      font.pixelSize: Style.font.caption
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: if (!root.checking) root.choice = answer.which
      onClicked: root.choose(answer.which)
    }
  }
}
