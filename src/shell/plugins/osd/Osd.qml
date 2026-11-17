import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "OsdModel.js" as Face

// The on-screen display: a card a little above the bottom of the screen,
// for a moment, with an icon and a level (the volume, the brightness) or an
// icon and a few words ("Launching Files…"). nova-osd calls it up through
// the osd IPC target, the keys and the panels through the shell's summon. It
// never takes a click or a key.
//
// A notice in words is the size of the dictation's pill, the other card at
// the bottom of the screen, and drawn as its messages are: the pill's
// padding and row, the icon at title size and the words at body size. A
// level keeps a larger card, its icon at display size.
Item {
  id: osd

  // Up; the shell reads it to tell whether the plugin is open.
  property bool opened: false
  property var face: Face.parse({})
  readonly property bool notice: !face.level
  // The card's two faces of type, the icon's and the words', a notice's and
  // a level's.
  readonly property font noticeGlyph: Qt.font({ family: Style.font.family, pixelSize: Style.font.title })
  readonly property font levelGlyph: Qt.font({ family: Style.font.family, pixelSize: Style.font.displayLarge })
  readonly property font noticeWords: Qt.font({ family: Style.font.family, pixelSize: Style.font.body })
  readonly property font levelWords: Qt.font({ family: Style.font.family, bold: true, pixelSize: Style.font.title })
  readonly property font glyphType: notice ? noticeGlyph : levelGlyph
  readonly property font wordsType: notice ? noticeWords : levelWords
  // A notice's padding is the dictation pill's; its words start the pill's gap
  // after the icon, and have the most room beside a player's icon. An icon's
  // ink is given at most twice its type's size (the widest Nerd Font glyphs
  // take about one and a half).
  readonly property real noticePad: Style.spacing.pillPadding
  readonly property real levelPad: Style.space(16)
  readonly property real gap: Style.space(16)
  readonly property real barLength: Style.space(142)
  readonly property real noticeWordsGap: Style.space(9)
  readonly property real mostWords: Style.space(325)
  readonly property var spots: Face.layout(face, {
    ink: iconInk.tightBoundingRect.width,
    widestInk: widestIconInk.tightBoundingRect.width,
    inkMax: 2 * glyphType.pixelSize,
    readout: widestReadout.advanceWidth,
    words: wordsRun.advanceWidth,
    gap: gap,
    bar: barLength,
    wordsMax: face.fromPlayer ? mostWords : Style.space(190),
    wordsGap: notice ? noticeWordsGap : undefined
  })

  // The window: room for the largest card any face makes, with the card at
  // its foot, in the middle. A window the card's own size took a new size
  // with each face, and Hyprland could draw a face into the size of the one
  // before it: "Microphone on" in the room of "Microphone muted", the card's
  // right edge smeared over the rest as a lavender block.
  readonly property real roomWidth: card.edge.left + card.edge.right + Face.room(
    { pad: noticePad, inkMax: 2 * Style.font.title, wordsGap: noticeWordsGap, wordsMax: mostWords },
    { pad: levelPad, inkMax: 2 * Style.font.displayLarge, gap: gap, bar: barLength, readout: levelReadout.advanceWidth })
  readonly property real roomHeight: card.edge.top + card.edge.bottom
    + Math.max(2 * noticePad + Style.spacing.pillRowHeight, 2 * levelPad + Style.font.displayLarge)

  // A request as Face.parse takes it, as JSON; one that is not JSON is
  // dropped. The card goes after the request's duration, or stays for 0.
  function open(requestJson) {
    var next
    try {
      next = Face.parse(JSON.parse(requestJson || "{}"))
    } catch (e) {
      return
    }
    face = next
    opened = true
    away.stop()
    if (face.duration > 0) away.start()
  }

  function close() {
    opened = false
  }

  Timer {
    id: away
    interval: osd.face.duration
    onTriggered: osd.close()
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

  // The icon is measured by its ink, as Nerd Font glyphs spill out of
  // their cells; the words by their advance.
  TextMetrics {
    id: iconInk
    font: osd.glyphType
    text: osd.face.glyph
  }

  TextMetrics {
    id: widestIconInk
    font: osd.glyphType
    text: Face.widestIcon
  }

  TextMetrics {
    id: wordsRun
    font: osd.wordsType
    text: osd.face.words
  }

  TextMetrics {
    id: widestReadout
    font: osd.wordsType
    text: Face.widestReadout
  }

  TextMetrics {
    id: levelReadout
    font: osd.levelWords
    text: Face.widestReadout
  }

  // The window is the room for a card: a screen-sized one was a whole
  // screen to redraw at each step of a held key, and for Hyprland to fade.
  PanelWindow {
    visible: osd.opened
    anchors.bottom: true
    margins.bottom: Style.space(67)
    implicitWidth: Math.ceil(osd.roomWidth)
    implicitHeight: Math.ceil(osd.roomHeight)
    color: "transparent"
    WlrLayershell.namespace: "nova-osd"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    // No input region: a click lands on whatever is under the card.
    mask: Region {}

    BorderSurface {
      id: card
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      padding: osd.notice ? osd.noticePad : osd.levelPad
      width: inset.left + osd.spots.width + inset.right
      height: inset.top + (osd.notice ? Style.spacing.pillRowHeight : Style.font.displayLarge) + inset.bottom
      radius: Style.cornerRadius
      color: Util.alpha(Commons.Color.background, 0.97)
      frame: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
      opacity: osd.opened ? 1 : 0

      // The pieces side by side, each where Face.layout puts it.
      Item {
        anchors.fill: parent
        anchors.leftMargin: card.inset.left
        anchors.topMargin: card.inset.top
        anchors.rightMargin: card.inset.right
        anchors.bottomMargin: card.inset.bottom

        // The glyph's ink, not its cell, in the middle of its column.
        Line {
          x: Math.round((osd.spots.column - osd.spots.ink) / 2 - iconInk.tightBoundingRect.x)
          text: osd.face.glyph
          font: osd.glyphType
        }

        LevelBar {
          visible: osd.face.level
          x: osd.spots.barX
          width: osd.barLength
        }

        // A readout ends at the padding, any room to spare in the gap
        // before it; words stop short with an ellipsis.
        Line {
          visible: osd.face.words !== ""
          x: osd.spots.textX
          width: osd.spots.textWidth
          horizontalAlignment: osd.face.level ? Text.AlignRight : Text.AlignLeft
          text: osd.face.words
          font: osd.wordsType
          elide: Text.ElideRight
          maximumLineCount: 1
        }
      }
    }
  }

  component Line: Text {
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    color: Commons.Color.popups.text
  }

  // The level, which slides to a new one while the card is up.
  component LevelBar: Rectangle {
    anchors.verticalCenter: parent.verticalCenter
    height: Math.max(Style.space(6), Style.spacing.sm)
    color: Util.alpha(Commons.Color.popups.text, 0.45)

    Rectangle {
      width: parent.width * osd.face.fill
      height: parent.height
      color: Commons.Color.accent

      Behavior on width {
        enabled: osd.opened
        NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
      }
    }
  }
}
