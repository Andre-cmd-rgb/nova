import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "../NotificationLogic.js" as NotificationLogic

// A toast as it looks: its picture or glyph, its summary in bold and its body
// below, three lines at most. A click is clicked(), a right click dismissed().
BorderSurface {
  id: root

  property string app: ""
  property string appIcon: ""
  property string summary: ""
  property string body: ""
  property string image: ""
  // A Nerd Font glyph for a toast with no picture, as nova-notification-send's
  // -g gives Nova's own toasts.
  property string glyph: ""
  property int cornerRadius: 0
  // The bar's font, for the glyph.
  property string fontFamily: ""

  readonly property bool hovered: pointer.hovered

  signal clicked()
  signal dismissed()

  // The notification's own picture (an avatar, a photo), or its app's icon.
  readonly property string picture: image.length > 0 ? image : iconUrl(appIcon)
  readonly property bool hasPicture: picture.length > 0
  readonly property bool hasGlyph: glyph.length > 0
  readonly property string plainBody: NotificationLogic.shownBody(body, app, appIcon)
  readonly property bool oneLine: plainBody.length === 0
  // A one-line toast with a glyph and no picture has the glyph small, in line.
  readonly property bool glyphInline: NotificationLogic.compactGlyph(glyph, picture, oneLine)
  // A one-line toast whose summary starts with its own glyph has no icon.
  readonly property bool noIcon: oneLine && !hasGlyph && NotificationLogic.startsWithGlyph(summary)
  readonly property real margin: oneLine ? Style.space(7) : Style.space(10)

  // An icon's name looked up in the theme, with `check` so that a name it
  // does not have gives nothing rather than Qt's missing-image picture.
  function iconUrl(icon) {
    var value = String(icon || "")
    if (value.length === 0) return ""
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  implicitWidth: Style.space(380)
  implicitHeight: row.implicitHeight + margin * 2 + borderTop + borderBottom
  radius: cornerRadius
  color: Commons.Color.notifications.background
  borderSpec: Border.surfaceSpec("notifications", "border", Commons.Color.notifications.border, Math.max(1, Style.space(2)))
  clip: true

  HoverHandler { id: pointer }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onClicked: function (mouse) {
      if (mouse.button === Qt.RightButton) root.dismissed()
      else root.clicked()
    }
  }

  RowLayout {
    id: row
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.topMargin: root.borderTop + root.margin
    anchors.leftMargin: root.borderLeft + Style.space(12)
    anchors.rightMargin: root.borderRight + Style.space(12)
    spacing: root.noIcon ? 0 : root.glyphInline ? Style.space(8) : Style.space(12)

    // The picture, or the glyph large when there is none or it will not load;
    // with neither, or a picture that will not load and no glyph, no room.
    Item {
      id: icon
      Layout.preferredWidth: visible ? Style.space(40) : 0
      Layout.preferredHeight: visible ? Style.space(40) : 0
      Layout.alignment: Qt.AlignVCenter
      visible: !root.noIcon && !root.glyphInline && (root.hasPicture || root.hasGlyph)
        && (root.hasGlyph || photo.status !== Image.Error)

      Image {
        id: photo
        anchors.fill: parent
        source: root.picture
        sourceSize.width: icon.width * Screen.devicePixelRatio
        sourceSize.height: icon.height * Screen.devicePixelRatio
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        visible: !root.hasGlyph || status === Image.Ready
      }

      Text {
        textFormat: Text.PlainText
        anchors.centerIn: parent
        visible: root.hasGlyph && photo.status !== Image.Ready
        text: root.glyph
        color: Commons.Color.notifications.text
        font.family: root.fontFamily
        font.pixelSize: Style.font.displayLarge
      }
    }

    Text {
      textFormat: Text.PlainText
      Layout.alignment: Qt.AlignVCenter
      visible: root.glyphInline
      text: root.glyph
      color: Commons.Color.notifications.text
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
    }

    ColumnLayout {
      Layout.fillWidth: true
      Layout.alignment: Qt.AlignVCenter
      spacing: Style.space(2)

      // Plain text: the summary is one line of text by the specification,
      // and anything richer could only come from a sender up to no good.
      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        visible: root.summary.length > 0
        text: root.summary
        font.family: Style.font.family
        color: Commons.Color.notifications.text
        font.pixelSize: Style.font.title
        font.bold: true
        wrapMode: Text.WordWrap
        elide: Text.ElideRight
        maximumLineCount: 2
      }

      // StyledText, for the markup the server says it takes, its images
      // dropped (see NotificationLogic.withoutImages).
      Text {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(2)
        visible: !root.oneLine
        text: NotificationLogic.bodyMarkup(root.body, root.app, root.appIcon)
        textFormat: Text.StyledText
        font.family: Style.font.family
        color: Qt.darker(Commons.Color.notifications.text, 1.15)
        font.pixelSize: Style.font.title
        wrapMode: Text.WordWrap
        elide: Text.ElideRight
        maximumLineCount: 3
      }
    }
  }
}
