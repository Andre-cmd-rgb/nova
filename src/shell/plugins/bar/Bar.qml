import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import QtQuick
import qs.Commons
import qs.Commons as Commons
import "BarModel.js" as BarModel

// Nova's bar: one on every screen, along the edge its part of shell.json
// names, with the widgets of its layout in three sections. The shell hands
// it that part (config) and the widgets the plugins made; what is changed on
// the bar itself (a widget dragged to another place, the bar dragged to
// another edge or made see-through) is saved through the shell, which
// hands the bar its new config.
//
// The widgets are handed this item as `bar`, and what they use of it is
// listed in README.md. It is made of:
//   ScreenBar   one screen's bar window, its tooltip and its overlays
//   Sections    the three sections in that window, and the bar's gestures
//   WidgetSlot  one widget's place: it loads the widget and drags it
//   SeeThrough  the text colour of a see-through bar, and its shade
//   Tip         the one tooltip
//   WidgetDrag  a widget being dragged; BarDrag, the bar
//   BarIpc      the IPC targets of the widgets
Item {
  id: root

  // ---------------------------------------------------- from the shell

  // { id: { component } }, a widget for each bar-widget plugin that is on.
  property var widgets: ({})
  property var config: ({})
  property var shell: null

  // ----------------------------------------------------------- the look

  property string position: "top"
  readonly property bool vertical: BarModel.onSide(position)
  readonly property int thickness: vertical ? Style.bar.sizeVertical : Style.bar.sizeHorizontal
  // "monospace" until fontconfig resolves it as it draws, so that a new
  // system font (nova-font-set) reaches the bar without a reload.
  property string fontFamily: Style.font.family
  property color foreground: Commons.Color.bar.text
  property color background: Commons.Color.bar.background
  property color urgent: Commons.Color.bar.active
  // The text colour as drawn: the theme's, or the one picked to read on the
  // background while the bar is see-through. Then the background behind the
  // bar is shaded as much as that text needs (ScreenBar draws it).
  property color textColour: seeThrough.shown ? seeThrough.colour : foreground
  readonly property bool textFades: seeThrough.fades
  readonly property bool transparent: seeThrough.shown
  property color shadeColour: seeThrough.shade
  property real shadeStrength: seeThrough.shown ? seeThrough.strength : 0
  // Moved past its screen's edge by nova-toggle-bar.
  property bool tucked: false

  component Fade: ColorAnimation { duration: 420; easing.type: Easing.InOutCubic }

  Behavior on textColour {
    enabled: root.textFades
    Fade {}
  }
  Behavior on shadeColour {
    enabled: root.textFades
    Fade {}
  }
  Behavior on shadeStrength {
    enabled: root.textFades
    NumberAnimation { duration: 420; easing.type: Easing.InOutCubic }
  }
  Behavior on background { Fade {} }
  Behavior on urgent { Fade {} }

  // The background is measured where the first screen's bar is: every
  // screen shows the same one, cut to its own shape.
  readonly property var firstScreen: Quickshell.screens.length > 0 ? Quickshell.screens[0] : null

  readonly property SeeThrough seeThrough: SeeThrough {
    edge: root.position
    thickness: root.thickness
    screenWidth: root.firstScreen ? root.firstScreen.width : 0
    screenHeight: root.firstScreen ? root.firstScreen.height : 0
    text: root.foreground
    backdrop: Commons.Color.background
  }

  // --------------------------------------------------------- the layout

  // The sections as built, each a list of entries: replaced when the
  // widgets have to be built again, changed in place when only their
  // settings change. The centre's anchor is the id of the widget it hangs
  // off, or "" for none.
  property var layout: ({ left: [], center: [], right: [] })
  property string anchor: ""

  onConfigChanged: settle()

  // shell.qml hands the bar its shell. Without one the bar still draws, but
  // a change made on it is not saved, which the checks on `saves` below
  // would hide; it is said once, where the smoke tests see it.
  Component.onCompleted: {
    if (!shell) console.warn("Bar: started without its shell; layout changes cannot be saved")
    settle()
  }

  function settle() {
    const part = Util.isPlainObject(config) ? config : {}
    position = BarModel.edge(part.position)
    seeThrough.want(part.transparent === true)

    const next = Util.normalizeLayout(part.layout)
    for (const name of BarModel.SECTIONS) next[name] = BarModel.trayInward(next[name], name)
    anchor = BarModel.centerAnchor(part.centerAnchor, next.center)

    // A Repeater cannot tell two lists of entries apart, so a new layout
    // builds every widget on every screen again. A change of settings alone
    // (the battery's percentage, the clock's format) is handed to the
    // widgets in place instead.
    const changes = BarModel.settingsOnlyChanges(layout, next)
    if (changes === null) {
      layout = next
      return
    }
    for (const change of changes) {
      layout[change.region][change.index] = change.entry
      const id = BarModel.entryId(change.entry)
      for (const slot of slots) {
        if (slot.section !== change.region || slot.widgetId !== id || !slot.widget) continue
        if ("settings" in slot.widget) slot.widget.settings = BarModel.entrySettings(change.entry)
      }
    }
  }

  // A change to the bar as a whole is saved into shell.json through the
  // shell, which hands it back; with no shell it is only shown.
  readonly property bool saves: !!shell && typeof shell.mutateShellConfig === "function"

  // <key> of the bar's part set to <value>, or with nothing to save to,
  // <show>n here alone.
  function keep(key, value, show) {
    if (!saves) {
      show()
      return
    }
    shell.mutateShellConfig(config => {
      BarModel.barOf(config)[key] = value
    })
  }

  function putOnEdge(edge) {
    const to = BarModel.edge(edge)
    keep("position", to, () => position = to)
  }

  function toggleSeeThrough() {
    const on = !seeThrough.wanted
    keep("transparent", on, () => seeThrough.want(on))
  }

  // Runs <command> with bash, and does not wait for it.
  function run(command) {
    if (command) Util.execDetached(command)
  }

  // ------------------------------------------------------------- tucked

  // nova-toggle-bar tucks the bar away with a flag file, bar-off, read by
  // its being there. A tucked bar is not unmapped but moved past its
  // screen's edge (ScreenBar): a mapped surface keeps its glyphs and
  // textures, so it is back with a change of margin (about 20 ms) rather
  // than as a new surface (about 150 ms).
  readonly property string togglesDir: Commons.Color.stateHome + "/nova/toggles"

  // Asked while it looks, it looks once more after: the flag may have
  // flipped back after it looked (the bar off and on again in a moment).
  Process {
    id: flagLook

    property bool again: false

    function ask() {
      again = running
      if (!running) running = true
    }

    command: ["test", "-f", root.togglesDir + "/bar-off"]
    running: true
    onExited: code => {
      root.tucked = code === 0
      if (again) {
        again = false
        running = true
      }
    }
  }

  // A file that is not there cannot be watched, so its folder is.
  FileView {
    path: root.togglesDir
    watchChanges: true
    printErrors: false
    onFileChanged: flagLook.ask()
  }

  // That watch can stop for good after quick changes, which would leave the
  // bar tucked away until the shell restarts, so nova-toggle-bar asks as
  // well.
  IpcHandler {
    target: "nova.bar"

    function syncHidden(): void {
      flagLook.ask()
    }
  }

  BarIpc {
    bar: root
  }

  // ---------------------------------------------------- slots and buttons

  // The slot of every widget on every screen's bar, in the order they came;
  // and every button that takes a click (BarButton lists itself), for a
  // click on the slot or on the bar under an open panel.
  property var slots: []
  property var buttons: []

  function listSlot(slot, on) {
    slots = BarModel.listed(slots, slot, on)
  }

  function listButton(button, on) {
    buttons = BarModel.listed(buttons, button, on)
  }

  function windowOf(item) {
    return item && item.QsWindow ? item.QsWindow.window : null
  }

  function inWindow(item, window) {
    return !!item && !!window && windowOf(item) === window
  }

  // Two windows on one screen are one bar's: a window can be made anew
  // while its screen stays.
  function sameBar(one, other) {
    return !!one && !!other && (one === other || BarModel.sameScreen(one.screen, other.screen))
  }

  // The name of the screen <slot>'s bar is on.
  function screenOf(slot) {
    const screen = windowOf(slot)?.screen
    return screen ? String(screen.name || "") : ""
  }

  // The output Hyprland has focused, where a panel opened by a key goes;
  // "" until it names one, which leaves the choice to BarModel.reached.
  readonly property string focusedOutput: Hyprland.focusedMonitor?.name ?? ""

  // <point> in <window>, on its screen.
  function screenPoint(point, window) {
    if (!window || !window.screen) return { x: point ? point.x : 0, y: point ? point.y : 0 }
    return BarModel.onScreen(point, position, window.screen.width, window.screen.height, window.width, window.height)
  }

  // The slots of the live copies of widget <id>, one on each screen's bar.
  function slotsOf(id) {
    return id ? slots.filter(slot => slot.widgetId === id && !!slot.widget) : []
  }

  // Every live copy of a widget.
  function copiesOf(id) {
    return slotsOf(String(id || "")).map(slot => slot.widget)
  }

  // ------------------------------------------------------------- panels

  function isPanel(widget) {
    return !!widget && typeof widget.open === "function" && typeof widget.close === "function" && widget.opened !== undefined
  }

  // The panels a section shows on one bar, or on any with no window, in the
  // order of the layout: of each entry, the first copy that is drawn and is
  // a panel. Widgets without a panel, and hidden ones, are passed over.
  function panelsIn(section, window) {
    const shows = slot => slot.section === section && (!window || sameBar(windowOf(slot), window))
      && BarModel.isDrawn(slot) && slot.widget.visible === true && isPanel(slot.widget)
    return (layout[section] || []).map(entry => slotsOf(BarModel.entryId(entry)).find(shows))
      .filter(slot => !!slot)
  }

  // The id of a section's <n>th panel, from one, as the keys count them; ""
  // past the last. Every bar has the same layout, so any can be counted; the
  // panel opens on the focused screen.
  function panelAt(section, n) {
    const slot = panelsIn(String(section || ""), null)[Math.round(Number(n)) - 1]
    return slot ? slot.widgetId : ""
  }

  // Opens the panel before (<step> below 0) or after <owner>'s, on the same
  // bar, from the last round to the first. Whether one opened.
  function nextPanel(owner, step) {
    const from = owner ? slots.find(slot => slot.widget === owner) : null
    if (!from) return false
    const panels = panelsIn(from.section, windowOf(from))
    const at = panels.indexOf(from)
    if (at === -1 || panels.length < 2) return false
    const to = panels[(at + panels.length + (step < 0 ? -1 : 1)) % panels.length].widget
    if (!to || to === owner) return false
    to.open()
    return true
  }

  // The copy of a widget with a panel that a key acts on.
  function panelOf(id) {
    const copies = slotsOf(String(id || "")).filter(slot => isPanel(slot.widget))
      .map(slot => ({ slot: slot, screen: screenOf(slot), open: slot.widget.opened === true }))
    return BarModel.reached(copies, focusedOutput)?.widget ?? null
  }

  // The shell's summon, hide and toggle, for the panels that are the bar's.
  function openPanel(id) {
    const panel = panelOf(id)
    panel?.open()
    return !!panel
  }

  function closePanel(id) {
    const panel = panelOf(id)
    panel?.close()
    return !!panel
  }

  function panelOpen(id) {
    return panelOf(id)?.opened === true
  }

  // One card or panel open at a time, <popup>: one that opens takes the
  // place, and the one there closes (handing its place over when it can, so
  // that it goes at once); one that closes gives the place back.
  property var popup: null

  function claimPopup(key, open) {
    if (!open) {
      if (popup === key) popup = null
      return
    }
    const before = popup
    popup = key
    if (!before || before === key) return
    if ("handOver" in before) before.handOver()
    else if ("close" in before) before.close()
  }

  // ------------------------------------------------------------ tooltip

  // Asked for with tip.ask(widget, text), taken back with tip.withdraw().
  readonly property Tip tip: Tip {}

  // ----------------------------------------------------------- the peek

  // The indicators' hidden icons show while the pointer is on the centre,
  // and stay until it leaves the bar: showing them widens the centre, which
  // can slide a neighbour under a pointer that has not moved, and hiding
  // them then would slide it back and show them once more. A card open over
  // the centre (the clock's, the weather's: their widgets say so with
  // `hidesPeek`) keeps them hidden.
  readonly property bool peek: peekHeld && !(popup && popup.hidesPeek === true)
  property bool peekHeld: false
  property bool centreUnderPointer: false
  // Each screen's bar counts itself in and out, so that a pointer going
  // from one bar to another is counted whichever of the two comes first.
  property int barsUnderPointer: 0

  function pointerOnCentre(on) {
    centreUnderPointer = on
    if (on) {
      peekEnd.stop()
      peekHeld = true
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
    onTriggered: if (!root.centreUnderPointer && root.barsUnderPointer === 0) root.peekHeld = false
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
