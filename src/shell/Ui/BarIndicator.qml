import QtQuick
import qs.Commons

// A small icon on the bar saying a state is on: do not disturb, a screen
// recording, the night light, Caffeine. While <lit> it shows its glyph and
// <tipLit>; while dark it keeps its place unseen, shown faded only while its
// <host> (the Indicators widget) has the dark ones out, with <tipDark>. It
// is never in the urgent colour.
//
// The host gives each one a <row>: in "active" it is there while lit, in
// "inactive" while dark, and gone otherwise. <forced>, true or false, stands
// in for <lit>. The pointer on a dark one keeps the host showing them all.
BarIcon {
  id: indicator

  property bool lit: false
  property string tipLit: ""
  property string tipDark: tipLit
  property string row: "inactive"
  property var host: null
  property var forced: null

  readonly property bool _on: forced === null || forced === undefined ? lit : forced === true
  readonly property bool _here: _on === (row === "active")

  ink: foreground
  fontSize: Style.font.caption
  slot: Style.bar.statusSlot
  tip: _on ? tipLit : tipDark
  visible: _here
  holdsPlace: true
  pressable: _here
  veiled: !_on && !(host && host.showsDark)
  opacity: !_here || veiled ? 0 : _on ? 1 : 0.45

  onCrossed: over => {
    if (row === "inactive" && host && host.pointerOnDark) host.pointerOnDark(over)
  }
}
