import QtQuick
import qs.Commons
import qs.Ui
import "Shelves.js" as Shelves

// The chevron's card: every icon the tray has, each with a button to pin it,
// to keep it on the bar, and one to hide it, to show it nowhere. A button
// asks for the change with flip(); the lists come back through <pinned> and
// <hidden> once the settings have it.
PopupCard {
  id: card

  property var icons: []
  property var pinned: []
  property var hidden: []
  property color ink
  property string face

  signal flip(string onto, string id)

  contentWidth: fittedContentWidth(Style.space(300))
  contentHeight: fittedContentHeight(lines.implicitHeight)

  Column {
    id: lines
    anchors.fill: parent
    spacing: Style.space(8)

    Text {
      text: "Tray icons"
      color: card.ink
      font.family: card.face
      font.pixelSize: Style.font.body
      font.bold: true
    }

    Text {
      width: lines.width
      text: "Pinned icons stay visible. Hidden icons never show."
      wrapMode: Text.WordWrap
      color: Qt.darker(card.ink, 1.4)
      font.family: card.face
      font.pixelSize: Style.font.caption
    }

    Text {
      visible: card.icons.length === 0
      text: "No tray items reporting."
      color: Qt.darker(card.ink, 1.5)
      font.family: card.face
      font.pixelSize: Style.font.bodySmall
      font.italic: true
    }

    Repeater {
      model: card.icons

      Item {
        id: line

        required property var modelData
        readonly property string key: String(modelData.id || "")

        width: lines.width
        implicitHeight: 28

        TrayGlyph {
          id: mark
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: 16
          height: 16
          source: line.modelData.icon
          tint: card.ink
        }

        Text {
          anchors.left: mark.right
          anchors.leftMargin: Style.space(10)
          anchors.right: hideButton.left
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          text: Shelves.name(line.modelData)
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: card.ink
          font.family: card.face
          font.pixelSize: Style.font.bodySmall
        }

        Choice {
          id: pinButton
          anchors.right: parent.right
          iconText: "\uf08d"
          text: card.pinned.indexOf(line.key) === -1 ? "Pin" : "Unpin"
          onClicked: card.flip("pinned", line.key)
        }

        Choice {
          id: hideButton
          anchors.right: pinButton.left
          anchors.rightMargin: Style.space(6)
          iconText: "\uf06e"
          text: card.hidden.indexOf(line.key) === -1 ? "Hide" : "Show"
          onClicked: card.flip("hidden", line.key)
        }
      }
    }
  }

  component Choice: Button {
    anchors.verticalCenter: parent.verticalCenter
    foreground: card.ink
    horizontalPadding: 8
    verticalPadding: 3
    iconSize: Style.font.bodySmall
    fontSize: Style.font.bodySmall
  }
}
