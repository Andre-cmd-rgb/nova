import QtQuick
import Quickshell
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// The bar's media widget: a play or pause mark and what plays, title and
// artist, scrolling through while it plays and does not fit. A click plays or
// pauses, a middle click skips on, the wheel goes back or on; a right click
// opens a card with the cover, the transport and every player to pick from.
// The media service (Service.qml) does the playing.
BarWidget {
  id: widget
  moduleName: "nova.media"

  readonly property var media: bar?.shell?.serviceFor("nova.media")
  readonly property var player: media ? media.activePlayer : null
  readonly property var players: media ? media.sourcePlayers : []
  readonly property bool playing: !!player && player.isPlaying
  readonly property bool shown: media ? media.hasMedia : false
  readonly property string title: player ? (player.trackTitle || "") : ""
  readonly property string artist: player ? (player.trackArtist || "") : ""
  // The bar shows a tooltip only while its widget says the pointer is on it.
  readonly property bool tooltipHovered: visible && pointer.containsMouse

  property bool cardOpen: false

  function close() { cardOpen = false }

  // Pause while it plays, play while it does not.
  function mark(isPlaying) {
    return isPlaying ? "\u{F03E4}" : "\u{F040A}"
  }

  // <action> on the player the card shows when <onShown>, else on the one
  // the service picks for it. No on-screen display: the bar shows the change.
  function act(action, onShown) {
    if (media) media.runAction(action, false, onShown ? media.playerKey(player) : undefined)
  }

  function isShown(candidate) {
    return player && candidate && media.playerKey(player) === media.playerKey(candidate)
  }

  visible: shown
  implicitWidth: shown ? onBar.implicitWidth + Style.space(14) : 0
  implicitHeight: barSize

  Row {
    id: onBar
    anchors.centerIn: parent
    spacing: Style.space(6)

    Glyph {
      id: stateMark
      anchors.verticalCenter: parent.verticalCenter
      text: widget.mark(widget.playing)
      color: widget.playing ? widget.bar.barForeground : Qt.darker(widget.bar.barForeground, 1.5)
      font.pixelSize: Style.font.body

      Behavior on color {
        enabled: !widget.bar || widget.bar.foregroundAnimationEnabled
        ColorAnimation { duration: 160 }
      }
    }

    // Title and artist in 180 px at most, and none on a side bar. Too long,
    // they scroll through, in from the right, while they play on a bar that
    // shows with the card closed: a frame each refresh, so only then.
    // Stopped, they are back at the start.
    Item {
      id: clipper
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(180, track.implicitWidth)
      height: stateMark.height
      clip: true
      visible: !widget.bar.vertical && widget.title !== ""

      Text {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        text: widget.artist ? widget.title + "  ·  " + widget.artist : widget.title
        textFormat: Text.PlainText
        color: widget.bar.barForeground
        font.family: widget.bar.fontFamily
        font.pixelSize: Style.font.body

        NumberAnimation on x {
          running: track.implicitWidth > clipper.width && !widget.cardOpen && !widget.bar.vertical
            && !widget.bar.barHidden && widget.playing
          onRunningChanged: if (!running) track.x = 0
          loops: Animation.Infinite
          duration: Math.max(6000, track.implicitWidth * 25)
          from: clipper.width
          to: -track.implicitWidth
          easing.type: Easing.Linear
        }
      }
    }
  }

  // A click puts the tooltip away, as on the bar's buttons.
  MouseArea {
    id: pointer
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    cursorShape: widget.player ? Qt.PointingHandCursor : Qt.ArrowCursor

    onEntered: if (widget.bar) widget.bar.showTooltip(widget, widget.shown ? widget.title + (widget.artist ? " — " + widget.artist : "") : "")
    onExited: if (widget.bar) widget.bar.hideTooltip(widget)
    onClicked: function(mouse) {
      if (widget.bar) widget.bar.hideTooltip(widget)
      if (!widget.player) return
      switch (mouse.button) {
      case Qt.RightButton: widget.cardOpen = !widget.cardOpen; break
      case Qt.MiddleButton: widget.act("next"); break
      default: widget.act("playPause")
      }
    }
    onWheel: function(wheel) {
      if (!widget.player || wheel.angleDelta.y === 0) return
      widget.act(wheel.angleDelta.y > 0 ? "previous" : "next")
    }
  }

  PopupCard {
    id: card
    anchorItem: widget
    bar: widget.bar
    owner: widget
    open: widget.cardOpen
    contentWidth: card.fittedContentWidth(Style.space(320))
    contentHeight: card.fittedContentHeight(body.implicitHeight)

    Column {
      id: body
      anchors.fill: parent
      spacing: Style.space(10)

      // The cover, or a note where there is none, beside the track.
      Row {
        width: parent.width
        spacing: Style.space(10)

        BorderSurface {
          width: Style.space(64)
          height: Style.space(64)
          radius: Style.spacing.labelGap
          color: Style.normalFillFor(widget.bar.foreground, Commons.Color.accent)
          borderSpec: Border.controlSpec("normal", widget.bar.foreground, Commons.Color.accent)

          Image {
            anchors.fill: parent
            anchors.margins: Style.space(2)
            visible: source !== ""
            source: widget.player && widget.player.trackArtUrl ? widget.player.trackArtUrl : ""
            // Covers come as large as 1200 px square, for 64 here.
            sourceSize: Qt.size(width, height)
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
          }

          Glyph {
            anchors.centerIn: parent
            visible: !widget.player || !widget.player.trackArtUrl
            text: "\u{F075A}"
            color: widget.bar.foreground
            font.pixelSize: Style.font.displayLarge
          }
        }

        Column {
          width: parent.width - Style.space(74)
          spacing: Style.space(4)

          Detail {
            text: widget.title || "Nothing playing"
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          Detail {
            text: widget.artist
            darker: 1.3
            font.pixelSize: Style.font.bodySmall
          }
          Detail {
            text: widget.player && widget.player.trackAlbum ? widget.player.trackAlbum : ""
            darker: 1.6
            font.pixelSize: Style.font.caption
          }
        }
      }

      // Back, play or pause, and on, for the player shown.
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)

        Transport {
          iconText: "\u{F04AE}"
          enabled: widget.player && widget.player.canGoPrevious
          onClicked: widget.act("previous", true)
        }
        Transport {
          iconText: widget.mark(widget.playing)
          iconSize: Style.font.iconLarge
          horizontalPadding: Style.spacing.panelGap
          enabled: widget.player && (widget.player.canTogglePlaying || widget.player.canPlay || widget.player.canPause)
          onClicked: widget.act("playPause", true)
        }
        Transport {
          iconText: "\u{F04AD}"
          enabled: widget.player && widget.player.canGoNext
          onClicked: widget.act("next", true)
        }
      }

      // With more than one player, each of them: a click makes it the one
      // shown and played.
      PanelSeparator {
        visible: widget.players.length > 1
        foreground: widget.bar.foreground
      }

      Column {
        id: playerList
        visible: widget.players.length > 1
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: widget.players

          BorderSurface {
            id: choice

            required property var modelData
            readonly property bool selected: widget.isShown(modelData)

            width: playerList.width
            height: line.implicitHeight + Style.space(10)
            radius: Style.spacing.labelGap
            color: selected ? Style.selectedFillFor(widget.bar.foreground, Commons.Color.accent) : "transparent"
            borderSpec: selected ? Border.controlSpec("normal", widget.bar.foreground, Commons.Color.accent) : Border.none()

            Row {
              id: line
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.leftMargin: choice.borderLeft + Style.space(8)
              anchors.rightMargin: choice.borderRight + Style.space(8)
              spacing: Style.space(8)

              Glyph {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(18)
                horizontalAlignment: Text.AlignHCenter
                text: widget.mark(choice.modelData && choice.modelData.isPlaying)
                color: widget.bar.foreground
                font.pixelSize: Style.font.body
              }

              // Its track's title and artist, or what it calls itself.
              Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(26)
                spacing: Style.space(1)

                Detail {
                  text: choice.modelData ? (choice.modelData.trackTitle || choice.modelData.identity || choice.modelData.desktopEntry || "Media source") : "Media source"
                  font.pixelSize: Style.font.bodySmall
                  font.bold: choice.selected
                }
                Detail {
                  text: choice.modelData && choice.modelData.trackArtist ? choice.modelData.trackArtist
                    : (choice.modelData && choice.modelData.identity ? choice.modelData.identity : "")
                  darker: 1.5
                  font.pixelSize: Style.font.caption
                }
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (widget.media) widget.media.selectPlayer(widget.media.playerKey(choice.modelData))
            }
          }
        }
      }
    }
  }

  // A mark in the bar's font.
  component Glyph: Text {
    textFormat: Text.PlainText
    font.family: widget.bar.fontFamily
  }

  // A line of the card in the bar's foreground, <darker> times darker, cut
  // short at its width; none while empty.
  component Detail: Glyph {
    property real darker: 1
    width: parent.width
    visible: text !== ""
    elide: Text.ElideRight
    color: darker === 1 ? widget.bar.foreground : Qt.darker(widget.bar.foreground, darker)
  }

  component Transport: Button {
    foreground: widget.bar.foreground
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY
    opacity: enabled ? 1.0 : 0.4
  }
}
