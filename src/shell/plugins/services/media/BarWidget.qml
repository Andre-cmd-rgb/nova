import QtQuick
import Quickshell
import qs.Ui
import qs.Commons
import qs.Commons as Commons
import "MediaModel.js" as Media

// The bar's media widget: a play or pause mark and what plays, title and
// artist, running past while it plays and does not fit. A click plays or
// pauses, a middle click skips on, the wheel goes back or on; a right click
// opens a card with the cover, the transport and every player to pick from.
// The media service plays.
BarWidget {
  id: widget
  moduleName: "nova.media"

  readonly property var media: bar?.shell?.serviceFor("nova.media")
  readonly property var player: media ? media.activePlayer : null
  readonly property var listed: media ? media.listed : []
  readonly property bool playing: !!player && player.isPlaying
  readonly property string title: player ? player.trackTitle || "" : ""
  readonly property string artist: player ? player.trackArtist || "" : ""
  // Shown for a track with a title or an artist.
  readonly property bool shown: title !== "" || artist !== ""
  // The bar shows a tooltip only while its widget says the pointer is on it.
  readonly property bool tooltipHovered: visible && pointer.containsMouse

  property bool cardOpen: false

  function close() {
    cardOpen = false
  }

  // A player playing shows pause, one stopped play.
  function mark(isPlaying) {
    return isPlaying ? "\u{F03E4}" : "\u{F040A}"
  }

  // The action on the player the card shows when `onShown`, else on the one
  // the service picks; with no on-screen display, as the bar shows it.
  function act(action, onShown) {
    if (media) media.press(action, true, onShown ? Media.playerKey(player) : "")
  }

  visible: shown
  implicitWidth: shown ? strip.implicitWidth + Style.space(14) : 0
  implicitHeight: barSize

  Row {
    id: strip
    anchors.centerIn: parent
    spacing: Style.space(6)

    BarText {
      id: playMark
      anchors.verticalCenter: parent.verticalCenter
      text: widget.mark(widget.playing)
      color: widget.playing ? widget.bar.barForeground : Qt.darker(widget.bar.barForeground, 1.5)
      font.pixelSize: Style.font.body

      Behavior on color {
        enabled: !widget.bar || widget.bar.foregroundAnimationEnabled
        ColorAnimation { duration: 160 }
      }
    }

    // 180 px of title and artist, none on a side bar. Longer, they run past,
    // in from the right, while they play on a bar that shows with the card
    // closed: a frame each refresh, so only then. Stopped, they are back at
    // the start.
    Item {
      id: ticker
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(180, tape.implicitWidth)
      height: playMark.height
      clip: true
      visible: !widget.vertical && widget.title !== ""

      BarText {
        id: tape
        anchors.verticalCenter: parent.verticalCenter
        text: widget.title + (widget.artist ? "  ·  " + widget.artist : "")
        color: widget.bar.barForeground
        font.pixelSize: Style.font.body

        NumberAnimation on x {
          running: tape.implicitWidth > ticker.width && !widget.cardOpen && !widget.vertical
            && !widget.bar.barHidden && widget.playing
          onRunningChanged: if (!running) tape.x = 0
          loops: Animation.Infinite
          duration: Math.max(6000, tape.implicitWidth * 25)
          from: ticker.width
          to: -tape.implicitWidth
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
      if (mouse.button === Qt.RightButton) widget.cardOpen = !widget.cardOpen
      else widget.act(mouse.button === Qt.MiddleButton ? "next" : "playPause")
    }
    onWheel: function(wheel) {
      if (widget.player && wheel.angleDelta.y !== 0) widget.act(wheel.angleDelta.y > 0 ? "previous" : "next")
    }
  }

  PopupCard {
    id: card
    anchorItem: widget
    bar: widget.bar
    owner: widget
    open: widget.cardOpen
    contentWidth: card.fittedContentWidth(Style.space(320))
    contentHeight: card.fittedContentHeight(sheet.implicitHeight)

    Column {
      id: sheet
      anchors.fill: parent
      spacing: Style.space(10)

      Row {
        width: parent.width
        spacing: Style.space(10)

        Cover {}

        Column {
          width: parent.width - Style.space(74)
          spacing: Style.space(4)

          CardLine {
            text: widget.title || "Nothing playing"
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          CardLine {
            text: widget.artist
            dim: 1.3
            font.pixelSize: Style.font.bodySmall
          }
          CardLine {
            text: widget.player && widget.player.trackAlbum ? widget.player.trackAlbum : ""
            dim: 1.6
            font.pixelSize: Style.font.caption
          }
        }
      }

      // Back, play or pause, and on, for the player shown, each there when
      // it says it can.
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(6)

        Repeater {
          model: ["previous", "playPause", "next"]

          Button {
            required property string modelData
            readonly property bool middle: modelData === "playPause"

            foreground: widget.bar.foreground
            iconText: middle ? widget.mark(widget.playing) : modelData === "next" ? "\u{F04AD}" : "\u{F04AE}"
            iconSize: middle ? Style.font.iconLarge : Style.font.icon
            horizontalPadding: middle ? Style.spacing.panelGap : Style.spacing.controlPaddingX
            enabled: Media.can(widget.player, modelData)
            opacity: enabled ? 1.0 : 0.4
            onClicked: widget.act(modelData, true)
          }
        }
      }

      // Every player, with more than one: a click makes it the one shown
      // and played.
      PanelSeparator {
        visible: widget.listed.length > 1
        foreground: widget.bar.foreground
      }

      Column {
        visible: widget.listed.length > 1
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: widget.listed
          delegate: PlayerChoice {}
        }
      }
    }
  }

  // Text in the bar's font.
  component BarText: Text {
    textFormat: Text.PlainText
    font.family: widget.bar.fontFamily
  }

  // A line of the card in the bar's foreground, `dim` times darker, cut
  // short at its width; none while empty.
  component CardLine: BarText {
    property real dim: 1
    width: parent.width
    visible: text !== ""
    elide: Text.ElideRight
    color: dim === 1 ? widget.bar.foreground : Qt.darker(widget.bar.foreground, dim)
  }

  // The cover of the track shown, or a note where it has none.
  component Cover: BorderSurface {
    id: cover

    readonly property string art: widget.player && widget.player.trackArtUrl ? widget.player.trackArtUrl : ""

    width: Style.space(64)
    height: width
    radius: Style.spacing.labelGap
    color: Style.normalFillFor(widget.bar.foreground, Commons.Color.accent)
    borderSpec: Border.controlSpec("normal", widget.bar.foreground, Commons.Color.accent)

    Image {
      anchors.fill: parent
      anchors.margins: Style.space(2)
      visible: cover.art !== ""
      source: cover.art
      // Covers come as large as 1200 px square, for 64 here.
      sourceSize: Qt.size(width, height)
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
    }

    BarText {
      anchors.centerIn: parent
      visible: cover.art === ""
      text: "\u{F075A}"
      color: widget.bar.foreground
      font.pixelSize: Style.font.displayLarge
    }
  }

  // A player in the card's list: its mark, and its track's title and artist
  // or its own name; the one shown stands out.
  component PlayerChoice: BorderSurface {
    id: choice

    required property var modelData
    readonly property bool selected: !!widget.player && Media.playerKey(modelData) === Media.playerKey(widget.player)

    width: parent ? parent.width : 0
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

      BarText {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(18)
        horizontalAlignment: Text.AlignHCenter
        text: widget.mark(choice.modelData.isPlaying)
        color: widget.bar.foreground
        font.pixelSize: Style.font.body
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - Style.space(26)
        spacing: Style.space(1)

        CardLine {
          text: Media.label(choice.modelData) || "Media source"
          font.pixelSize: Style.font.bodySmall
          font.bold: choice.selected
        }
        CardLine {
          text: choice.modelData.trackArtist || choice.modelData.identity || ""
          dim: 1.5
          font.pixelSize: Style.font.caption
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (widget.media) widget.media.choose(choice.modelData)
    }
  }
}
