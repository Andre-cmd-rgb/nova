import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../NotificationLogic.js" as Notes

// A toast, a row of the service's toasts: its picture or glyph, its summary
// in bold and its body below, three lines at most. A click invokes it, a
// right click dismisses it. It counts down its lifetime in one timer for
// what is left, stopped while the pointer is on it on any screen, and starts
// over when its sender changes what it says.
BorderSurface {
  id: toast

  required property var service

  required property int index
  required property int originalId
  required property double timestamp
  required property string app
  required property string appIcon
  required property string summary
  required property string body
  required property string image
  // A Nerd Font glyph, for a toast with no picture, as
  // nova-notification-send's -g gives Nova's own.
  required property string glyph
  required property int urgency
  required property double expireTimeout

  // Its own picture (an avatar, a photo), or its app's icon.
  readonly property string picture: image !== "" ? image : iconSource(appIcon)
  readonly property bool oneLine: Notes.shownBody(body, app, appIcon) === ""
  // One line with a glyph and no picture: the glyph small, in line.
  readonly property bool smallGlyph: glyph !== "" && picture === "" && oneLine
  // One line whose summary starts with its own glyph: no icon.
  readonly property bool bare: oneLine && glyph === "" && Notes.startsWithGlyph(summary)
  readonly property real margin: oneLine ? Style.space(7) : Style.space(10)
  readonly property string glyphFont: service.shell && service.shell.bar ? service.shell.bar.fontFamily : ""

  readonly property string stem: Notes.stem(toast)
  readonly property real lifetime: Notes.lifetime(urgency, expireTimeout)
  readonly property bool ticking: lifetime > 0 && !service.held[stem]
  // A toast that goes with the pointer on it lets go of it.
  property bool pointed: false

  // An icon by its name, from the theme; `check`, so that a name it lacks
  // gives nothing rather than Qt's missing-image picture.
  function iconSource(icon) {
    var value = String(icon || "")
    if (value === "" || value.startsWith("file://") || value.startsWith("image://")) return value
    return value.startsWith("/") ? Util.fileUrl(value) : Quickshell.iconPath(value, true)
  }

  onTickingChanged: ticking ? countdown.go() : countdown.hold()
  onLifetimeChanged: {
    countdown.hold()
    countdown.go()
  }
  onSummaryChanged: countdown.anew()
  onBodyChanged: countdown.anew()
  onImageChanged: countdown.anew()
  Component.onCompleted: countdown.go()
  Component.onDestruction: if (pointed) service.hold(stem, false)

  Timer {
    id: countdown

    // The share of the lifetime left, and when it last began counting.
    property real left: 1.0
    property real from: 0

    function go() {
      stop()
      if (!toast.ticking) return
      from = Date.now()
      interval = Math.max(1, Math.round(left * toast.lifetime))
      start()
    }

    function hold() {
      if (!running) return
      stop()
      if (toast.lifetime > 0) left = Math.max(0, left - (Date.now() - from) / toast.lifetime)
    }

    function anew() {
      left = 1.0
      go()
    }

    onTriggered: {
      left = 0
      toast.service.expire(toast.index)
    }
  }

  implicitWidth: Style.space(380)
  implicitHeight: content.implicitHeight + margin * 2 + borderTop + borderBottom
  radius: Style.cornerRadius
  color: Commons.Color.notifications.background
  borderSpec: Border.surfaceSpec("notifications", "border", Commons.Color.notifications.border, Math.max(1, Style.space(2)))
  clip: true

  HoverHandler {
    onHoveredChanged: {
      toast.pointed = hovered
      toast.service.hold(toast.stem, hovered)
    }
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: mouse => mouse.button === Qt.RightButton ? toast.service.dismiss(toast.index) : toast.service.invoke(toast.index)
  }

  RowLayout {
    id: content
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: toast.borderTop + toast.margin
    anchors.leftMargin: toast.borderLeft + Style.space(12)
    anchors.rightMargin: toast.borderRight + Style.space(12)
    spacing: toast.bare ? 0 : toast.smallGlyph ? Style.space(8) : Style.space(12)

    // The picture, or the glyph large where there is none or it will not
    // load; with neither, or a picture that will not load and no glyph, no
    // room at all.
    Item {
      id: badge
      Layout.preferredWidth: visible ? Style.space(40) : 0
      Layout.preferredHeight: visible ? Style.space(40) : 0
      Layout.alignment: Qt.AlignVCenter
      visible: !toast.bare && !toast.smallGlyph && (toast.picture !== "" || toast.glyph !== "")
        && (toast.glyph !== "" || photo.status !== Image.Error)

      Image {
        id: photo
        anchors.fill: parent
        source: toast.picture
        sourceSize.width: badge.width * Screen.devicePixelRatio
        sourceSize.height: badge.height * Screen.devicePixelRatio
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        visible: toast.glyph === "" || status === Image.Ready
      }

      Glyph {
        anchors.centerIn: parent
        visible: toast.glyph !== "" && photo.status !== Image.Ready
        font.pixelSize: Style.font.displayLarge
      }
    }

    Glyph {
      Layout.alignment: Qt.AlignVCenter
      visible: toast.smallGlyph
      font.pixelSize: Style.font.icon
    }

    ColumnLayout {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      spacing: Style.space(2)

      // Plain text: a summary is one line of text by the specification, and
      // anything richer could only come from a sender up to no good.
      Words {
        textFormat: Text.PlainText
        visible: toast.summary !== ""
        text: toast.summary
        color: Commons.Color.notifications.text
        font.bold: true
        maximumLineCount: 2
      }

      // StyledText, the markup the server says it takes, without its images
      // (see Notes.withoutImages).
      Words {
        Layout.topMargin: Style.space(2)
        textFormat: Text.StyledText
        visible: !toast.oneLine
        text: Notes.bodyMarkup(toast.body, toast.app, toast.appIcon)
        color: Qt.darker(Commons.Color.notifications.text, 1.15)
        maximumLineCount: 3
      }
    }
  }

  // The toast's glyph, in the bar's font.
  component Glyph: Text {
    textFormat: Text.PlainText
    text: toast.glyph
    color: Commons.Color.notifications.text
    font.family: toast.glyphFont
  }

  component Words: Text {
    Layout.fillWidth: true
    font.family: Style.font.family
    font.pixelSize: Style.font.title
    wrapMode: Text.WordWrap
    elide: Text.ElideRight
  }
}
