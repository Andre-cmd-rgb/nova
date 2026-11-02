import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "OsdModel.js" as OsdModel

// The on-screen display: a card above the bottom edge with an icon and a
// level or a message, gone after its duration. `nova-osd` shows it through
// the osd IPC target, the shell's keys and panels through summon.
Item {
  id: root

  property bool opened: false
  // What the card shows: OsdModel.parse's answer to the last request.
  property var shown: OsdModel.parse({})

  readonly property bool media: shown.iconKey.indexOf("media") === 0 || shown.iconKey.indexOf("player") === 0

  // The card is sized by what it holds, with `pad` round it whatever the
  // glyph and the text. A message grows with its text up to maxMessageWidth,
  // a media title's further, and is cut short with an ellipsis beyond.
  readonly property int pad: Style.space(16)
  readonly property int gap: Style.space(16)
  // An icon next to text looks further from it than it measures, both
  // falling away from their edges; text sits at two thirds of the gap, the
  // bar, square-ended, at all of it.
  readonly property int messageGap: Math.round(gap * 2 / 3)
  readonly property int barWidth: Style.space(142)
  readonly property int maxMessageWidth: media ? Style.space(325) : Style.space(190)

  // Nerd Font glyphs draw outside their cell, so the icon's column is as
  // wide as its ink. With a level it is as wide as the widest icon, and the
  // readout as wide as "100%", so nothing moves as the level changes.
  readonly property int iconInkWidth: Math.ceil(iconMetrics.tightBoundingRect.width)
  readonly property int iconWidth: shown.hasProgress
    ? Math.max(iconInkWidth, Math.ceil(widestIconMetrics.tightBoundingRect.width))
    : iconInkWidth
  readonly property int valueWidth: Math.ceil(Math.max(valueMetrics.advanceWidth, messageMetrics.advanceWidth))
  readonly property int messageWidth: Math.min(Math.ceil(messageMetrics.advanceWidth), maxMessageWidth)
  readonly property int contentWidth: shown.hasProgress
    ? iconWidth + gap + barWidth + gap + valueWidth
    : shown.message === "" ? iconWidth : iconWidth + messageGap + messageWidth

  // The request as JSON: see OsdModel.parse. One that does not parse is
  // dropped. A level shown while the card is up slides to its new place.
  function open(requestJson) {
    var next
    try {
      next = OsdModel.parse(JSON.parse(requestJson || "{}"))
    } catch (e) {
      return
    }
    shown = next
    opened = true
    if (shown.duration > 0) hideTimer.restart()
    else hideTimer.stop()
  }

  function close() {
    opened = false
  }

  Timer {
    id: hideTimer
    interval: root.shown.duration
    onTriggered: root.opened = false
  }

  TextMetrics {
    id: messageMetrics
    font.family: Style.font.family
    font.bold: true
    font.pixelSize: Style.font.title
    text: root.shown.message
  }

  TextMetrics {
    id: valueMetrics
    font: messageMetrics.font
    text: "100%"
  }

  TextMetrics {
    id: iconMetrics
    font.family: Style.font.family
    font.pixelSize: Style.font.displayLarge
    text: root.shown.icon
  }

  TextMetrics {
    id: widestIconMetrics
    font: iconMetrics.font
    text: OsdModel.widestIcon
  }

  IpcHandler {
    target: "osd"

    function show(requestJson: string): string {
      root.open(requestJson)
      return "ok"
    }

    function close(): string {
      root.close()
      return "ok"
    }

    function state(): string {
      return root.opened ? "open" : "closed"
    }

    function ping(): string {
      return "ok"
    }
  }

  // A window the card's size, not the screen's: a full-screen one was a
  // screen-sized buffer to redraw at each step of a held key, and for
  // Hyprland to fade.
  PanelWindow {
    visible: root.opened
    anchors.bottom: true
    margins.bottom: Style.space(67)
    implicitWidth: card.width
    implicitHeight: card.height
    color: "transparent"
    WlrLayershell.namespace: "nova-osd"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // Shown, never touched: clicks go through to what is under it.
    mask: Region {}

    BorderSurface {
      id: card
      padding: root.pad
      width: contentLeftInset + root.contentWidth + contentRightInset
      height: contentTopInset + Style.font.displayLarge + contentBottomInset
      color: Util.alpha(Commons.Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      opacity: root.opened ? 1 : 0

      Row {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.shown.hasProgress ? root.gap : root.messageGap

        Item {
          width: root.iconWidth
          height: parent.height

          // The glyph's ink, not its cell, centred in the column.
          Text {
            x: Math.round((root.iconWidth - root.iconInkWidth) / 2 - iconMetrics.tightBoundingRect.x)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.shown.icon
            font: iconMetrics.font
            color: Commons.Color.popups.text
          }
        }

        Rectangle {
          visible: root.shown.hasProgress
          width: root.barWidth
          height: Math.max(Style.space(6), Style.spacing.sm)
          anchors.verticalCenter: parent.verticalCenter
          color: Util.alpha(Commons.Color.popups.text, 0.45)

          Rectangle {
            width: parent.width * (root.shown.hasProgress ? root.shown.value / root.shown.maxValue : 0)
            height: parent.height
            color: Commons.Color.accent

            Behavior on width {
              enabled: root.opened
              NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
            }
          }
        }

        // A readout ends at the card's padding, its slack in the gap before
        // it; a message starts after the icon.
        Text {
          visible: root.shown.message !== ""
          width: root.shown.hasProgress ? root.valueWidth : root.messageWidth
          anchors.verticalCenter: parent.verticalCenter
          horizontalAlignment: root.shown.hasProgress ? Text.AlignRight : Text.AlignLeft
          textFormat: Text.PlainText
          text: root.shown.message
          font: messageMetrics.font
          color: Commons.Color.popups.text
          elide: Text.ElideRight
          maximumLineCount: 1
        }
      }
    }
  }
}
