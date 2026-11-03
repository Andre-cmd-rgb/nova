import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Polkit
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "PolkitModel.js" as PolkitModel

// Nova's polkit agent: when an app needs root, a card over the dimmed
// screen asks for the password, or the finger. One at a time: the finger
// while PAM waits on the reader, which it does when /etc/pam.d/polkit-1 has
// it and the lid is open; the password field as soon as PAM asks for a
// password, at once when the lid is shut and Nova's lid check skips the
// reader.
//
// The password is only ever the field's text. It goes to PAM on Return and
// is cleared then, and on Escape, on a wrong answer, when a request starts
// and when one ends.
Item {
  id: agent

  // The [polkit] section of the theme's shell.toml.
  readonly property QtObject colors: Commons.Color.polkit
  readonly property string family: Style.font.menuFamily
  readonly property int lineHeight: Math.max(Style.space(42), Style.spacing.controlHeight)
  readonly property int padding: Style.spacing.panelPadding

  // ---------------------------------------------------------------- state

  // The request, copied from the flow, so that the card still reads the
  // same while it lingers after the flow is gone.
  property string requestMessage: ""
  property bool awaitingAnswer: false
  property bool echo: false
  // A password went to PAM, and PAM has not answered yet.
  property bool checking: false
  // PAM said no: the card shows it in the error colours for a moment.
  property bool wrong: false
  // Answered or cancelled: the card stays up a moment longer.
  property bool leaving: false
  property bool readerInPam: false
  // Asked again at each request: with the lid shut, the reader is out of
  // reach.
  property bool lidShut: false
  property int shake: 0

  readonly property bool shown: polkit.isActive || leaving
  readonly property bool byFinger: readerInPam && !lidShut && shown && !awaitingAnswer && !checking && !wrong
  readonly property color tint: wrong ? colors.textError : colors.accent
  readonly property color ink: wrong ? colors.textError : colors.text

  // The finger's card is a square round the sensor; the password's is
  // wide enough for a field.
  readonly property int cardHeight: surface.height > 0
    ? Math.min(lineHeight + padding * 2, surface.height - Style.gapsOut * 2)
    : lineHeight + padding * 2
  readonly property int cardWidth: byFinger
    ? cardHeight
    : Math.min(Style.space(312), Math.max(Style.space(260), surface.width - Style.gapsOut * 2))

  // ---------------------------------------------------------------- the request

  // What the flow says now. A new question from PAM ends "Checking...".
  function follow() {
    var flow = polkit.flow
    if (!flow) return
    requestMessage = String(flow.message || "Authentication is needed...")
    awaitingAnswer = !!flow.isResponseRequired
    echo = !!flow.responseVisible
    if (awaitingAnswer) checking = false
  }

  function start() {
    lingering.stop()
    leaving = false
    checking = false
    field.text = ""
    if (!lidCheck.running) lidCheck.running = true
    follow()
    Qt.callLater(takeKeys)
  }

  function forget() {
    requestMessage = ""
    awaitingAnswer = false
    echo = false
    checking = false
    wrong = false
    field.text = ""
  }

  // The keys go to the field; with none, to the card, for Escape.
  function takeKeys() {
    if (!shown) return
    if (byFinger) keyCatcher.forceActiveFocus()
    else field.forceActiveFocus()
  }

  // ---------------------------------------------------------------- the answer

  function answer() {
    var flow = polkit.flow
    if (!flow || !flow.isResponseRequired) return
    checking = true
    wrong = false
    flow.submit(field.text)
    field.text = ""
    keyCatcher.forceActiveFocus()
  }

  function cancel() {
    var flow = polkit.flow
    field.text = ""
    checking = false
    leave()
    if (flow) flow.cancelAuthenticationRequest()
  }

  function leave() {
    leaving = true
    lingering.restart()
  }

  function refused() {
    checking = false
    wrong = true
    field.text = ""
    wrongFor.restart()
    shaking.restart()
    Qt.callLater(takeKeys)
  }

  Timer {
    id: lingering
    interval: 300
    onTriggered: {
      agent.leaving = false
      agent.forget()
    }
  }

  Timer {
    id: wrongFor
    interval: 1200
    onTriggered: agent.wrong = false
  }

  // A shake of the head: left, right, and back.
  SequentialAnimation {
    id: shaking
    NumberAnimation { target: agent; property: "shake"; to: -8; duration: 35; easing.type: Easing.OutQuad }
    NumberAnimation { target: agent; property: "shake"; to: 8; duration: 50; easing.type: Easing.InOutQuad }
    NumberAnimation { target: agent; property: "shake"; to: 0; duration: 55; easing.type: Easing.OutQuad }
  }

  // ---------------------------------------------------------------- the reader

  FileView {
    path: "/etc/pam.d/polkit-1"
    watchChanges: true
    printErrors: false
    onLoaded: agent.readerInPam = PolkitModel.fingerprintInPam(text())
    onLoadFailed: agent.readerInPam = false
    onFileChanged: reload()
  }

  Process {
    id: lidCheck
    command: ["bash", "-c", "nova-hw-laptop-closed && echo closed || echo open"]
    stdout: StdioCollector { id: lidAnswer; waitForEnd: true }
    onExited: agent.lidShut = lidAnswer.text.trim() === "closed"
  }

  // ---------------------------------------------------------------- polkit

  PolkitAgent {
    id: polkit
    path: "/org/nova/PolkitAgent"

    onAuthenticationRequestStarted: agent.start()
    onIsActiveChanged: {
      if (isActive) agent.follow()
      else if (!agent.leaving) agent.forget()
    }
    onIsRegisteredChanged: {
      if (isRegistered) console.log("nova polkit agent registered")
      else console.warn("nova polkit agent is not registered; another agent may be running")
    }
  }

  Connections {
    target: polkit.flow

    function onIsResponseRequiredChanged() {
      agent.follow()
      if (!polkit.flow || !polkit.flow.isResponseRequired) field.text = ""
      Qt.callLater(agent.takeKeys)
    }
    function onInputPromptChanged() { agent.follow() }
    function onResponseVisibleChanged() { agent.follow() }
    function onSupplementaryMessageChanged() { agent.follow() }
    function onFailedChanged() { agent.follow() }
    function onAuthenticationFailed() {
      agent.follow()
      agent.refused()
    }
    function onAuthenticationSucceeded() { agent.leave() }
    function onAuthenticationRequestCancelled() { agent.leave() }
  }

  // ---------------------------------------------------------------- the card

  PanelWindow {
    id: surface
    visible: agent.shown
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "nova-polkit"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: agent.colors.scrim
    }

    // A click anywhere gives the keys back to the card; it cancels nothing.
    MouseArea {
      anchors.fill: parent
      onClicked: agent.takeKeys()
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: agent.shake
      width: agent.cardWidth
      height: agent.cardHeight
      radius: Style.cornerRadius
      color: agent.colors.background
      borderSpec: agent.wrong
        ? Border.surfaceSpec("polkit", "border-error", agent.colors.borderError, Math.max(1, Style.space(2)), "border-alpha")
        : Border.surfaceSpec("polkit", "border", agent.colors.border, Math.max(1, Style.space(2)), "border-alpha")
      padding: agent.padding

      MouseArea {
        anchors.fill: parent
        onClicked: agent.takeKeys()
      }

      // The card's own keys, when the field does not have them: Escape
      // cancels, Return answers if PAM is asking.
      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Escape) {
            agent.cancel()
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (agent.awaitingAnswer) agent.answer()
          } else {
            return
          }
          event.accepted = true
        }
      }

      // The sensor's glyph, alone in its square.
      OpticalGlyph {
        anchors.centerIn: parent
        width: Math.round(agent.lineHeight * 0.7)
        height: width
        visible: agent.byFinger
        text: "\u{F0237}"
        fontFamily: agent.family
        fontSize: Math.round(agent.lineHeight * 0.7)
        color: agent.colors.accent
      }

      // A padlock, and the password field.
      Row {
        visible: !agent.byFinger
        anchors.fill: parent
        anchors.leftMargin: card.contentLeftInset
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        spacing: Style.space(14)

        Text {
          width: Style.space(26)
          height: agent.lineHeight
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          textFormat: Text.PlainText
          text: "\u{F023}"
          color: agent.tint
          font.family: agent.family
          font.pixelSize: Style.font.iconLarge
        }

        Item {
          width: parent.width - Style.space(40)
          height: agent.lineHeight

          // Dots, unless PAM asks for what is typed to show. Nothing can be
          // typed while PAM checks, or while the card says it was wrong.
          TextInput {
            id: field
            anchors.fill: parent
            verticalAlignment: TextInput.AlignVCenter
            activeFocusOnPress: true
            clip: true
            enabled: agent.shown
            readOnly: agent.checking || agent.wrong
            echoMode: agent.echo ? TextInput.Normal : TextInput.Password
            passwordCharacter: "•"
            cursorVisible: activeFocus && !agent.checking && !agent.wrong
            color: agent.ink
            selectionColor: Util.alpha(agent.colors.accent, 0.45)
            selectedTextColor: agent.colors.text
            font.family: agent.family
            font.pixelSize: Style.font.iconLarge
            onAccepted: agent.answer()
            Keys.onPressed: function (event) {
              if (event.key !== Qt.Key_Escape) return
              agent.cancel()
              event.accepted = true
            }
          }

          // The empty field says what it is for, or how the answer went.
          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: field.text.length === 0
            textFormat: Text.PlainText
            text: agent.wrong ? "Wrong" : agent.checking ? "Checking..." : "Enter password"
            color: agent.ink
            opacity: agent.wrong ? 1 : 0.36
            font.family: agent.family
            font.pixelSize: Style.font.iconLarge
            elide: Text.ElideRight
          }

          // The empty field's cursor, which the words above would cover.
          Rectangle {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(1, Style.space(2))
            height: Style.space(24)
            visible: field.visible && field.activeFocus && field.text.length === 0 && !agent.checking && !agent.wrong
            color: agent.ink
          }

          MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            enabled: field.visible
            onClicked: field.forceActiveFocus()
          }
        }
      }
    }

    // What the request is for, on a tab above the card.
    Rectangle {
      anchors.horizontalCenter: card.horizontalCenter
      anchors.bottom: card.top
      anchors.bottomMargin: Style.space(10)
      width: Math.min(label.implicitWidth + Style.space(24), surface.width - Style.gapsOut * 2)
      height: Style.space(28)
      radius: Style.cornerRadius
      color: agent.colors.background

      Text {
        id: label
        anchors.fill: parent
        anchors.leftMargin: Style.space(12)
        anchors.rightMargin: Style.space(12)
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        textFormat: Text.PlainText
        text: PolkitModel.requestLabel(agent.requestMessage)
        color: agent.colors.text
        font.family: agent.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideMiddle
      }
    }
  }
}
