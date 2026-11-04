import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Commons as Commons
import "BarModel.js" as BarModel

// Nova's bar: one on every screen, along the edge its part of shell.json
// names, with the widgets of its layout in three sections. The shell hands
// it that part (barConfig) and the registry of widgets; what is changed on
// the bar itself (a widget dragged to another place, the bar dragged to
// another edge or made see-through) is saved through the shell, which
// hands the bar its new config.
//
// The widgets are handed this item as `bar`, and what they use of it is
// listed in README.md. It is made of:
//   ScreenBar   one screen's bar window, its tooltip and its overlays
//   Sections    the three sections in that window, and the bar's gestures
//   WidgetSlot  one widget's place: it loads the widget and drags it
//   SeeThrough  the text colour of a see-through bar
//   Tip         the one tooltip
//   WidgetDrag  a widget being dragged; BarDrag, the bar
//   BarIpc      the IPC targets of the widgets
Item {
  id: root

  // ---------------------------------------------------- from the shell

  property var barWidgetRegistry: ({ widgets: {} })
  property var barConfig: ({})
  property var shell: null

  // ----------------------------------------------------------- the look

  property string position: "top"
  readonly property bool vertical: position === "left" || position === "right"
  readonly property int barSize: vertical ? Style.bar.sizeVertical : Style.bar.sizeHorizontal
  // "monospace" until fontconfig resolves it as it draws, so that a new
  // system font (nova-font-set) reaches the bar without a reload.
  property string fontFamily: Style.font.family
  property color foreground: Commons.Color.bar.text
  property color background: Commons.Color.bar.background
  property color urgent: Commons.Color.bar.active
  // The text colour as drawn: the theme's, or the one picked to read on the
  // wallpaper while the bar is see-through.
  property color barForeground: seeThrough.shown ? seeThrough.colour : foreground
  readonly property bool foregroundAnimationEnabled: seeThrough.fades
  readonly property bool transparent: seeThrough.shown
  property bool barHidden: false

  component Fade: ColorAnimation { duration: 420; easing.type: Easing.InOutCubic }

  Behavior on barForeground {
    enabled: root.foregroundAnimationEnabled
    Fade {}
  }
  Behavior on background { Fade {} }
  Behavior on urgent { Fade {} }

  readonly property SeeThrough seeThrough: SeeThrough {
    edge: root.position
    thickness: root.barSize
    text: root.foreground
    backdrop: Commons.Color.background
  }

  // --------------------------------------------------------- the layout

  // The sections as built, each a list of entries: replaced when the
  // widgets have to be built again, changed in place when only their
  // settings change. The centre's anchor is the id of the widget it hangs
  // off, or "" for none.
  property var builtLayout: ({ left: [], center: [], right: [] })
  property string anchorId: ""

  onBarConfigChanged: settle()

  // shell.qml hands the bar its shell. Without one the bar still draws, but
  // a change made on it is not saved, which the checks on `shell` below
  // would hide; it is said once, where the smoke tests see it.
  Component.onCompleted: {
    if (!shell) console.warn("Bar: started without its shell; layout changes cannot be saved")
    settle()
  }

  function settle() {
    var config = Util.isPlainObject(barConfig) ? barConfig : ({})
    position = BarModel.edge(config.position)
    seeThrough.want(config.transparent === true)

    var next = Util.normalizeLayout(config.layout)
    for (var section in next) next[section] = BarModel.trayInward(next[section], section)
    anchorId = BarModel.centerAnchor(config.centerAnchor, next.center)

    // A Repeater cannot tell two lists of entries apart, so a new layout
    // builds every widget on every screen again. A change of settings alone
    // (the battery's percentage, the clock's format) is handed to the
    // widgets in place instead.
    var changes = BarModel.settingsOnlyChanges(builtLayout, next)
    if (changes === null) {
      builtLayout = next
      return
    }
    changes.forEach(function(change) {
      builtLayout[change.region][change.index] = change.entry
      var id = BarModel.entryId(change.entry)
      var settings = BarModel.entrySettings(change.entry)
      moduleSlots.forEach(function(slot) {
        var widget = slot && slot.section === change.region && slot.moduleName === id ? slot.activeItem : null
        if (widget && "settings" in widget) widget.settings = settings
      })
    })
  }

  // A change to the bar as a whole is saved into shell.json through the
  // shell, which hands it back; with no shell it is only shown.
  function canSave() {
    return !!shell && typeof shell.mutateShellConfig === "function"
  }

  function saveBar(change) {
    shell.mutateShellConfig(function(config) {
      if (!Util.isPlainObject(config.bar)) config.bar = {}
      change(config.bar)
    })
  }

  function putOnEdge(edge) {
    var to = BarModel.edge(edge)
    if (canSave()) saveBar(function(part) { part.position = to })
    else position = to
  }

  function toggleSeeThrough() {
    var on = !seeThrough.wanted
    if (canSave()) saveBar(function(part) { part.transparent = on })
    else seeThrough.want(on)
  }

  // Runs <command> with bash, and does not wait for it.
  function run(command) {
    if (command) Util.execDetached(command)
  }

  // ------------------------------------------------------------- hidden

  // nova-toggle-bar hides the bar with a flag file, bar-off, read by its
  // being there. A hidden bar is not unmapped but moved past its screen's
  // edge (ScreenBar): a mapped surface keeps its glyphs and textures, so it
  // is back with a change of margin (about 20 ms) rather than as a new
  // surface (about 150 ms).
  readonly property string togglesDir: Commons.Color.stateHome + "/nova/toggles"

  Process {
    id: flagLook
    running: true
    command: ["test", "-f", root.togglesDir + "/bar-off"]
    onExited: function(exitCode) { root.barHidden = exitCode === 0 }
  }

  // A file that is not there cannot be watched, so its folder is.
  FileView {
    path: root.togglesDir
    watchChanges: true
    printErrors: false
    onFileChanged: flagLook.running = true
  }

  // That watch can stop for good after quick changes, which would leave the
  // bar hidden until the shell restarts, so nova-toggle-bar asks as well. A
  // look under way began after the flag changed and is let finish: stopped,
  // its answer could be lost.
  IpcHandler {
    target: "nova.bar"

    function syncHidden(): void {
      flagLook.running = true
    }
  }

  BarIpc {
    bar: root
  }

  // ---------------------------------------------------- slots and buttons

  // The slot of every widget on every screen's bar, in the order they came;
  // and every button that takes a click (WidgetButton lists itself), for a
  // click on the slot or on the bar under an open panel.
  property var moduleSlots: []
  property var clickTargets: []

  function enlist(slot) {
    if (moduleSlots.indexOf(slot) === -1) moduleSlots = moduleSlots.concat([slot])
  }

  function delist(slot) {
    if (moduleSlots.indexOf(slot) !== -1) moduleSlots = moduleSlots.filter(function(other) { return other !== slot })
  }

  function registerClickTarget(button) {
    if (button && clickTargets.indexOf(button) === -1) clickTargets = clickTargets.concat([button])
  }

  function unregisterClickTarget(button) {
    if (clickTargets.indexOf(button) !== -1) clickTargets = clickTargets.filter(function(other) { return other !== button })
  }

  function windowOf(item) {
    return item && item.QsWindow ? item.QsWindow.window : null
  }

  function targetBelongsToWindow(item, window) {
    return !!item && !!window && windowOf(item) === window
  }

  // Two windows on one screen are one bar's: a window can be made anew
  // while its screen stays.
  function sameBar(one, other) {
    return !!one && !!other && (one === other || BarModel.sameScreen(one.screen, other.screen))
  }

  function slotScreenName(slot) {
    var window = windowOf(slot)
    return window && window.screen ? String(window.screen.name || "") : ""
  }

  // The output Hyprland has focused, where a panel opened by a key goes;
  // "" until it names one, which leaves the choice to BarModel.pickPanelSlot.
  function focusedScreenName() {
    var monitor = Hyprland.focusedMonitor
    return monitor ? String(monitor.name || "") : ""
  }

  // <point> in <window>, on its screen.
  function screenPoint(point, window) {
    if (!window || !window.screen) return { x: point ? point.x : 0, y: point ? point.y : 0 }
    return BarModel.onScreen(point, position, window.screen.width, window.screen.height, window.width, window.height)
  }

  // Every live copy of a widget, one on each screen's bar.
  function moduleWidgets(id) {
    var name = String(id || "")
    return moduleSlots.filter(function(slot) { return name !== "" && !!slot && !!slot.activeItem && slot.moduleName === name })
      .map(function(slot) { return slot.activeItem })
  }

  // ------------------------------------------------------------- panels

  function isPanel(widget) {
    return !!widget && typeof widget.open === "function" && typeof widget.close === "function" && widget.opened !== undefined
  }

  // The panels a section shows on one bar, or on any with no window, in the
  // order of the layout: of each entry, the first copy that is drawn and is
  // a panel. Widgets without a panel, and hidden ones, are passed over.
  function panelsIn(section, window) {
    var panels = []
    var entries = builtLayout[section] || []
    entries.forEach(function(entry) {
      var id = BarModel.entryId(entry)
      var copy = moduleSlots.find(function(slot) {
        if (!slot || slot.section !== section || slot.moduleName !== id) return false
        if (window && !sameBar(windowOf(slot), window)) return false
        var widget = slot.activeItem
        return BarModel.isDrawn(slot) && !!widget && widget.visible === true && isPanel(widget)
      })
      if (copy) panels.push(copy)
    })
    return panels
  }

  // The id of a section's <index>th panel, from one, as the keys count
  // them; "" past the last. Every bar has the same layout, so any can be
  // counted; the panel opens on the focused screen.
  function panelWidgetIdAt(section, index) {
    var slot = panelsIn(String(section || ""), null)[Math.round(Number(index)) - 1]
    return slot ? String(slot.moduleName || "") : ""
  }

  // Opens the panel before (<direction> below 0) or after <owner>'s, on the
  // same bar, from the last round to the first.
  function switchPanelFrom(owner, direction) {
    var from = owner ? moduleSlots.find(function(slot) { return !!slot && slot.activeItem === owner }) : null
    if (!from) return false
    var panels = panelsIn(from.section, windowOf(from))
    var at = panels.indexOf(from)
    if (at === -1 || panels.length < 2) return false
    var to = panels[(at + panels.length + (direction < 0 ? -1 : 1)) % panels.length]
    if (!to.activeItem || to.activeItem === owner) return false
    to.activeItem.open()
    return true
  }

  // The copy of a widget with a panel that a key acts on.
  function panelCopy(id) {
    var name = String(id || "")
    if (name === "") return null
    var copies = moduleSlots.filter(function(slot) {
      return !!slot && slot.moduleName === name && isPanel(slot.activeItem)
    }).map(function(slot) {
      return { slot: slot, screenName: slotScreenName(slot), opened: slot.activeItem.opened === true }
    })
    var slot = BarModel.pickPanelSlot(copies, focusedScreenName())
    return slot ? slot.activeItem : null
  }

  // The shell's summon, hide and toggle, for the panels that are the bar's.
  function summonBarWidget(id) {
    var panel = panelCopy(id)
    if (panel) panel.open()
    return !!panel
  }

  function hideBarWidget(id) {
    var panel = panelCopy(id)
    if (panel) panel.close()
    return !!panel
  }

  function isBarWidgetOpen(id) {
    var panel = panelCopy(id)
    return !!panel && panel.opened === true
  }

  // One popup at a time: the one asked for closes the one open, which then
  // gives up its place, and takes the place.
  property var activePopout: null

  function requestPopout(owner) {
    if (activePopout === owner) return
    var open = activePopout
    if (open && "closeForPopoutSwitch" in open) open.closeForPopoutSwitch()
    else if (open && "close" in open) open.close()
    activePopout = owner
  }

  function releasePopout(owner) {
    if (activePopout === owner) activePopout = null
  }

  // ------------------------------------------------------------ tooltip

  readonly property Tip tip: Tip {}

  function showTooltip(target, text) {
    tip.ask(target, text)
  }

  function hideTooltip(target) {
    tip.withdraw(target)
  }

  // ----------------------------------------------------------- the peek

  // The indicators' hidden icons show while the pointer is on the centre,
  // and stay until it leaves the bar: showing them widens the centre, which
  // can slide a neighbour under a pointer that has not moved, and hiding
  // them then would slide it back and show them once more.
  property bool centerSectionRevealHeld: false
  // Set while the clock's or the weather's panel is open over the centre,
  // which keeps the icons hidden.
  property bool centerHoverRevealSuppressed: false
  property bool centreUnderPointer: false
  // Each screen's bar counts itself in and out, so that a pointer going
  // from one bar to another is counted whichever of the two comes first.
  property int barsUnderPointer: 0

  function setCenterHoverRevealSuppressed(value) {
    centerHoverRevealSuppressed = !!value
  }

  function pointerOnCentre(on) {
    centreUnderPointer = on
    if (on) {
      peekEnd.stop()
      centerSectionRevealHeld = true
    } else {
      peekEnd.restart()
    }
  }

  function pointerOnBar(on) {
    barsUnderPointer = Math.max(0, barsUnderPointer + (on ? 1 : -1))
    if (barsUnderPointer === 0) peekEnd.restart()
  }

  // It only ends the peek: a pointer that left the bar and came back has
  // not been on the centre again.
  Timer {
    id: peekEnd
    interval: 120
    onTriggered: if (!root.centreUnderPointer && root.barsUnderPointer === 0) root.centerSectionRevealHeld = false
  }

  // -------------------------------------------------------------- drags

  readonly property WidgetDrag widgetDrag: WidgetDrag {
    bar: root
  }

  readonly property BarDrag barDrag: BarDrag {
    bar: root
  }

  // ------------------------------------------------------------ screens

  Variants {
    model: Quickshell.screens

    ScreenBar {
      bar: root
    }
  }
}
