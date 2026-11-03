import QtQuick
import qs.Commons

// A bar icon that shows a state: Do Not Disturb, the screen recording,
// night light, caffeine. Active, it shows <activeText>; inactive, it hides,
// keeping its place, unless its host reveals the inactive indicators, when
// it shows <inactiveText> faded.
//
// An indicator can sit in a block of the bar's: in the "active" block it
// is there only while active, in the "inactive" one only while inactive,
// and in a "single" one always. <activeOverride>, true or false, stands in
// for <active>.
BarIconButton {
  id: root

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
  readonly property bool belongsInBlock: {
    switch (indicatorBlock) {
    case "active": return effectiveActive
    case "inactive": return !effectiveActive
    }
    return true
  }
  readonly property bool inactiveRevealed: !effectiveActive && !!indicatorHost && indicatorHost.revealInactiveIndicators

  function extractData(raw) {
    return Util.parseModuleJson(raw)
  }

  // These rules take the place of WidgetButton's opacity binding; they are
  // applied whenever one of the values they read changes.
  function syncIndicatorOpacity() {
    if (!belongsInBlock) root.opacity = 0
    else if (effectiveActive) root.opacity = 1
    else root.opacity = inactiveRevealed ? 0.45 : 0
  }

  visible: belongsInBlock && (text !== "" || keepSpace)
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

  Component.onCompleted: syncIndicatorOpacity()
  onActiveChanged: syncIndicatorOpacity()
  onEffectiveActiveChanged: syncIndicatorOpacity()
  onBarChanged: syncIndicatorOpacity()
  onBelongsInBlockChanged: syncIndicatorOpacity()
  onInactiveRevealedChanged: syncIndicatorOpacity()
  onIndicatorBlockChanged: syncIndicatorOpacity()
}
