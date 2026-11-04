import QtQuick
import qs.Commons

// A small bar icon that says a state is on: Do Not Disturb, a screen
// recording, night light, caffeine. Lit, it shows <activeText>; off, it
// keeps its place unseen, unless its host is revealing the indicators that
// are off, when it shows faded. It is never drawn in the urgent colour.
//
// The Indicators widget puts each one in one of two blocks: the "active"
// block holds it while lit, the "inactive" block while off. Out of its
// block it is gone. <activeOverride>, true or false, stands in for <active>.
// While the pointer is on an off one, the host keeps revealing them all.
BarIconButton {
  id: indicator

  property string activeText: ""
  property string activeTooltipText: ""
  property string inactiveTooltipText: activeTooltipText
  property string indicatorBlock: "inactive"
  property var indicatorHost: null
  property var activeOverride: null

  readonly property bool _lit: activeOverride == null ? active : activeOverride === true
  readonly property bool _inBlock: (indicatorBlock === "active") === _lit
  readonly property bool _peeking: !_lit && !!(indicatorHost && indicatorHost.revealInactiveIndicators)

  text: activeText
  tooltipText: _lit ? activeTooltipText : inactiveTooltipText
  _ink: foreground
  fontSize: Style.font.caption
  slotSize: Style.bar.statusSlot

  visible: _inBlock
  keepSpace: true
  interactive: _inBlock
  concealed: !_lit && !_peeking
  opacity: !_inBlock || concealed ? 0 : _lit ? 1 : 0.45

  onCrossed: function (over) {
    if (indicatorBlock === "inactive" && indicatorHost && indicatorHost.setIndicatorItemHovered)
      indicatorHost.setIndicatorItemHovered(over)
  }
}
