import QtQuick
import qs.Commons
import qs.Ui
import "../BarModel.js" as BarModel

// Small switches: a screen recording, the night light, do not disturb,
// Caffeine. Those that are on are lit, nearest the centre; those that are off
// keep their room beside them, and show while the pointer is on the widget or
// on the bar's centre. Each is a file in ../indicators, named in the widget's
// `items` (or `indicators`, its older name), all of them when it names none.
BarWidget {
  id: root
  moduleName: "nova.indicators"

  readonly property var defaultIndicators: ["ScreenRecording", "NightLight", "Dnd", "Caffeine"]
  // Stay Awake and Lid Awake became one Caffeine indicator; a layout naming
  // either gets it.
  readonly property var renamed: ({ "StayAwake": "Caffeine", "LidAwake": "Caffeine" })
  readonly property var indicatorEntries: entriesFrom(settings)

  // The indicators that are on, in the order they are lit, and the model the
  // lit block is built from: moved rather than rebuilt, so a lit indicator
  // keeps its copy while another comes or goes.
  property var activeIds: []
  property var activeStates: ({})
  ListModel { id: lit }

  property bool areaHovered: false
  property bool itemHovered: false
  readonly property bool revealInactiveIndicators: setting("alwaysShow", false) === true || areaHovered || itemHovered
    || (bar && bar.centerSectionRevealHeld === true && bar.centerHoverRevealSuppressed !== true)

  // To the indicators that look for their state themselves (the recording):
  // look now. nova-shell nova.indicators refresh.
  signal refreshRequested()

  function refresh() { refreshRequested() }

  Component.onCompleted: refreshRequested()

  function entriesFrom(settings) {
    var source = defaultIndicators
    if (settings.items && typeof settings.items.length === "number" && settings.items.length > 0) source = settings.items
    else if (settings.indicators && typeof settings.indicators.length === "number" && settings.indicators.length > 0) source = settings.indicators

    var result = []
    for (var i = 0; i < source.length; i++) {
      var entry = source[i]
      if (entry !== null && typeof entry === "object") {
        try {
          entry = JSON.parse(JSON.stringify(entry))
        } catch (error) {
        }
      }
      var id = BarModel.entryId(entry)
      if (renamed[id] !== undefined) {
        id = renamed[id]
        entry = id
        if (result.some(function(other) { return BarModel.entryId(other) === id })) continue
      }
      if (id !== "") result.push(entry)
    }
    return result
  }

  function listed(id) {
    return indicatorEntries.some(function(entry) { return BarModel.entryId(entry) === id })
  }

  function entryForId(id) {
    for (var i = 0; i < indicatorEntries.length; i++) {
      if (BarModel.entryId(indicatorEntries[i]) === id) return indicatorEntries[i]
    }
    return { id: id }
  }

  // Of `ids`, in their order, those listed and on.
  function stillActive(states, ids) {
    var kept = []
    ids.forEach(function(id) {
      if (kept.indexOf(id) === -1 && listed(id) && states[id] === true) kept.push(id)
    })
    return kept
  }

  // An indicator saying it is on or off. One that comes on goes first, the
  // far side from the centre: added last it would push those lit sideways.
  function setIndicatorActive(entry, active) {
    var id = BarModel.entryId(entry)
    if (id === "") return
    var states = {}
    for (var key in activeStates) {
      if (activeStates[key] === true) states[key] = true
    }
    if (active) states[id] = true
    else delete states[id]
    activeStates = states

    var ids = stillActive(states, activeIds)
    if (active && ids.indexOf(id) === -1 && listed(id)) ids.unshift(id)
    activeIds = ids
    syncLit()
  }

  onIndicatorEntriesChanged: {
    activeIds = stillActive(activeStates, activeIds)
    syncLit()
  }

  function syncLit() {
    for (var i = lit.count - 1; i >= 0; i--) {
      if (activeIds.indexOf(lit.get(i).activeId) === -1) lit.remove(i)
    }
    for (var j = 0; j < activeIds.length; j++) {
      var at = -1
      for (var k = 0; k < lit.count && at === -1; k++) {
        if (lit.get(k).activeId === activeIds[j]) at = k
      }
      if (at === -1) lit.insert(j, { activeId: activeIds[j] })
      else if (at !== j) lit.move(at, j, 1)
    }
  }

  // The off ones show while the pointer is on them, and for 120 ms after it
  // leaves, so it can cross to one without them fading under it.
  function setIndicatorAreaHovered(hovered) {
    areaHovered = hovered
    if (hovered) hideDelay.stop()
    else hideDelay.restart()
  }

  // WidgetButton's, for the off indicators it draws.
  function setIndicatorItemHovered(hovered) {
    if (!hovered) {
      hideDelay.restart()
      return
    }
    itemHovered = true
    hideDelay.stop()
  }

  Timer {
    id: hideDelay
    interval: 120
    onTriggered: if (!root.areaHovered) root.itemHovered = false
  }

  implicitWidth: both.implicitWidth
  implicitHeight: both.implicitHeight

  // The off block, then the lit one, along the bar. The off indicators keep
  // their room and only fade: room made on a hover would move the clock and
  // everything beside it each time the pointer crossed the bar.
  Item {
    id: both

    implicitWidth: root.vertical ? Math.max(unlitArea.implicitWidth, litBlock.implicitWidth) : unlitArea.implicitWidth + litBlock.implicitWidth
    implicitHeight: root.vertical ? unlitArea.implicitHeight + litBlock.implicitHeight : Math.max(unlitArea.implicitHeight, litBlock.implicitHeight)
    width: implicitWidth
    height: implicitHeight

    Item {
      id: unlitArea

      implicitWidth: root.vertical ? Math.max(unlitBlock.implicitWidth, root.barSize) : unlitBlock.implicitWidth
      implicitHeight: root.vertical ? unlitBlock.implicitHeight : Math.max(unlitBlock.implicitHeight, root.barSize)
      width: implicitWidth
      height: implicitHeight

      Block {
        id: unlitBlock
        anchors.verticalCenter: root.vertical ? undefined : parent.verticalCenter
        anchors.horizontalCenter: root.vertical ? parent.horizontalCenter : undefined
        opacity: root.revealInactiveIndicators ? 1 : 0
        enabled: root.revealInactiveIndicators

        Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

        Repeater {
          model: root.indicatorEntries

          Indicator {
            required property var modelData
            entry: modelData
            block: "inactive"
          }
        }
      }

      HoverHandler {
        onHoveredChanged: root.setIndicatorAreaHovered(hovered)
      }
    }

    Block {
      id: litBlock
      x: root.vertical ? 0 : unlitArea.width
      y: root.vertical ? unlitArea.height : 0

      Repeater {
        model: lit

        Indicator {
          required property string activeId
          entry: root.entryForId(activeId)
          block: "active"
        }
      }
    }
  }

  HoverHandler {
    onHoveredChanged: root.setIndicatorAreaHovered(hovered)
  }

  // A row of indicators, or a column on a side bar.
  component Block: Grid {
    rows: root.vertical ? -1 : 1
    columns: root.vertical ? 1 : -1
  }

  // One indicator, loaded from its file. Every listed indicator has a copy
  // in the off block, which hides itself while it is on, and one that is on
  // has a second copy in the lit block. Both say when they change, which is
  // how the lit block learns what to show.
  component Indicator: Item {
    id: indicator

    required property var entry
    required property string block
    readonly property string indicatorId: BarModel.entryId(entry)
    readonly property var indicatorSettings: BarModel.entrySettings(entry)
    readonly property var hostBar: root.bar
    // A lit copy is made for an indicator that is on, and only once it has
    // said so does its going off count: before, it is still loading.
    property bool seenOn: false

    implicitWidth: file.item && file.item.visible ? file.item.implicitWidth : 0
    implicitHeight: file.item && file.item.visible ? file.item.implicitHeight : 0
    width: implicitWidth
    height: implicitHeight

    onEntryChanged: {
      seenOn = false
      hand()
      report()
    }
    onIndicatorSettingsChanged: hand()
    onHostBarChanged: hand()

    function hand() {
      var item = file.item
      if (!item) return
      if ("bar" in item) item.bar = root.bar
      if ("moduleName" in item) item.moduleName = indicatorId
      if ("settings" in item) item.settings = indicatorSettings
      if ("indicatorBlock" in item) item.indicatorBlock = block
      if ("indicatorHost" in item) item.indicatorHost = root
      if ("activeOverride" in item) item.activeOverride = block === "active" ? true : null
    }

    function report() {
      var on = !!file.item && file.item.active === true
      if (block === "active") {
        if (on) seenOn = true
        else if (!seenOn) return
      }
      root.setIndicatorActive(entry, on)
    }

    Loader {
      id: file
      anchors.fill: parent
      source: indicator.indicatorId ? Qt.resolvedUrl("../indicators/" + indicator.indicatorId + ".qml") : ""
      onLoaded: {
        indicator.hand()
        indicator.report()
      }
      onStatusChanged: if (status === Loader.Error) console.warn("Indicator loader error", indicator.indicatorId, source)
    }

    Connections {
      target: file.item
      ignoreUnknownSignals: true
      function onActiveChanged() { indicator.report() }
    }
  }
}
