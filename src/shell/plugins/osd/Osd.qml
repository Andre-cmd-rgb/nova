import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "OsdModel.js" as OsdModel

// The on-screen display: a card a little above the bottom of the screen,
// for a moment, with an icon and a level (the volume, the brightness) or an
// icon and a few words. nova-osd calls it up through the osd IPC target,
// the keys and the panels through the shell's summon. It never takes a
// click or a key.
Item {
  id: osd

  property bool opened: false
  // The last request, as OsdModel.parse reads it.
  property var face: OsdModel.parse({})
  readonly property bool level: face.hasProgress
  // A player's title gets more room than a message.
  readonly property bool fromPlayer: /^(media|player)/.test(face.iconKey)

  // ---------------------------------------------------------------- sizes

  // The card is as wide as what it holds, with `padding` all round.
  readonly property int padding: Style.space(16)
  readonly property int gap: Style.space(16)
  // Words beside an icon look further from it than they are, as both fall
  // away from their edges, so they sit two thirds of the gap off; the bar,
  // square-ended, the whole gap.
  readonly property int wordGap: Math.round(gap * 2 / 3)
  readonly property int barWidth: Style.space(142)
  readonly property int wordsMax: fromPlayer ? Style.space(325) : Style.space(190)

  // The icon is measured by its ink, as Nerd Font glyphs spill out of their
  // cells. Beside a level, the icon's column fits the widest speaker and
  // the readout "100%", so the bar keeps its place as the level moves.
  readonly property int ink: Math.ceil(glyph.tightBoundingRect.width)
  readonly property int iconColumn: level ? Math.max(ink, Math.ceil(widestGlyph.tightBoundingRect.width)) : ink
  readonly property int readoutWidth: Math.ceil(Math.max(fullReadout.advanceWidth, words.advanceWidth))
  readonly property int wordsWidth: Math.min(Math.ceil(words.advanceWidth), wordsMax)

  // Where each piece starts, from the icon's left edge.
  readonly property int barX: iconColumn + gap
  readonly property int wordsX: level ? barX + barWidth + gap : iconColumn + wordGap
  readonly property int contentWidth: level ? wordsX + readoutWidth
    : face.message === "" ? iconColumn : wordsX + wordsWidth

  TextMetrics {
    id: words
    font.family: Style.font.family
    font.bold: true
    font.pixelSize: Style.font.title
    text: osd.face.message
  }

  TextMetrics {
    id: fullReadout
    font: words.font
    text: "100%"
  }

  TextMetrics {
    id: glyph
    font.family: Style.font.family
    font.pixelSize: Style.font.displayLarge
    text: osd.face.icon
  }

  TextMetrics {
    id: widestGlyph
    font: glyph.font
    text: OsdModel.widestIcon
  }

  // ---------------------------------------------------------------- showing

  // <requestJson> as OsdModel.parse takes it; one that is not JSON is
  // dropped. The card goes after the request's duration, or stays for 0.
  function open(requestJson) {
    var next
    try {
      next = OsdModel.parse(JSON.parse(requestJson || "{}"))
    } catch (e) {
      return
    }
    face = next
    opened = true
    if (face.duration > 0) hideTimer.restart()
    else hideTimer.stop()
  }

  function close() {
    opened = false
  }

  Timer {
    id: hideTimer
    interval: osd.face.duration
    onTriggered: osd.opened = false
  }

  IpcHandler {
    target: "osd"

    function show(requestJson: string): string {
      osd.open(requestJson)
      return "ok"
    }

    function close(): string {
      osd.close()
      return "ok"
    }
  }

  // ---------------------------------------------------------------- the card

  // The window is the card's size: a screen-sized one was a whole screen
  // to redraw at each step of a held key, and for Hyprland to fade.
  PanelWindow {
    visible: osd.opened
    anchors.bottom: true
    margins.bottom: Style.space(67)
    implicitWidth: card.width
    implicitHeight: card.height
    color: "transparent"
    WlrLayershell.namespace: "nova-osd"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // No input region: a click lands on whatever is under the card.
    mask: Region {}

    BorderSurface {
      id: card
      padding: osd.padding
      width: contentLeftInset + osd.contentWidth + contentRightInset
      height: contentTopInset + Style.font.displayLarge + contentBottomInset
      radius: Style.cornerRadius
      color: Util.alpha(Commons.Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
      opacity: osd.opened ? 1 : 0

      // The pieces side by side, each at its own x.
      Item {
        anchors.fill: parent
        anchors.leftMargin: card.contentLeftInset
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset

        // The glyph's ink, not its cell, in the middle of its column.
        Text {
          x: Math.round((osd.iconColumn - osd.ink) / 2 - glyph.tightBoundingRect.x)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: osd.face.icon
          font: glyph.font
          color: Commons.Color.popups.text
        }

        // The level, which slides to a new one while the card is up.
        Rectangle {
          visible: osd.level
          x: osd.barX
          anchors.verticalCenter: parent.verticalCenter
          width: osd.barWidth
          height: Math.max(Style.space(6), Style.spacing.sm)
          color: Util.alpha(Commons.Color.popups.text, 0.45)

          Rectangle {
            width: parent.width * (osd.level ? osd.face.value / osd.face.maxValue : 0)
            height: parent.height
            color: Commons.Color.accent

            Behavior on width {
              enabled: osd.opened
              NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
            }
          }
        }

        // A readout ends at the padding, any room to spare in the gap before
        // it; words start after the icon and stop short with an ellipsis.
        Text {
          visible: osd.face.message !== ""
          x: osd.wordsX
          width: osd.level ? osd.readoutWidth : osd.wordsWidth
          anchors.verticalCenter: parent.verticalCenter
          horizontalAlignment: osd.level ? Text.AlignRight : Text.AlignLeft
          textFormat: Text.PlainText
          text: osd.face.message
          font: words.font
          color: Commons.Color.popups.text
          elide: Text.ElideRight
          maximumLineCount: 1
        }
      }
    }
  }
}
