import QtQuick
import QtQuick.Effects
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// What the lock screen shows, for the lock and the greeter alike: the
// desktop's background, blurred, and on it a card with the password field.
// The holder keeps what is typed and checks it; the view shows it as dots,
// hands every edit back, and says how the last check went.
//
//   backdrop                 the background, small and blurred already
//                            (nova-theme makes it): read at once, so that
//                            the first frame is the finished lock screen
//   picture                  the background's file, blurred here where
//                            there is no backdrop
//   showPicture              whether to show either at all
//   fadeIn                   comes in from black (the boot's lock, the
//                            greeter), rather than at once
//   fingerReady              a finger can open it too: the mark shows
//   typed                    the holder's copy of the field
//   checking, failure        a check under way; why the last one failed
//   takesInput               whether the field takes keys
//
// Nothing is drawn until the picture is ready: the window under the view is
// black, and a frame of flat colour or a card without its picture would
// flash (a light theme's background was a white flash before the lock's
// picture came). A picture that never comes is waited for 1.5 s; then the
// theme's background stands in for it. A fade starts from the window's
// first frame, drawn black: a new window's first frame can take longer than
// the fade. `ready`, `framed` and `revealed` say how far it is.
//
// edited(text) and submitted(text) hand the field back; failureSeen() says
// the user typed past a failure; stirred() is any key, click or move, for the
// holder to keep the screens on.
Item {
  id: view

  property string backdrop: ""
  property string picture: ""
  property bool showPicture: true
  property bool fadeIn: false
  property bool fingerReady: false
  property string typed: ""
  property bool checking: false
  property string failure: ""
  property bool takesInput: true

  signal edited(string text)
  signal submitted(string text)
  signal failureSeen()
  signal stirred()

  // shell.toml's [lock] colours.
  readonly property QtObject ink: Commons.Color.lock
  readonly property bool failing: failure !== ""
  // The words in the empty field at a little over the heading's size, the
  // dots larger again and a little apart.
  readonly property int wordSize: Math.round(Style.font.heading * 1.125)
  readonly property int dotSize: Math.round(Style.font.heading * 1.33)
  readonly property int dotGap: Math.round(Style.font.heading * 0.19)

  // The backdrop is shown, or else the picture blurred here, or else, the
  // picture having failed or been waited for long enough, nothing but the
  // theme's background.
  readonly property bool backdropShown: showPicture && premade.status === Image.Ready
  readonly property bool pictureShown: backdropShown || (photo.item !== null && photo.item.status === Image.Ready)
  readonly property bool ready: !showPicture || pictureShown || waited
    || (!backdropShown && (picture === "" || (photo.item !== null && photo.item.status === Image.Error)))
  property bool waited: false
  // The window has shown a frame; a view that does not fade need not wait.
  property bool framed: !fadeIn
  readonly property bool shows: ready && framed
  property bool revealed: false

  function focusField() {
    field.forceActiveFocus()
  }

  onTypedChanged: field.show(typed)
  onTakesInputChanged: if (takesInput) Qt.callLater(focusField)
  onShowsChanged: if (shows) revealed = true
  Component.onCompleted: {
    field.show(typed)
    if (takesInput) Qt.callLater(focusField)
    if (shows) revealed = true
  }

  Connections {
    target: view.framed ? null : view.Window.window
    function onFrameSwapped() {
      view.framed = true
    }
  }

  // Waited for long enough: shown as it is.
  Timer {
    interval: 1500
    running: !view.revealed
    onTriggered: {
      view.waited = true
      view.framed = true
    }
  }

  // Under all that is drawn, so that the field takes its own clicks.
  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    onPositionChanged: view.stirred()
    onClicked: {
      view.stirred()
      view.focusField()
    }
  }

  // All that is drawn, at once or faded in from black once it is ready. The
  // field takes keys while it waits: a password typed then is not lost.
  Item {
    id: content
    anchors.fill: parent
    opacity: view.revealed ? 1 : 0

    // Set before the first frame when the view is ready by then, so that
    // only a fade asked for, or a picture still loading, is animated.
    Behavior on opacity {
      enabled: view.fadeIn || !view.backdropShown
      NumberAnimation { duration: 240; easing.type: Easing.OutCubic }
    }

    // The theme's background where no picture shows.
    Rectangle {
      anchors.fill: parent
      visible: !view.pictureShown
      color: Commons.Color.background
    }

    // A few hundred pixels a side, read before the first frame and scaled up
    // smoothly: blurred this much, nothing is lost by it. The file is read
    // anew for each view, as nova-theme replaces it in place.
    Image {
      id: premade
      anchors.fill: parent
      source: view.showPicture && view.backdrop !== "" ? Util.fileUrl(view.backdrop) : ""
      fillMode: Image.PreserveAspectCrop
      asynchronous: false
      cache: false
      smooth: true
    }

    // No backdrop (none made yet, or one that cannot be read): the picture,
    // blurred here, with a little of its contrast taken out.
    Loader {
      id: photo
      anchors.fill: parent
      active: view.showPicture && view.picture !== "" && premade.status !== Image.Ready && premade.status !== Image.Loading
      sourceComponent: Item {
        readonly property alias status: picture.status

        Image {
          id: picture
          anchors.fill: parent
          source: Util.fileUrl(view.picture)
          // Decoded at a quarter of the screen's size: the blur below leaves
          // no detail finer than that (measured: at most 5 levels of 255
          // apart from a full-size decode, 0.25 on average), and the picture
          // comes sooner and holds a sixteenth of the memory.
          sourceSize: Qt.size(Math.ceil(width / 4), Math.ceil(height / 4))
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
        }

        MultiEffect {
          anchors.fill: picture
          source: picture
          autoPaddingEnabled: false
          blurEnabled: picture.status === Image.Ready
          blur: 1.0
          blurMax: 128
          blurMultiplier: 1.25
          contrast: -0.08
        }
      }
    }

    // The card in the middle of the screen; its border is the failure's
    // colour while a failure shows.
    BorderSurface {
      id: card

      // The field keeps 18 px from the border on both sides, and on both
      // sides as much again as the finger mark takes, so that the dots stay
      // centred and never run under the mark.
      readonly property real side: edge.right + 18 + (view.fingerReady ? Math.round(mark.implicitWidth + 12) : 0)

      anchors.centerIn: parent
      width: 381
      height: 67
      radius: Style.cornerRadius
      clip: true
      color: view.ink.background
      frame: Border.surfaceSpec("lock", view.failing ? "border-error" : "border-active",
        view.failing ? view.ink.borderError : view.ink.borderActive, 3, "border-alpha")

      TextInput {
        id: field

        // True while the holder's text is written in, which is not an edit.
        property bool showing: false
        readonly property bool dotted: text.length > 0
        // Dots too many for the field at full size are drawn smaller, so that
        // each key still shows one more.
        readonly property real squeeze: dots.advanceWidth > 0 ? Math.min(1, (width - 4) / dots.advanceWidth) : 1

        function show(value) {
          if (text === value) return
          showing = true
          text = value
          showing = false
        }

        // Back to the holder, and the field empty.
        function empty() {
          view.edited("")
        }

        x: card.edge.left + card.side - card.edge.right
        y: card.edge.top
        width: card.width - x - card.side
        height: card.height - card.edge.top - card.edge.bottom
        clip: true

        echoMode: TextInput.Password
        passwordCharacter: "●"
        passwordMaskDelay: 0
        // Nothing is typed while a password is checked.
        enabled: view.takesInput && !view.checking
        readOnly: view.checking
        activeFocusOnPress: true

        horizontalAlignment: TextInput.AlignHCenter
        verticalAlignment: TextInput.AlignVCenter
        font.family: Style.font.family
        font.pixelSize: dotted ? Math.max(1, Math.floor(view.dotSize * squeeze)) : view.wordSize
        font.letterSpacing: dotted ? view.dotGap * squeeze : 0
        color: view.ink.text
        selectionColor: view.ink.selection
        selectedTextColor: view.ink.text

        // A cursor only among dots, and not while a check runs or a failure
        // shows. TextInput turns it on as it takes the focus and turns it off
        // only when what this reads changes, so it reads one value.
        cursorVisible: activeFocus && view.takesInput && !view.checking && !view.failing && dotted
        cursorDelegate: Rectangle {
          width: 2
          visible: field.cursorVisible
          color: view.ink.text
        }

        // An edit goes back to the holder; a key typed keeps the screens on
        // and puts a failure away.
        onTextChanged: {
          if (!showing) view.edited(text)
          if (!dotted) return
          view.stirred()
          if (view.failing) view.failureSeen()
        }

        // Return hands over what the holder has, and the field starts again.
        onAccepted: {
          const given = view.typed
          empty()
          if (given !== "") view.submitted(given)
        }

        // Escape and Ctrl+U empty the field, as a terminal's line does.
        Keys.onPressed: event => {
          view.stirred()
          if (event.key === Qt.Key_Escape || (event.key === Qt.Key_U && event.modifiers & Qt.ControlModifier)) {
            empty()
            event.accepted = true
          }
        }

        TextMetrics {
          id: dots
          text: "●".repeat(field.text.length)
          font.family: Style.font.family
          font.pixelSize: view.dotSize
          font.letterSpacing: view.dotGap
        }
      }

      // In the empty field: "Enter Password", "Checking…" while a check runs,
      // or in italics why the last one failed.
      Words {
        anchors.fill: field
        visible: !field.dotted
        text: view.checking ? "Checking…" : view.failing ? view.failure : "Enter Password"
        elide: Text.ElideRight
        font.pixelSize: view.wordSize
        font.italic: view.failing && !view.checking
        color: view.checking ? view.ink.text : view.failing ? view.ink.textError : view.ink.placeholder
      }

      // A finger enrolled: the mark inside the right edge says a touch opens
      // the lock too.
      Words {
        id: mark
        visible: view.fingerReady
        anchors.right: parent.right
        anchors.rightMargin: card.edge.right + 18
        anchors.verticalCenter: parent.verticalCenter
        text: "\u{F0237}"
        font.pixelSize: Math.round(view.wordSize * 1.1)
        color: view.ink.placeholder
      }
    }
  }

  component Words: Text {
    textFormat: Text.PlainText
    font.family: Style.font.family
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
  }
}
