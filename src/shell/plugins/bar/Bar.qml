import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "BarModel.js" as BarModel

// The bar: a window along one edge of every screen, holding the widgets of
// shell.json's layout in three sections. It draws what the shell hands it
// (barConfig) and writes a change back through the shell. A widget is found
// in the shell's registry by its id, or is the user's own: a command's
// output, or a QML file. Dragging a widget moves it along the bar, dragging
// the bar's empty centre takes the bar to another edge, and a double click
// there makes it transparent.
Item {
  id: root

  // From the shell (shell.qml's bar Loader).
  property string novaPath: Quickshell.env("NOVA_PATH")
  property var barWidgetRegistry: noRegistry
  property var barConfig: ({})
  property var shell: null

  QtObject {
    id: noRegistry
    property var widgets: ({})
  }

  // What widgets read: the edge, the bar's size and colours, and whether it
  // is hidden or transparent.
  property string position: "top"
  readonly property bool vertical: position === "left" || position === "right"
  readonly property int barSize: vertical ? Style.bar.sizeVertical : Style.bar.sizeHorizontal
  // "monospace" until fontconfig resolves it while drawing, so a new system
  // font (nova-font-set) reaches the bar without a reload.
  property string fontFamily: Style.font.family
  property color foreground: Commons.Color.bar.text
  property color barForeground: measuredForegroundShown ? measuredForeground : foreground
  property color background: Commons.Color.bar.background
  property color urgent: Commons.Color.bar.active
  property bool foregroundAnimationEnabled: true
  property bool transparent: false
  property bool barHidden: false

  Behavior on barForeground { enabled: root.foregroundAnimationEnabled; ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  Behavior on background { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }
  Behavior on urgent { ColorAnimation { duration: 420; easing.type: Easing.InOutCubic } }

  // The layout as last applied; layoutSerial moves when the sections have to
  // be built again.
  property var layoutConfig: defaultConfig.layout
  property int layoutSerial: 0
  property string centerAnchor: ""
  readonly property var defaultConfig: ({
    position: "top",
    transparent: false,
    centerAnchor: "nova.clock",
    layout: { left: [], center: [], right: [] }
  })
  readonly property string home: Quickshell.env("HOME")
  readonly property string stateHome: Commons.Color.stateHome

  // Every widget slot and every clickable widget, on every screen's bar.
  property var moduleSlots: []
  property var clickTargets: []
  // The widget whose popup is open; one at a time.
  property var activePopout: null

  // ---------------------------------------------------------------- config

  onBarConfigChanged: applyConfig()

  // shell.qml's Loader hands the bar its shell. Without it the bar still draws
  // but cannot save a change, and the guards on `shell` below would hide that,
  // so it is said once, where the smoke tests see it.
  Component.onCompleted: {
    if (!shell) console.warn("Bar: started without its shell; layout changes cannot be saved")
    applyConfig()
  }

  function applyConfig() {
    var config = Util.isPlainObject(barConfig) ? barConfig : defaultConfig
    position = BarModel.edge(config.position)
    setTransparentWanted(config.transparent === true)

    var layout = Util.normalizeLayout(Util.isPlainObject(config.layout) ? config.layout : defaultConfig.layout)
    for (var region in layout) layout[region] = BarModel.trayInward(layout[region], region)
    centerAnchor = BarModel.centerAnchor(config.centerAnchor, layout.center)

    // The sections' Repeaters take plain arrays, which QML cannot compare,
    // so a new layout builds every widget on every screen again. A write
    // that only changed a widget's settings (the battery's percentage, the
    // clock's format) is pushed into the widgets that are there instead.
    var changes = BarModel.settingsOnlyChanges(layoutConfig, layout)
    if (!changes) {
      layoutConfig = layout
      layoutSerial++
      return
    }
    changes.forEach(function(change) {
      layoutConfig[change.region][change.index] = change.entry
      var id = BarModel.entryId(change.entry)
      var settings = BarModel.entrySettings(change.entry)
      moduleSlots.forEach(function(slot) {
        if (!slot || slot.region !== change.region || slot.moduleName !== id) return
        if (slot.activeItem && "settings" in slot.activeItem) slot.activeItem.settings = settings
      })
    })
  }

  function entries(region) {
    var serial = layoutSerial
    var list = layoutConfig ? layoutConfig[region] : null
    return Array.isArray(list) ? list : []
  }

  // A change to the bar as a whole goes into shell.json through the shell,
  // which hands it back as barConfig; without a shell it is only shown.
  function setBarPosition(value) {
    var next = BarModel.edge(value)
    if (!canSave()) {
      position = next
      return
    }
    shell.mutateShellConfig(function(config) {
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      config.bar.position = next
    })
  }

  function toggleTransparency() {
    var next = transparentWanted !== true
    if (!canSave()) {
      setTransparentWanted(next)
      return
    }
    shell.mutateShellConfig(function(config) {
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      config.bar.transparent = next
    })
  }

  function canSave() {
    return !!shell && typeof shell.mutateShellConfig === "function"
  }

  function run(command) {
    if (command) Util.execDetached(command)
  }

  // ----------------------------------------------------------- transparent

  // A transparent bar's text takes the colour nova-bar-text-color picks to
  // read on the background behind the bar. Until it answers the bar keeps
  // its theme's look, and it asks again when the edge, the theme or the
  // background change. The colour is set without fading, as is the return
  // to the theme's.
  property bool transparentWanted: false
  property bool measuredForegroundShown: false
  property color measuredForeground: foreground

  function setTransparentWanted(wanted) {
    transparentWanted = wanted === true
    if (transparentWanted) {
      measureForeground()
      return
    }
    foregroundAnimationEnabled = false
    measuredForegroundShown = false
    transparent = false
    measuredForeground = foreground
    fadeForegroundAgain()
  }

  // Two turns later, once the colour has been drawn without a fade.
  function fadeForegroundAgain() {
    Qt.callLater(function() {
      Qt.callLater(function() { root.foregroundAnimationEnabled = true })
    })
  }

  function measureForeground() {
    if (transparentWanted) measureTimer.restart()
    else measuredForeground = foreground
  }

  onTransparentWantedChanged: measureForeground()
  onPositionChanged: measureForeground()
  onForegroundChanged: measureForeground()
  readonly property color contrastForeground: Commons.Color.background
  onContrastForegroundChanged: measureForeground()

  Timer {
    id: measureTimer
    interval: 120
    onTriggered: {
      if (!root.transparentWanted || textColor.running) return
      textColor.command = ["nova-bar-text-color", root.position, String(root.barSize),
        root.hex(root.foreground), root.hex(root.contrastForeground)]
      textColor.running = true
    }
  }

  function hex(color) {
    var c = typeof color === "string" ? Qt.color(color) : color
    return BarModel.hex(c.r, c.g, c.b)
  }

  Process {
    id: textColor
    stdout: SplitParser {
      onRead: function(line) {
        var color = String(line || "").trim()
        if (!/^#[0-9A-Fa-f]{6}$/.test(color)) return
        root.foregroundAnimationEnabled = false
        root.measuredForeground = color
        if (root.transparentWanted) {
          root.measuredForegroundShown = true
          root.transparent = true
        }
        root.fadeForegroundAgain()
      }
    }
  }

  // A new theme or background.
  FileView {
    path: root.stateHome + "/nova/current"
    watchChanges: true
    printErrors: false
    onFileChanged: root.measureForeground()
  }

  // ---------------------------------------------------------------- hidden

  // nova-toggle-bar hides the bar by making a flag file, read by its
  // presence. The bar is parked past its screen's edge rather than unmapped:
  // a mapped surface keeps its glyphs and textures, so showing it again is a
  // margin's change (about 20 ms) rather than a new surface (about 150 ms).
  // The folder is watched, as a file that is not there cannot be.
  Process {
    id: hiddenProbe
    running: true
    command: ["test", "-f", root.stateHome + "/nova/toggles/bar-off"]
    onExited: function(exitCode) { root.barHidden = exitCode === 0 }
  }

  FileView {
    path: root.stateHome + "/nova/toggles"
    watchChanges: true
    printErrors: false
    onFileChanged: hiddenProbe.running = true
  }

  // The folder's watch can stop for good after quick changes, which would
  // leave the bar hidden until the shell restarts, so nova-toggle-bar also
  // asks the bar to look. A look already running started after the flag
  // changed, and stopping it could lose its answer, so it is let finish.
  IpcHandler {
    target: "nova.bar"

    function syncHidden(): void {
      hiddenProbe.running = true
    }
  }

  BarIpc { bar: root }

  // ----------------------------------------------------------------- slots

  function registerModuleSlot(slot) {
    if (slot && moduleSlots.indexOf(slot) === -1) moduleSlots = moduleSlots.concat([slot])
  }

  function unregisterModuleSlot(slot) {
    if (moduleSlots.indexOf(slot) !== -1) moduleSlots = moduleSlots.filter(function(other) { return other !== slot })
  }

  function registerClickTarget(target) {
    if (target && clickTargets.indexOf(target) === -1) clickTargets = clickTargets.concat([target])
  }

  function unregisterClickTarget(target) {
    if (clickTargets.indexOf(target) !== -1) clickTargets = clickTargets.filter(function(other) { return other !== target })
  }

  function windowOf(item) {
    return item && item.QsWindow ? item.QsWindow.window : null
  }

  function slotWindow(slot) {
    return slot ? windowOf(slot.activeItem) || windowOf(slot) : null
  }

  function targetBelongsToWindow(target, window) {
    return !!target && !!window && windowOf(target) === window
  }

  // Two windows on one screen are one bar: a window can be replaced while
  // the screen stays.
  function sameBar(left, right) {
    if (!left || !right) return false
    if (left === right) return true
    return !!left.screen && !!right.screen && !!left.screen.name && left.screen.name === right.screen.name
  }

  function slotScreenName(slot) {
    var window = slotWindow(slot)
    return window && window.screen ? String(window.screen.name || "") : ""
  }

  // The output Hyprland has focused, where a panel opened by a key belongs.
  // Empty until Hyprland names one, which leaves the choice to pickPanelSlot.
  function focusedScreenName() {
    var monitor = Hyprland.focusedMonitor
    return monitor ? String(monitor.name || "") : ""
  }

  function isDrawn(slot) {
    return !!slot && slot.visible === true && slot.width > 0 && slot.height > 0
  }

  // Every live copy of a widget, one per screen's bar.
  function moduleWidgets(pluginId) {
    var id = String(pluginId || "")
    if (!id) return []
    return moduleSlots.filter(function(slot) { return slot && slot.activeItem && slot.moduleName === id })
      .map(function(slot) { return slot.activeItem })
  }

  // ---------------------------------------------------------------- panels

  function isPanel(item) {
    return !!item && typeof item.open === "function" && typeof item.close === "function" && item.opened !== undefined
  }

  // A section's panels on one bar, in the order the bar shows them, for
  // stepping from one to the next and for numbering them: widgets without a
  // panel, and those hidden, are passed over.
  function panelSlots(region, window) {
    var found = []
    entries(region).forEach(function(entry) {
      var id = BarModel.entryId(entry)
      for (var i = 0; i < moduleSlots.length; i++) {
        var slot = moduleSlots[i]
        if (!slot || slot.region !== region || slot.moduleName !== id) continue
        if (window && !sameBar(slotWindow(slot), window)) continue
        if (!isDrawn(slot) || !slot.activeItem || slot.activeItem.visible !== true || !isPanel(slot.activeItem)) continue
        found.push(slot)
        break
      }
    })
    return found
  }

  // The id of the Nth panel a section shows, counting from one, as the keys
  // number them; "" past the last. Any bar can be counted, as all lay out
  // the same layout, and the id opens on the focused screen.
  function panelWidgetIdAt(region, index) {
    var slot = panelSlots(String(region || ""), null)[Math.round(Number(index)) - 1]
    return slot ? String(slot.moduleName || "") : ""
  }

  // Opens the panel before (direction < 0) or after the one `owner` shows,
  // on the same bar, round from the last to the first.
  function switchPanelFrom(owner, direction) {
    if (!owner) return false
    var current = null
    for (var i = 0; i < moduleSlots.length && !current; i++) {
      if (moduleSlots[i] && moduleSlots[i].activeItem === owner) current = moduleSlots[i]
    }
    if (!current) return false
    var slots = panelSlots(current.region, slotWindow(current))
    var at = slots.indexOf(current)
    if (slots.length < 2 || at === -1) return false
    var next = slots[(at + (direction < 0 ? -1 : 1) + slots.length) % slots.length]
    if (!next || !next.activeItem || next.activeItem === owner) return false
    next.activeItem.open()
    return true
  }

  // The copy of a widget with a panel that a key acts on (BarModel.pickPanelSlot).
  function panelWidget(pluginId) {
    var id = String(pluginId || "")
    if (!id) return null
    var copies = []
    moduleSlots.forEach(function(slot) {
      if (!slot || !slot.activeItem || slot.moduleName !== id || !isPanel(slot.activeItem)) return
      copies.push({ slot: slot, screenName: slotScreenName(slot), opened: slot.activeItem.opened === true })
    })
    var chosen = BarModel.pickPanelSlot(copies, focusedScreenName())
    return chosen ? chosen.activeItem : null
  }

  // shell.qml's summon, hide and toggle, for panels that live in the bar.
  function summonBarWidget(pluginId) {
    var item = panelWidget(pluginId)
    if (!item) return false
    item.open()
    return true
  }

  function hideBarWidget(pluginId) {
    var item = panelWidget(pluginId)
    if (!item) return false
    item.close()
    return true
  }

  function isBarWidgetOpen(pluginId) {
    var item = panelWidget(pluginId)
    return !!item && item.opened === true
  }

  // One popup at a time: the one asked for closes the one open.
  function requestPopout(owner) {
    if (activePopout === owner) return
    if (activePopout) {
      if ("closeForPopoutSwitch" in activePopout) activePopout.closeForPopoutSwitch()
      else if ("close" in activePopout) activePopout.close()
    }
    activePopout = owner
  }

  function releasePopout(owner) {
    if (activePopout === owner) activePopout = null
  }

  // --------------------------------------------------------------- tooltip

  // A widget the pointer enters asks for its tooltip, which is taken a turn
  // later if the pointer is still there and shown after 400 ms on it.
  property var tooltipTarget: null
  property string tooltipText: ""
  property bool tooltipShown: false
  property var tooltipAsked: null
  property int tooltipSerial: 0

  function onTarget(target) {
    return !!target && target.visible !== false && target.opacity !== 0 && target.tooltipHovered === true
  }

  function dropTooltip() {
    tooltipDelay.stop()
    tooltipAsked = null
    tooltipTarget = null
    tooltipText = ""
    tooltipShown = false
  }

  function showTooltip(target, text) {
    dropTooltip()
    var serial = ++tooltipSerial
    if (!onTarget(target) || !text) return
    tooltipAsked = { target: target, text: text }
    Qt.callLater(function() {
      if (serial !== root.tooltipSerial) return
      var asked = root.tooltipAsked
      if (!asked || !root.onTarget(asked.target)) {
        root.dropTooltip()
        return
      }
      root.tooltipAsked = null
      root.tooltipTarget = asked.target
      root.tooltipText = asked.text
      tooltipDelay.restart()
    })
  }

  function hideTooltip(target) {
    var asked = tooltipAsked ? tooltipAsked.target : null
    if (tooltipTarget !== target && asked !== target) return
    tooltipSerial++
    dropTooltip()
  }

  Timer {
    id: tooltipDelay
    interval: 400
    onTriggered: {
      if (root.onTarget(root.tooltipTarget)) root.tooltipShown = true
      else root.dropTooltip()
    }
  }

  // A widget that hides or moves away under the pointer sends no leave.
  Timer {
    interval: 100
    running: root.tooltipShown
    repeat: true
    onTriggered: if (!root.onTarget(root.tooltipTarget)) root.hideTooltip(root.tooltipTarget)
  }

  // ------------------------------------------------------------ the peek

  // The indicators' hidden icons show while the pointer is on the centre,
  // and stay until it leaves the bar: showing them widens the centre, which
  // can slide a neighbour under a pointer that has not moved, and hiding
  // them on that would slide it back and show them again.
  property bool centerSectionRevealHeld: false
  property bool centerHoverRevealSuppressed: false
  property bool centerHovered: false
  // Each screen's bar counts itself in, so a pointer crossing from one bar
  // to another is counted whichever of enter and leave comes first.
  property int barsHovered: 0

  function setCenterSectionHovered(hovered) {
    centerHovered = hovered
    if (!hovered) {
      revealEnd.restart()
      return
    }
    revealEnd.stop()
    centerSectionRevealHeld = true
  }

  function setBarHovered(hovered) {
    barsHovered = Math.max(0, barsHovered + (hovered ? 1 : -1))
    if (barsHovered === 0) revealEnd.restart()
  }

  // A clock or weather panel open over the centre keeps the peek closed.
  function setCenterHoverRevealSuppressed(value) {
    centerHoverRevealSuppressed = !!value
  }

  // It only ends the peek: a pointer that left the bar and came back has
  // not pointed at the centre again.
  Timer {
    id: revealEnd
    interval: 120
    onTriggered: if (!root.centerHovered && root.barsHovered === 0) root.centerSectionRevealHeld = false
  }

  // ---------------------------------------------------- dragging a widget

  QtObject {
    id: widgetDrag

    property var slot: null
    property var window: null
    property var screen: null
    property url image: ""
    property var target: null
    property bool after: false
    // The drop marker, in the screen's coordinates.
    property var marker: null
    // The pointer on the screen, and where it holds the widget.
    property real x: 0
    property real y: 0
    property real offsetX: 0
    property real offsetY: 0

    function clear() {
      slot = null
      window = null
      screen = null
      image = ""
      target = null
      marker = null
      after = false
      x = 0
      y = 0
      offsetX = 0
      offsetY = 0
    }
  }

  function windowPointOnScreen(point, window) {
    if (!window || !window.screen) return { x: point ? point.x : 0, y: point ? point.y : 0 }
    return BarModel.onScreen(point, position, window.screen.width, window.screen.height, window.width, window.height)
  }

  function startWidgetDrag(slot, pressX, pressY) {
    widgetDrag.window = slotWindow(slot)
    widgetDrag.screen = widgetDrag.window ? widgetDrag.window.screen : null
    widgetDrag.offsetX = pressX
    widgetDrag.offsetY = pressY
    // A picture of the widget follows the pointer.
    widgetDrag.image = ""
    var item = slot.activeItem
    if (item && typeof item.grabToImage === "function") {
      var width = Math.max(1, Math.ceil(item.width || item.implicitWidth || slot.width || 1))
      var height = Math.max(1, Math.ceil(item.height || item.implicitHeight || slot.height || 1))
      item.grabToImage(function(result) {
        if (widgetDrag.slot === slot && result && result.url) widgetDrag.image = result.url
      }, Qt.size(width, height))
    }
    widgetDrag.slot = slot
  }

  function moveWidgetDrag(slot, scenePoint) {
    var point = windowPointOnScreen(scenePoint, widgetDrag.window)
    widgetDrag.x = point.x
    widgetDrag.y = point.y
    var drop = dropAt(scenePoint, slot)
    widgetDrag.target = drop ? drop.slot : null
    widgetDrag.after = drop ? drop.after : false
    widgetDrag.marker = drop ? markerAt(drop.slot, drop.after) : null
  }

  // The place before or after a widget on the dragged widget's bar nearest
  // the pointer, or null with the pointer off that bar.
  function dropAt(scenePoint, dragged) {
    var window = slotWindow(dragged) || widgetDrag.window
    if (window && window.contentItem) {
      var point = window.contentItem.mapFromItem(null, scenePoint.x, scenePoint.y)
      if (point.x < 0 || point.x > window.contentItem.width || point.y < 0 || point.y > window.contentItem.height) return null
    }
    var places = []
    moduleSlots.forEach(function(slot) {
      if (!slot || slot === dragged || !slot.visible || slot.width <= 0 || slot.height <= 0) return
      if (window && !sameBar(slotWindow(slot), window)) return
      var at = { x: slot.x, y: slot.y }
      try {
        at = slot.mapToItem(null, 0, 0)
      } catch (e) {
      }
      places.push({ slot: slot, x: at.x, y: at.y, width: slot.width, height: slot.height })
    })
    return BarModel.dropPlace(places, scenePoint, vertical)
  }

  function markerAt(slot, after) {
    try {
      var point = windowPointOnScreen(slot.mapToItem(null, 0, 0), widgetDrag.window)
      return BarModel.dropMarker(point, slot.width, slot.height, after, vertical, Style.spacing.xs)
    } catch (e) {
      return null
    }
  }

  // Drops the dragged widget before the target, or after it: before the next
  // widget shown on that bar, which a hidden one in between leaves in place.
  function dropWidget(dragged, target, after) {
    if (!dragged || !target) return false
    var beforeId = after ? nextShownId(target.region, target.moduleName, dragged) : target.moduleName
    if (!dragged.region || !dragged.moduleName || !target.region) return false
    if (dragged.region === target.region && dragged.moduleName === beforeId) return false
    if (!canSave()) return false
    var moved = false
    shell.mutateShellConfig(function(config) {
      moved = BarModel.moveEntry(config, dragged.region, dragged.moduleName, target.region, beforeId)
    })
    return moved
  }

  function nextShownId(region, afterId, dragged) {
    var window = slotWindow(dragged) || widgetDrag.window
    var list = entries(region)
    var at = BarModel.indexOfId(list, afterId)
    for (var i = at === -1 ? list.length : at + 1; i < list.length; i++) {
      var id = BarModel.entryId(list[i])
      var shown = moduleSlots.some(function(slot) {
        return slot && slot !== dragged && slot.region === region && slot.moduleName === id
          && slot.visible && slot.width > 0 && slot.height > 0 && (!window || sameBar(slotWindow(slot), window))
      })
      if (shown) return id
    }
    return ""
  }

  // ---------------------------------------------------- moving the bar

  QtObject {
    id: edgeMove

    property bool active: false
    property string edge: ""
    property var window: null
    property var screen: null
  }

  function startEdgeMove(window) {
    edgeMove.window = window
    edgeMove.screen = window ? window.screen : null
    edgeMove.edge = position
    edgeMove.active = true
  }

  function moveEdgeMove(screenPoint) {
    if (edgeMove.active && edgeMove.screen)
      edgeMove.edge = BarModel.nearestEdge(screenPoint, edgeMove.screen.width, edgeMove.screen.height)
  }

  function endEdgeMove(drop) {
    var edge = edgeMove.edge
    var moved = drop && edgeMove.active && edge !== "" && edge !== position
    edgeMove.active = false
    edgeMove.edge = ""
    edgeMove.window = null
    edgeMove.screen = null
    if (moved) setBarPosition(edge)
  }

  // -------------------------------------------------------------- clicks

  // The slot over a widget takes the press, to tell a drag from a click, and
  // hands a click to the widget's clickable part under the pointer.
  function clickable(target) {
    return !!target && target.visible !== false && target.opacity !== 0 && target.interactive !== false
      && target.pressable !== false && target.concealed !== true && typeof target.triggerPress === "function"
  }

  function clickTargetAt(slot, x, y) {
    for (var i = clickTargets.length - 1; i >= 0; i--) {
      var target = clickTargets[i]
      if (!clickable(target)) continue
      var point
      try {
        point = slot.mapToItem(target, x, y)
      } catch (e) {
        continue
      }
      if (point.x >= 0 && point.x <= target.width && point.y >= 0 && point.y <= target.height) return target
    }
    return clickable(slot.activeItem) ? slot.activeItem : null
  }

  // ------------------------------------------------------------- windows

  Variants {
    model: Quickshell.screens
    delegate: Component {
      BarWindow {
        required property var modelData
        screen: modelData
      }
    }
  }

  Variants {
    model: Quickshell.screens
    delegate: Component {
      DragGhost {
        required property var modelData
        screen: modelData
        ghostScreen: modelData
      }
    }
  }

  Variants {
    model: Quickshell.screens
    delegate: Component {
      EdgeGhost {
        required property var modelData
        screen: modelData
        ghostScreen: modelData
      }
    }
  }

  component BarWindow: PanelWindow {
    id: barWindow

    visible: !remap.remapping
    exclusionMode: root.barHidden ? ExclusionMode.Ignore : ExclusionMode.Auto
    implicitWidth: root.vertical ? root.barSize : 0
    implicitHeight: root.vertical ? 0 : root.barSize
    color: root.transparent ? "transparent" : root.background
    surfaceFormat.opaque: false
    WlrLayershell.namespace: "nova-bar"
    WlrLayershell.layer: WlrLayer.Top

    anchors {
      top: root.position !== "bottom"
      bottom: root.position !== "top"
      left: root.position !== "right"
      right: root.position !== "left"
    }

    // Hidden, the bar sits just past its edge.
    margins {
      top: root.barHidden && root.position === "top" ? -root.barSize : 0
      bottom: root.barHidden && root.position === "bottom" ? -root.barSize : 0
      left: root.barHidden && root.position === "left" ? -root.barSize : 0
      right: root.barHidden && root.position === "right" ? -root.barSize : 0
    }

    ScreenMoveRemap {
      id: remap
      window: barWindow
    }

    Loader {
      anchors.fill: parent
      sourceComponent: root.vertical ? verticalSections : horizontalSections

      // On the Loader, not beside the sections: an ancestor stays hovered
      // while the pointer is on a widget, where a sibling would lose it.
      HoverHandler {
        onHoveredChanged: root.setBarHovered(hovered)
        // A screen unplugged takes its bar without a leave.
        Component.onDestruction: if (hovered) root.setBarHovered(false)
      }
    }

    Component {
      id: horizontalSections
      Sections { vertical: false }
    }

    Component {
      id: verticalSections
      Sections { vertical: true }
    }

    PopupWindow {
      id: tooltip

      visible: root.tooltipShown && root.tooltipTarget !== null && root.tooltipText !== ""
        && root.targetBelongsToWindow(root.tooltipTarget, barWindow)
      color: "transparent"
      implicitWidth: Math.ceil(bubble.implicitWidth)
      implicitHeight: Math.ceil(bubble.implicitHeight)

      // 6 px off the widget, on the side away from the edge.
      anchor {
        id: tooltipAnchor
        window: barWindow
        adjustment: PopupAdjustment.Slide
        edges: Edges.Top | Edges.Left
        gravity: Edges.Bottom | Edges.Right
        rect.width: 1
        rect.height: 1

        onAnchoring: {
          var target = root.tooltipTarget
          if (!root.targetBelongsToWindow(target, barWindow)) return
          var x = target.width / 2 - tooltip.implicitWidth / 2
          var y = target.height + 6
          if (root.position === "bottom") {
            y = -tooltip.implicitHeight - 6
          } else if (root.vertical) {
            x = root.position === "left" ? target.width + 6 : -tooltip.implicitWidth - 6
            y = target.height / 2 - tooltip.implicitHeight / 2
          }
          var point = barWindow.contentItem.mapFromItem(target, x, y)
          tooltipAnchor.rect.x = Math.round(point.x)
          tooltipAnchor.rect.y = Math.round(point.y)
        }
      }

      BorderSurface {
        id: bubble
        implicitWidth: tooltipLabel.implicitWidth + 20
        implicitHeight: tooltipLabel.implicitHeight + 14
        color: Commons.Color.tooltip.background
        borderSpec: Border.surfaceSpec("tooltip", "border", Commons.Color.tooltip.border, 1)
        radius: Style.cornerRadius

        Text {
          id: tooltipLabel
          anchors.centerIn: parent
          text: root.tooltipText
          textFormat: Text.PlainText
          color: Commons.Color.tooltip.text
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
        }
      }
    }
  }

  // The dragged widget's picture under the pointer, and the marker where it
  // would land, over everything on the screen it is dragged on. Its input
  // region is empty, so the pointer stays with the slot dragging.
  component DragGhost: PanelWindow {
    id: ghost

    required property var ghostScreen
    readonly property bool active: !!widgetDrag.slot && !!widgetDrag.screen && root.sameScreen(widgetDrag.screen, ghostScreen)
    readonly property var item: widgetDrag.slot ? widgetDrag.slot.activeItem : null
    readonly property int padding: Style.space(1)

    visible: active && item !== null
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "nova-bar-drag-ghost"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    anchors { top: true; bottom: true; left: true; right: true }
    mask: Region {}

    Item {
      visible: ghost.visible
      x: Math.round(widgetDrag.x - widgetDrag.offsetX - ghost.padding)
      y: Math.round(widgetDrag.y - widgetDrag.offsetY - ghost.padding)
      width: (ghost.item ? Math.max(1, Math.ceil(ghost.item.width)) : 1) + ghost.padding * 2
      height: (ghost.item ? Math.max(1, Math.ceil(ghost.item.height)) : 1) + ghost.padding * 2

      BorderSurface {
        anchors.fill: parent
        color: root.transparent ? "transparent" : root.background
        borderSpec: Border.flat(root.barForeground, 1)
        radius: Math.min(Style.cornerRadius, height / 2)
        opacity: root.transparent ? 0.45 : 0.94
      }

      Image {
        anchors.fill: parent
        anchors.margins: ghost.padding
        source: widgetDrag.image
        fillMode: Image.Stretch
        smooth: true
        opacity: 0.84
      }
    }

    Rectangle {
      readonly property var marker: widgetDrag.marker

      visible: ghost.active && marker !== null
      x: marker ? Math.round(marker.x) : 0
      y: marker ? Math.round(marker.y) : 0
      width: marker ? marker.width : 0
      height: marker ? marker.height : 0
      color: Commons.Color.accent
      radius: Math.min(width, height) / 2
    }
  }

  // The edge a dragged bar would go to, shown as a bar there. One slab per
  // edge, faded in and out: a single slab resized from edge to edge repaints
  // halfway and flickers.
  component EdgeGhost: PanelWindow {
    required property var ghostScreen

    visible: edgeMove.active && root.sameScreen(edgeMove.screen, ghostScreen)
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "nova-bar-move-ghost"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    anchors { top: true; bottom: true; left: true; right: true }
    mask: Region {}

    Repeater {
      model: ["top", "bottom", "left", "right"]

      BorderSurface {
        required property string modelData
        readonly property bool across: modelData === "left" || modelData === "right"
        readonly property int size: across ? Style.bar.sizeVertical : Style.bar.sizeHorizontal

        x: modelData === "right" ? parent.width - size : 0
        y: modelData === "bottom" ? parent.height - size : 0
        width: across ? size : parent.width
        height: across ? parent.height : size
        color: root.transparent ? "transparent" : root.background
        borderSpec: Border.flat(root.barForeground, 1)
        visible: opacity > 0
        opacity: edgeMove.edge === modelData ? (root.transparent ? 0.45 : 0.7) : 0

        Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
      }
    }
  }

  function sameScreen(screen, other) {
    return screen === other || (!!screen && !!other && !!screen.name && !!other.name && screen.name === other.name)
  }

  // ------------------------------------------------------------ sections

  // The left and right sections hang off the bar's ends, 8 px in; the centre
  // fills the bar, under them, and holds the gestures of the bar itself.
  // Built for one orientation: a bar turned on its side is built again, so
  // nothing in here follows root.vertical, which would build its widgets
  // once more on the way out.
  component Sections: Item {
    id: sections

    required property bool vertical

    anchors.fill: parent

    Center {
      vertical: sections.vertical
      anchors.fill: parent
    }

    ModuleList {
      vertical: sections.vertical
      region: "left"
      entries: root.entries("left")
      anchors.left: sections.vertical ? undefined : parent.left
      anchors.leftMargin: sections.vertical ? 0 : Style.space(8)
      anchors.verticalCenter: sections.vertical ? undefined : parent.verticalCenter
      anchors.top: sections.vertical ? parent.top : undefined
      anchors.topMargin: sections.vertical ? Style.space(8) : 0
      anchors.horizontalCenter: sections.vertical ? parent.horizontalCenter : undefined
    }

    ModuleList {
      vertical: sections.vertical
      region: "right"
      entries: root.entries("right")
      anchors.right: sections.vertical ? undefined : parent.right
      anchors.rightMargin: sections.vertical ? 0 : Style.space(8)
      anchors.verticalCenter: sections.vertical ? undefined : parent.verticalCenter
      anchors.bottom: sections.vertical ? parent.bottom : undefined
      anchors.bottomMargin: sections.vertical ? Style.space(8) : 0
      anchors.horizontalCenter: sections.vertical ? parent.horizontalCenter : undefined
    }
  }

  // The centre: its anchor widget at the bar's middle, the widgets before and
  // after it on either side; with no anchor in it, all of them centred as one.
  component Center: Item {
    id: center

    required property bool vertical
    readonly property var list: root.entries("center")
    readonly property int anchorAt: BarModel.indexOfId(list, root.centerAnchor)
    readonly property bool anchored: anchorAt !== -1

    BarGestures { anchors.fill: parent }

    HoverHandler {
      onHoveredChanged: root.setCenterSectionHovered(hovered)
    }

    ModuleList {
      vertical: center.vertical
      visible: !center.anchored
      region: "center"
      entries: center.list
      anchors.centerIn: parent
    }

    ModuleList {
      vertical: center.vertical
      visible: center.anchored
      region: "center"
      entries: BarModel.before(center.list, root.centerAnchor)
      anchors.right: center.vertical ? undefined : anchorSlot.left
      anchors.verticalCenter: center.vertical ? undefined : anchorSlot.verticalCenter
      anchors.bottom: center.vertical ? anchorSlot.top : undefined
      anchors.horizontalCenter: center.vertical ? anchorSlot.horizontalCenter : undefined
    }

    ModuleSlot {
      id: anchorSlot
      visible: center.anchored
      region: "center"
      entry: center.anchored ? center.list[center.anchorAt] : null
      anchors.centerIn: parent
    }

    ModuleList {
      vertical: center.vertical
      visible: center.anchored
      region: "center"
      entries: BarModel.after(center.list, root.centerAnchor)
      anchors.left: center.vertical ? undefined : anchorSlot.right
      anchors.verticalCenter: center.vertical ? undefined : anchorSlot.verticalCenter
      anchors.top: center.vertical ? anchorSlot.bottom : undefined
      anchors.horizontalCenter: center.vertical ? anchorSlot.horizontalCenter : undefined
    }
  }

  // The bar's own gestures, on its empty centre: hold or drag to take the
  // bar to another edge, double click for transparency.
  component BarGestures: MouseArea {
    id: gestures

    property bool moving: false
    property bool swallowClick: false
    property point pressedAt: Qt.point(0, 0)

    acceptedButtons: Qt.LeftButton
    cursorShape: moving ? Qt.ClosedHandCursor : Qt.ArrowCursor
    pressAndHoldInterval: 200

    function follow(x, y) {
      root.moveEdgeMove(root.windowPointOnScreen(gestures.mapToItem(null, x, y), edgeMove.window))
    }

    function startMoving(x, y) {
      if (moving) return
      moving = true
      root.startEdgeMove(root.windowOf(gestures))
      follow(x, y)
    }

    onPressed: function(mouse) {
      moving = false
      swallowClick = false
      pressedAt = Qt.point(mouse.x, mouse.y)
    }

    // A widget above passes its press-and-hold down without the grab, which
    // would leave the move with no release to end it.
    onPressAndHold: function(mouse) {
      if (pressed) startMoving(mouse.x, mouse.y)
    }

    onPositionChanged: function(mouse) {
      if (!(mouse.buttons & Qt.LeftButton)) return
      if (moving) follow(mouse.x, mouse.y)
      else if (Math.abs(mouse.x - pressedAt.x) + Math.abs(mouse.y - pressedAt.y) >= Style.space(4)) startMoving(mouse.x, mouse.y)
    }

    onReleased: function(mouse) {
      if (!moving) return
      moving = false
      swallowClick = true
      root.endEdgeMove(true)
      mouse.accepted = true
    }

    onCanceled: {
      moving = false
      swallowClick = false
      root.endEdgeMove(false)
    }

    onClicked: function(mouse) {
      if (!swallowClick) return
      swallowClick = false
      mouse.accepted = true
    }

    onDoubleClicked: function(mouse) {
      if (swallowClick) {
        swallowClick = false
        return
      }
      if (mouse.button !== Qt.LeftButton) return
      root.toggleTransparency()
      mouse.accepted = true
    }
  }

  // A run of widgets along the bar. One that is hidden builds none: the
  // centre declares its anchored and its plain arrangement and shows the one
  // that applies, and building both would run every centre widget twice.
  component ModuleList: Loader {
    id: strip

    required property bool vertical
    property var entries: []
    property string region: ""

    visible: entries.length > 0
    active: visible && entries.length > 0
    sourceComponent: vertical ? column : row
    width: item ? item.implicitWidth : 0
    height: item ? item.implicitHeight : 0

    Component {
      id: row
      Row { Slots { list: strip } }
    }

    Component {
      id: column
      Column { Slots { list: strip } }
    }
  }

  component Slots: Repeater {
    id: slots

    required property var list

    model: list.entries

    ModuleSlot {
      required property var modelData
      entry: modelData
      region: slots.list.region
    }
  }

  // One widget's place on the bar: it loads the widget, hands it the bar and
  // its settings, marks it while its panel is open, and drags it.
  component ModuleSlot: Item {
    id: slot

    required property var entry
    property string region: ""
    readonly property string moduleName: BarModel.entryId(entry)
    readonly property var moduleSettings: BarModel.entrySettings(entry)
    readonly property string customType: BarModel.customType(entry)
    // Read through `widgets`, so a widget added to the registry or taken
    // from it reloads the slot.
    readonly property var registryComponent: {
      var widgets = root.barWidgetRegistry.widgets
      if (customType) return null
      var registered = widgets[moduleName]
      return registered ? registered.component : null
    }
    readonly property bool fromFile: customType === "qml"
    readonly property var activeItem: fromFile ? file.item : content.item
    readonly property bool dragged: widgetDrag.slot === slot
    // How long the open-panel mark is along the bar: what the widget asks
    // for (a label in a padded slot, a stack on a vertical bar), or a little
    // over half the slot.
    readonly property real markLength: {
      var key = root.vertical ? "openPanelIndicatorHeight" : "openPanelIndicatorWidth"
      var asked = activeItem && key in activeItem ? activeItem[key] : undefined
      if (asked !== undefined && asked !== null && asked > 0) return Math.round(asked)
      return Math.max(Style.space(10), Math.round((root.vertical ? slot.height : slot.width) * 0.55))
    }

    implicitWidth: activeItem && activeItem.visible ? (root.vertical ? root.barSize : activeItem.implicitWidth) : 0
    implicitHeight: activeItem && activeItem.visible ? activeItem.implicitHeight : 0
    width: implicitWidth
    height: implicitHeight
    z: pointer.dragging ? 100 : 0

    Component.onCompleted: root.registerModuleSlot(slot)
    Component.onDestruction: {
      if (dragged) widgetDrag.clear()
      root.unregisterModuleSlot(slot)
    }

    onActiveItemChanged: Qt.callLater(hand)
    onModuleSettingsChanged: hand()

    function hand() {
      var item = activeItem
      if (!item) return
      if ("bar" in item) item.bar = root
      if ("moduleName" in item) item.moduleName = moduleName
      if ("settings" in item) item.settings = moduleSettings
    }

    HoverHandler { id: hover }

    // Where the dragged widget was.
    BorderSurface {
      visible: slot.dragged
      anchors.fill: parent
      anchors.margins: Style.space(1)
      color: root.transparent ? "transparent" : root.background
      borderSpec: Border.flat(root.barForeground, 1)
      radius: Math.min(Style.cornerRadius, height / 2)
      opacity: root.transparent ? 0.22 : 0.32
    }

    // A widget from the registry, a command's, or an empty one for an id
    // that is neither.
    Loader {
      id: content
      active: !slot.fromFile
      anchors.fill: parent
      opacity: slot.dragged ? 0.22 : 1.0
      sourceComponent: slot.registryComponent !== null ? slot.registryComponent
        : slot.customType === "command" ? commandWidget : nothing
      onLoaded: slot.handTwice()
    }

    // A QML widget of the user's, from its file.
    Loader {
      id: file
      active: slot.fromFile
      anchors.fill: parent
      opacity: slot.dragged ? 0.22 : 1.0
      source: {
        if (!slot.fromFile) return ""
        var path = BarModel.customSource(slot.entry, root.home, root.home + "/.config/nova")
        return path ? Util.fileUrl(path) : ""
      }
      onLoaded: slot.handTwice()
    }

    // Now, and again once the widget's own bindings have settled.
    function handTwice() {
      hand()
      Qt.callLater(hand)
    }

    Component {
      id: commandWidget
      CommandWidget { entry: slot.entry }
    }

    Component {
      id: nothing
      Item { visible: false }
    }

    // A short bar on the inside edge of a widget whose panel is open: under
    // it on a top bar, over it on a bottom one, beside it on the side bars,
    // pointing at the panel. Rounded down, as glyphs are drawn.
    Rectangle {
      readonly property int inset: Style.space(2)

      visible: opacity > 0
      opacity: root.activePopout === slot.activeItem && !slot.dragged ? 0.9 : 0
      color: Commons.Color.accent
      radius: Math.min(width, height) / 2
      width: root.vertical ? Style.space(2) : slot.markLength
      height: root.vertical ? slot.markLength : Style.space(2)
      x: root.vertical ? (root.position === "left" ? parent.width - width - inset : inset) : Math.floor((parent.width - width) / 2)
      y: root.vertical ? Math.floor((parent.height - height) / 2) : (root.position === "top" ? parent.height - height - inset : inset)
      z: 50

      Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
    }

    // Moving the slot itself would leave the Row or Column that places it
    // with a stale offset after a short drag, so the drag is drawn by the
    // ghost window and the slot stays put.
    MouseArea {
      id: pointer

      property bool dragging: false
      property bool swallowClick: false
      property point pressedAt: Qt.point(0, 0)

      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      enabled: slot.visible && slot.width > 0 && slot.height > 0
      propagateComposedEvents: true
      // Asked only of the slot under the pointer: every slot on every
      // screen would look again at each change of the click targets.
      cursorShape: hover.hovered && root.clickTargetAt(slot, mouseX, mouseY) ? Qt.PointingHandCursor : Qt.ArrowCursor

      onPressed: function(mouse) {
        dragging = false
        swallowClick = false
        pressedAt = Qt.point(mouse.x, mouse.y)
        widgetDrag.clear()
      }

      onPositionChanged: function(mouse) {
        if (!root.canSave() || !(mouse.buttons & Qt.LeftButton)) return
        if (Math.abs(mouse.x - pressedAt.x) + Math.abs(mouse.y - pressedAt.y) >= Style.space(4)) {
          if (!dragging) root.startWidgetDrag(slot, pressedAt.x, pressedAt.y)
          dragging = true
          root.hideTooltip(slot.activeItem)
        }
        if (dragging) root.moveWidgetDrag(slot, slot.mapToItem(null, mouse.x, mouse.y))
      }

      onReleased: function(mouse) {
        var wasDragging = dragging
        var target = widgetDrag.target
        var after = widgetDrag.after
        dragging = false
        widgetDrag.clear()
        if (!wasDragging) {
          mouse.accepted = false
          return
        }
        swallowClick = true
        if (!target) return
        root.dropWidget(slot, target, after)
        mouse.accepted = true
      }

      onCanceled: {
        dragging = false
        swallowClick = false
        widgetDrag.clear()
      }

      onClicked: function(mouse) {
        if (swallowClick) {
          swallowClick = false
          mouse.accepted = true
          return
        }
        var target = root.clickTargetAt(slot, mouse.x, mouse.y)
        if (target) target.triggerPress(mouse.button)
        else mouse.accepted = false
      }
    }
  }

  // A user's widget showing a command's output, run every `interval`
  // seconds: plain text, or Waybar's JSON ({"text", "tooltip", "class"}),
  // where a class of "active" draws it in the urgent colour. A click runs
  // onClick, onMiddleClick or onRightClick.
  component CommandWidget: WidgetButton {
    id: custom

    required property var entry
    // Read from its own entry. Not named `settings`: the slot hands a
    // widget with that property its settings, which a read-only one
    // refuses with an error.
    readonly property var options: BarModel.entrySettings(entry)
    property string outputText: ""
    property string outputTooltip: ""
    property bool outputActive: false

    function setting(name, fallback) {
      var value = options ? options[name] : undefined
      return value === undefined || value === null ? fallback : value
    }

    bar: root
    text: outputText || String(setting("text", ""))
    tooltipText: outputTooltip || String(setting("tooltip", ""))
    active: outputActive
    keepSpace: setting("keepSpace", false) === true
    horizontalMargin: Number(setting("horizontalMargin", 7.5))
    verticalPadding: Number(setting("verticalPadding", 6))
    fontSize: Number(setting("fontSize", 12))

    onPressed: function(button) {
      var key = button === Qt.RightButton ? "onRightClick" : button === Qt.MiddleButton ? "onMiddleClick" : "onClick"
      root.run(String(setting(key, "")))
    }

    Process {
      id: output
      command: ["bash", "-lc", String(custom.setting("exec", ""))]
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          var data = Util.parseModuleJson(text)
          var kind = data.class || data.alt || ""
          custom.outputText = data.text || String(text || "").trim()
          custom.outputTooltip = data.tooltip || String(custom.setting("tooltip", ""))
          custom.outputActive = kind === "active" || (Array.isArray(kind) && kind.indexOf("active") !== -1)
        }
      }
    }

    Timer {
      interval: Math.max(1, Number(custom.setting("interval", 5))) * 1000
      running: String(custom.setting("exec", "")) !== ""
      repeat: true
      triggeredOnStart: true
      onTriggered: if (!output.running) output.running = true
    }
  }
}
