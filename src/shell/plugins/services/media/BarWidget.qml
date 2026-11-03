import QtQuick
import Quickshell
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// What plays, on the bar: a play or pause glyph and the title and artist,
// which scroll while they are too long and playing. A click plays or pauses,
// a middle click skips, the wheel steps back or on; a right click opens a
// card with the cover, the controls, and every player to choose from. All of
// it through the media service (Service.qml).
BarWidget {
  id: root
  moduleName: "nova.media"

  readonly property var mediaService: bar?.shell?.serviceFor("nova.media")
  readonly property var activePlayer: mediaService ? mediaService.activePlayer : null
  readonly property var sourcePlayers: mediaService ? mediaService.sourcePlayers : []
  readonly property bool playing: !!activePlayer && activePlayer.isPlaying

  readonly property bool hasMedia: activePlayer !== null && (activePlayer.trackTitle || activePlayer.trackArtist)
  readonly property string title: activePlayer ? (activePlayer.trackTitle || "") : ""
  readonly property string artist: activePlayer ? (activePlayer.trackArtist || "") : ""
  readonly property string playIcon: playing ? "󰏤" : "󰐊"
  // The bar shows a tooltip only while its widget says the pointer is on it.
  readonly property bool tooltipHovered: visible && pointer.containsMouse

  property bool popupOpen: false

  function close() { popupOpen = false }

  // The action, on the player the card shows if `shown`, else on the one
  // the service picks for it. No on-screen display: the bar shows what
  // changed.
  function act(action, shown) {
    if (mediaService) mediaService.runAction(action, false, shown ? mediaService.playerKey(activePlayer) : undefined)
  }

  visible: hasMedia
  implicitWidth: hasMedia ? line.implicitWidth + Style.space(14) : 0
  implicitHeight: barSize

  Row {
    id: line
    anchors.centerIn: parent
    spacing: Style.space(6)

    Text {
      id: glyph
      anchors.verticalCenter: parent.verticalCenter
      text: root.playIcon
      textFormat: Text.PlainText
      color: root.playing ? root.bar.barForeground : Qt.darker(root.bar.barForeground, 1.5)
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.body

      Behavior on color {
        enabled: !root.bar || root.bar.foregroundAnimationEnabled
        ColorAnimation { duration: 160 }
      }
    }

    // Title and artist in at most 180 px; none on a side bar.
    Item {
      id: trackClip
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(180, track.implicitWidth)
      height: glyph.height
      clip: true
      visible: !root.bar.vertical && root.title !== ""

      Text {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        text: root.title + (root.artist ? "  ·  " + root.artist : "")
        textFormat: Text.PlainText
        color: root.bar.barForeground
        font.family: root.bar.fontFamily
        font.pixelSize: Style.font.body

        // Too long, it scrolls through, in from the right, while it plays
        // on a bar on screen with the card closed: a frame each refresh,
        // so only then. Stopped, it is back at its start.
        NumberAnimation on x {
          running: track.implicitWidth > trackClip.width && !root.popupOpen && !root.bar.vertical
            && !root.bar.barHidden && root.playing
          onRunningChanged: if (!running) track.x = 0
          loops: Animation.Infinite
          duration: Math.max(6000, track.implicitWidth * 25)
          from: trackClip.width
          to: -track.implicitWidth
          easing.type: Easing.Linear
        }
      }
    }
  }

  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.activePlayer ? Qt.PointingHandCursor : Qt.ArrowCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    // A click puts the tooltip away, as on the bar's buttons.
    onClicked: function(mouse) {
      if (root.bar) root.bar.hideTooltip(root)
      if (!root.activePlayer) return
      if (mouse.button === Qt.RightButton) root.popupOpen = !root.popupOpen
      else root.act(mouse.button === Qt.MiddleButton ? "next" : "playPause")
    }
    onWheel: function(wheel) {
      if (!root.activePlayer) return
      if (wheel.angleDelta.y > 0) root.act("previous")
      else if (wheel.angleDelta.y < 0) root.act("next")
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.hasMedia ? root.title + (root.artist ? " — " + root.artist : "") : "")
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  PopupCard {
    id: card
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: card.fittedContentWidth(Style.space(320))
    contentHeight: card.fittedContentHeight(cardColumn.implicitHeight)

    Column {
      id: cardColumn
      anchors.fill: parent
      spacing: Style.space(10)

      // The cover, or a note where there is none, and the track.
      Row {
        width: parent.width
        spacing: Style.space(10)

        BorderSurface {
          width: Style.space(64)
          height: Style.space(64)
          radius: Style.spacing.labelGap
          color: Style.normalFillFor(root.bar.foreground, Commons.Color.accent)
          borderSpec: Border.controlSpec("normal", root.bar.foreground, Commons.Color.accent)

          Image {
            anchors.fill: parent
            anchors.margins: Style.space(2)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            source: root.activePlayer && root.activePlayer.trackArtUrl ? root.activePlayer.trackArtUrl : ""
            // Covers come as large as 1200 px square, for 64 here.
            sourceSize: Qt.size(width, height)
            visible: source !== ""
          }

          Text {
            anchors.centerIn: parent
            visible: !root.activePlayer || !root.activePlayer.trackArtUrl
            text: "󰝚"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.displayLarge
          }
        }

        Column {
          width: parent.width - Style.space(74)
          spacing: Style.space(4)

          Detail {
            text: root.title || "Nothing playing"
            color: root.bar.foreground
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Detail {
            text: root.artist
            color: Qt.darker(root.bar.foreground, 1.3)
            font.pixelSize: Style.font.bodySmall
          }

          Detail {
            text: root.activePlayer && root.activePlayer.trackAlbum ? root.activePlayer.trackAlbum : ""
            color: Qt.darker(root.bar.foreground, 1.6)
            font.pixelSize: Style.font.caption
          }
        }
      }

      // Back, play or pause, on: for the player shown.
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)

        TransportButton {
          iconText: "󰒮"
          enabled: root.activePlayer && root.activePlayer.canGoPrevious
          onClicked: root.act("previous", true)
        }

        TransportButton {
          iconText: root.playIcon
          horizontalPadding: Style.spacing.panelGap
          iconSize: Style.font.iconLarge
          enabled: root.activePlayer && (root.activePlayer.canTogglePlaying || root.activePlayer.canPlay || root.activePlayer.canPause)
          onClicked: root.act("playPause", true)
        }

        TransportButton {
          iconText: "󰒭"
          enabled: root.activePlayer && root.activePlayer.canGoNext
          onClicked: root.act("next", true)
        }
      }

      // With more than one player, each of them; a click makes it the one
      // shown and played.
      PanelSeparator {
        visible: root.sourcePlayers.length > 1
        foreground: root.bar.foreground
      }

      Column {
        id: sources
        visible: root.sourcePlayers.length > 1
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: root.sourcePlayers

          BorderSurface {
            id: entry

            required property var modelData
            readonly property bool selected: root.activePlayer && modelData
              && root.mediaService.playerKey(root.activePlayer) === root.mediaService.playerKey(modelData)

            width: sources.width
            height: sourceLine.implicitHeight + Style.space(10)
            radius: Style.spacing.labelGap
            color: selected ? Style.selectedFillFor(root.bar.foreground, Commons.Color.accent) : "transparent"
            borderSpec: selected ? Border.controlSpec("normal", root.bar.foreground, Commons.Color.accent) : Border.none()

            Row {
              id: sourceLine
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: entry.borderLeft + Style.space(8)
              anchors.rightMargin: entry.borderRight + Style.space(8)
              spacing: Style.space(8)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(18)
                horizontalAlignment: Text.AlignHCenter
                text: entry.modelData && entry.modelData.isPlaying ? "󰏤" : "󰐊"
                textFormat: Text.PlainText
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }

              // Its track's title and artist, or its name.
              Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(26)
                spacing: Style.space(1)

                Detail {
                  text: entry.modelData ? (entry.modelData.trackTitle || entry.modelData.identity || entry.modelData.desktopEntry || "Media source") : "Media source"
                  color: root.bar.foreground
                  font.pixelSize: Style.font.bodySmall
                  font.bold: entry.selected
                }

                Detail {
                  text: entry.modelData && entry.modelData.trackArtist ? entry.modelData.trackArtist
                    : (entry.modelData && entry.modelData.identity ? entry.modelData.identity : "")
                  color: Qt.darker(root.bar.foreground, 1.5)
                  font.pixelSize: Style.font.caption
                }
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (root.mediaService) root.mediaService.selectPlayer(root.mediaService.playerKey(entry.modelData))
            }
          }
        }
      }
    }
  }

  // A line of the card, cut short at its width; none while empty.
  component Detail: Text {
    width: parent.width
    visible: text !== ""
    textFormat: Text.PlainText
    elide: Text.ElideRight
    font.family: root.bar.fontFamily
  }

  component TransportButton: Button {
    foreground: root.bar.foreground
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY
    opacity: enabled ? 1.0 : 0.4
  }
}
