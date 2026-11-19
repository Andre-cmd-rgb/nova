import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons

// An app's icon: the one the icon theme has by its name, which an installed
// app brings in every size; else the catalog's picture of it (128 pixels at
// most); else its initial on a tile.
Item {
  id: icon

  property var app: null
  property real size: Style.space(48)

  implicitWidth: size
  implicitHeight: size

  readonly property string source: {
    if (!app) return ""
    var themed = app.iconName ? Quickshell.iconPath(app.iconName, true) : ""
    if (themed) return themed
    return app.icon ? Util.fileUrl(app.icon) : ""
  }

  Image {
    id: picture
    anchors.fill: parent
    source: icon.source
    sourceSize: Qt.size(Math.ceil(icon.size * 2), Math.ceil(icon.size * 2))
    fillMode: Image.PreserveAspectFit
    asynchronous: true
    smooth: true
    mipmap: true
    visible: status === Image.Ready
  }

  Rectangle {
    anchors.fill: parent
    anchors.margins: icon.size * 0.06
    visible: picture.status !== Image.Ready
    radius: width * 0.22
    color: Qt.alpha(Commons.Color.foreground, 0.08)

    Text {
      anchors.centerIn: parent
      text: icon.app ? String(icon.app.name || "").charAt(0).toUpperCase() : ""
      color: Commons.Color.quieter(Commons.Color.foreground, Commons.Color.background, 0.7)
      font.family: Style.font.family
      font.pixelSize: Math.round(icon.size * 0.42)
      font.bold: true
      textFormat: Text.PlainText
    }
  }
}
