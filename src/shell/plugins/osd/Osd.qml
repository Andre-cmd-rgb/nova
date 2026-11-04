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
// icon and a few words. nova-osd calls it up through the osd IPC target,
// the keys and the panels through the shell's summon. It never takes a
// click or a key.
Item {
  id: osd

  // Up; the shell reads it to tell whether the plugin is open.
  property bool opened: false
  property var face: Face.parse({})
  // The card's two faces of type: the icon's, and the words'.
  readonly property font glyphType: Qt.font({ family: Style.font.family, pixelSize: Style.font.displayLarge })
  readonly property font wordsType: Qt.font({ family: Style.font.family, bold: true, pixelSize: Style.font.title })
  readonly property var spots: Face.layout(face, {
    ink: iconInk.tightBoundingRect.width,
    widestInk: widestIconInk.tightBoundingRect.width,
    readout: widestReadout.advanceWidth,
    words: wordsRun.advanceWidth,
    gap: Style.space(16),
    bar: Style.space(142),
    wordsMax: face.fromPlayer ? Style.space(325) : Style.space(190)
  })

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
      padding: Style.space(16)
      width: contentLeftInset + osd.spots.width + contentRightInset
      height: contentTopInset + Style.font.displayLarge + contentBottomInset
      radius: Style.cornerRadius
      color: Util.alpha(Commons.Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Commons.Color.popups.border, Math.max(1, Style.space(2)))
      opacity: osd.opened ? 1 : 0

      // The pieces side by side, each where Face.layout puts it.
      Item {
        anchors.fill: parent
        anchors.leftMargin: card.contentLeftInset
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset

        // The glyph's ink, not its cell, in the middle of its column.
        Line {
          x: Math.round((osd.spots.column - osd.spots.ink) / 2 - iconInk.tightBoundingRect.x)
          text: osd.face.glyph
          font: osd.glyphType
        }

        LevelBar {
          visible: osd.face.level
          x: osd.spots.barX
          width: Style.space(142)
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
