import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// One app in a list: its icon, name and summary, and its button: Get, Open,
// or how far its install is. A click elsewhere on it opens its page.
Item {
  id: tile

  property var app: null
  property var store: null

  readonly property var st: store && app ? store.statusOf(app) : ({ action: "get", progress: -1, text: "" })

  implicitHeight: Style.space(68)

  Rectangle {
    anchors.fill: parent
    anchors.margins: Style.space(2)
    radius: Style.cornerRadius
    color: hover.hovered ? Style.hoverFill : "transparent"
  }

  HoverHandler {
    id: hover
    cursorShape: Qt.PointingHandCursor
  }

  TapHandler {
    onTapped: if (tile.store) tile.store.show(tile.app)
  }

  AppIcon {
    id: icon
    anchors.left: parent.left
    anchors.leftMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    app: tile.app
    size: Style.space(44)
  }

  Column {
    anchors.left: icon.right
    anchors.leftMargin: Style.space(12)
    anchors.right: action.left
    anchors.rightMargin: Style.space(12)
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.space(3)

    Text {
      width: parent.width
      text: tile.app ? tile.app.name : ""
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      font.bold: true
      elide: Text.ElideRight
      textFormat: Text.PlainText
    }

    Caption {
      width: parent.width
      visible: tile.st.action !== "busy"
      text: tile.app ? tile.app.summary || "" : ""
      wrapMode: Text.NoWrap
      elide: Text.ElideRight
    }

    ProgressLine {
      visible: tile.st.action === "busy"
      width: parent.width
      fraction: tile.st.progress
    }
  }

  Item {
    id: action
    anchors.right: parent.right
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    width: Style.space(64)
    height: button.implicitHeight

    Button {
      id: button
      anchors.fill: parent
      visible: tile.st.action === "get" || (tile.st.action === "open" && tile.store && tile.store.canOpen(tile.app))
      text: tile.st.action === "open" ? "Open" : "Get"
      bordered: true
      onClicked: {
        if (tile.st.action === "open") tile.store.launch(tile.app)
        else tile.store.install(tile.app, "")
      }
    }

    Caption {
      anchors.centerIn: parent
      visible: tile.st.action === "busy"
      text: tile.st.progress >= 0 ? Math.round(tile.st.progress * 100) + "%" : "…"
    }

    Caption {
      anchors.centerIn: parent
      visible: tile.st.action === "open" && !button.visible
      text: "Installed"
    }
  }
}
