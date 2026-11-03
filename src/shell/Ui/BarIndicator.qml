import QtQuick
import qs.Commons

// A bar icon that says a state is on: Do Not Disturb, a screen recording,
// night light, caffeine. On, it shows <activeText>; off, it hides but keeps
// its place, unless its host reveals the indicators that are off, when it
// shows <inactiveText> faded.
//
// The Indicators widget places each indicator in one of its blocks: in the
// "active" block it is there only while on, in the "inactive" one only while
// off, and in a "single" one always. <activeOverride>, true or false,
// stands in for <active>.
BarIconButton {
  property string moduleName: ""
  property var settings: ({})
  property string activeText: ""
  property string inactiveText: activeText
  property string activeTooltipText: ""
  property string inactiveTooltipText: activeTooltipText
  property string indicatorBlock: "single"
  property var indicatorHost: null
  property var activeOverride: null

  readonly property bool effectiveActive: activeOverride === null || activeOverride === undefined ? active : activeOverride === true
  readonly property bool belongsInBlock: indicatorBlock === "active" ? effectiveActive
    : indicatorBlock === "inactive" ? !effectiveActive
    : true
  readonly property bool inactiveRevealed: !effectiveActive && !!indicatorHost && indicatorHost.revealInactiveIndicators

  visible: belongsInBlock && (text !== "" || keepSpace)
  // Out of its block it is gone; on, whole; off, faded while revealed.
  opacity: !belongsInBlock ? 0 : effectiveActive ? 1 : inactiveRevealed ? 0.45 : 0
  text: effectiveActive ? activeText : inactiveText
  tooltipText: effectiveActive ? activeTooltipText : inactiveTooltipText
  keepSpace: true
  dimmed: !effectiveActive
  concealed: !effectiveActive && !inactiveRevealed
  interactive: belongsInBlock && (effectiveActive || indicatorBlock === "inactive" || inactiveRevealed)
  useActiveColor: false
  maintainIndicatorReveal: indicatorBlock === "inactive"
  revealHost: indicatorHost
  fontSize: Style.font.caption
  horizontalMargin: 5
  verticalPadding: 5
  fixedWidth: vertical ? -1 : Style.bar.statusSlot
  fixedHeight: vertical ? Style.bar.statusSlot : -1
}
