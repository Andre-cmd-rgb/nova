import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "AppSearch.js" as AppSearch

// The installed applications, for the menu's Apps list and search: the
// desktop entries in search order, less those this desktop hides and those
// Nova's launcher.hides names; their icons; launching one, with an OSD while
// it is slow to show; and removing one. shell.qml makes one and hands it to
// the menu as shell.appLibrary.
Item {
  id: root

  property string novaPath: Quickshell.env("NOVA_PATH")

  // Desktop IDs to leave out, as { id: true }: those launcher.hides names,
  // and those hidden-entries.sh finds hidden from this desktop.
  property var configuredHiddenEntryIds: ({})
  property var desktopHiddenEntryIds: ({})

  // Icon name to file, from the app and device icons on disk. Qt reads the
  // icon theme once, at startup, and never sees an icon installed after it;
  // this index, made again whenever the apps change, is how a new app's icon
  // still shows. pendingIconIndex is the one being made.
  property var iconIndex: ({})
  property var pendingIconIndex: ({})

  // The launch in progress: its number, and the windows there were when it
  // started, to tell when its window has come.
  property int launchSerial: 0
  property int launchToplevelCount: 0
  property var launchActiveToplevel: null
  // Whether the launch OSD is up. It is shown with no time limit, so only
  // closeLaunchFeedback() takes it down, even after a later launch.
  property bool launchOsdOpen: false
  property string launchOsdMessage: ""

  // Sent whenever the list may have changed: entries came or went, or a
  // list of hidden IDs was read again.
  signal appsChanged()

  function entryName(entry) {
    return AppSearch.entryName(entry)
  }

  function entrySubtext(entry) {
    return AppSearch.entrySubtext(entry)
  }

  function isHiddenEntry(entry) {
    var id = String((entry && entry.id) || "")
    return configuredHiddenEntryIds[id] === true || desktopHiddenEntryIds[id] === true
  }

  // The rows to list for <query>, best first (AppSearch.sortedEntries).
  function sortedEntries(query) {
    var entries = DesktopEntries.applications.values || []
    return AppSearch.sortedEntries(entries, query, function(entry) { return root.isHiddenEntry(entry) })
  }

  // The icon to draw for an entry's Icon value: a URL or path as it is, else
  // the indexed file, else the theme's icon, else a generic program's.
  function iconSource(icon) {
    var name = String(icon || "")
    if (name.length > 0) {
      if (name.indexOf("file://") === 0 || name.indexOf("image://") === 0) return name
      if (name.charAt(0) === "/") return Util.fileUrl(name)
      // The index before the theme: it holds only app and device icons,
      // where the theme can answer an app's name with an action icon
      // ("zoom").
      var indexed = iconIndex[name]
      if (indexed) return Util.fileUrl(indexed)
      var themed = Quickshell.iconPath(name, true)
      if (themed.length > 0) return themed
    }
    return Quickshell.iconPath("application-x-executable", true)
  }

  // Indexes the icons again. The menu calls it when it opens, for icons that
  // landed after the shell started (on a first install, for one).
  function refreshIcons() {
    if (!iconIndexScan.running) iconIndexScan.running = true
  }

  function launch(desktopId, name) {
    var id = String(desktopId || "")
    if (id.length === 0) return
    beginLaunchFeedback(name)
    // uwsm-app runs the app in a scope of its own under app-graphical.slice,
    // not inside the compositor's service. gtk-launch finds the entry, which
    // copes with IDs that have spaces and entries uwsm will not take; it
    // wants the .desktop suffix, or an ID such as org.telegram.desktop is
    // not found.
    Util.execDetached("uwsm-app -- gtk-launch " + Util.shellQuote(id + ".desktop"))
  }

  function remove(desktopId, name) {
    var id = String(desktopId || "")
    if (id.length === 0) return
    var label = String(name || id)
    Util.execDetached([Util.shellQuote("nova-remove-launcher-entry"), Util.shellQuote(id), Util.shellQuote(label)].join(" "))
  }

  // An ID without blanks around it or a .desktop suffix.
  function normalizeDesktopId(id) {
    var value = String(id || "").trim()
    return value.slice(-8) === ".desktop" ? value.slice(0, -8) : value
  }

  // launcher.hides: a desktop ID a line.
  function loadConfiguredHides(rawText) {
    var ids = ({})
    String(rawText || "").split("\n").forEach(function(line) {
      var id = root.normalizeDesktopId(line)
      if (id.length > 0) ids[id] = true
    })
    configuredHiddenEntryIds = ids
    appsChanged()
  }

  // hidden-entries.sh's output: a desktop ID a line.
  function loadDesktopHiddenEntries(rawText) {
    var ids = ({})
    String(rawText || "").split("\n").forEach(function(line) {
      var id = root.normalizeDesktopId(line)
      if (id.length > 0) ids[id] = true
    })
    desktopHiddenEntryIds = ids
    appsChanged()
  }

  // A bash line printing the path of each app and device icon in the icon
  // dirs (~/.icons, ~/.local/share/icons and each XDG data dir's icons),
  // then each icon in /usr/share/pixmaps: every SVG first, then every PNG,
  // since indexIconLine keeps a name's first file. Device icons count
  // because some entries use one, such as Print Settings' "printer".
  function iconIndexScanCommand() {
    return [
      'dirs="$HOME/.icons $HOME/.local/share/icons"',
      'IFS=:',
      'for data in ${XDG_DATA_DIRS:-/usr/local/share:/usr/share}; do dirs="$dirs $data/icons"; done',
      'unset IFS',
      'for ext in svg png; do',
      '  for base in $dirs; do',
      '    [[ -d $base ]] && find "$base" \\( -path "*/apps/*" -o -path "*/devices/*" \\) -name "*.$ext" 2>/dev/null',
      '  done',
      '  find /usr/share/pixmaps -maxdepth 1 -name "*.$ext" 2>/dev/null',
      'done'
    ].join("\n")
  }

  // Adds an icon file to the index being made, under its name without the
  // extension, unless the name has a file already.
  function indexIconLine(path) {
    var file = String(path || "").trim()
    if (file.length === 0) return
    var base = file.slice(file.lastIndexOf("/") + 1)
    var dot = base.lastIndexOf(".")
    var name = dot > 0 ? base.slice(0, dot) : base
    if (name.length > 0 && pendingIconIndex[name] === undefined) pendingIconIndex[name] = file
  }

  // hidden-entries.sh, with this session's desktop names.
  function hiddenEntryScanCommand() {
    var names = [Quickshell.env("XDG_CURRENT_DESKTOP"), Quickshell.env("XDG_SESSION_DESKTOP"), Quickshell.env("DESKTOP_SESSION")]
    var desktops = names.filter(function(name) { return String(name || "").length > 0 }).join(":")
    return Util.shellQuote(novaPath + "/shell/services/hidden-entries.sh") + " " + Util.shellQuote(desktops)
  }

  function toplevelCount() {
    try {
      return ToplevelManager.toplevels.values.length
    } catch (e) {
      return 0
    }
  }

  // The OSD comes up when no window has opened or taken the focus within two
  // seconds of a launch, and goes down when one does, or after fifteen.
  function beginLaunchFeedback(name) {
    launchSerial++
    launchToplevelCount = toplevelCount()
    launchActiveToplevel = ToplevelManager.activeToplevel
    launchOsdMessage = "Launching " + String(name || "application") + "…"
    launchDelay.restart()
    launchTimeout.restart()
  }

  // Ends launch <serial>'s feedback, if it is still the latest launch.
  function closeLaunchFeedback(serial) {
    if (serial !== launchSerial) return
    launchDelay.stop()
    launchTimeout.stop()
    if (!launchOsdOpen) return
    Quickshell.execDetached(["nova-shell", "osd", "close"])
    launchOsdOpen = false
  }

  // Ends the feedback once a window has opened or taken the focus.
  function maybeFinishLaunchFeedback() {
    if (!launchDelay.running && !launchTimeout.running && !launchOsdOpen) return
    var windowCame = toplevelCount() > launchToplevelCount || ToplevelManager.activeToplevel !== launchActiveToplevel
    if (windowCame) closeLaunchFeedback(launchSerial)
  }

  // Both scans run bash without a login shell. A login shell reads the
  // user's profile, and a tool such as mise touches ~/.local/share when it
  // starts, which the desktop entry watcher sees: each scan would set off
  // the next, and keep a core busy.
  Process {
    id: hiddenEntryScan

    property string collected: ""

    command: ["bash", "-c", root.hiddenEntryScanCommand()]
    stdout: SplitParser {
      onRead: function(line) { hiddenEntryScan.collected += line + "\n" }
    }
    onStarted: collected = ""
    onExited: root.loadDesktopHiddenEntries(collected)
  }

  Process {
    id: iconIndexScan
    command: ["bash", "-c", root.iconIndexScanCommand()]
    stdout: SplitParser {
      onRead: function(line) { root.indexIconLine(line) }
    }
    onStarted: root.pendingIconIndex = ({})
    // A new object, so that every iconSource() binding reads it again and
    // new icons show without the list being made again.
    onExited: root.iconIndex = root.pendingIconIndex
  }

  // An install changes many entries at once; this makes one scan of them.
  Timer {
    id: iconIndexDebounce
    interval: 750
    onTriggered: root.refreshIcons()
  }

  FileView {
    path: root.novaPath + "/default/launcher.hides"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadConfiguredHides(text())
    // text() holds what was loaded before the change: it has to be read again.
    onFileChanged: reload()
    onLoadFailed: root.loadConfiguredHides("")
  }

  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() { root.maybeFinishLaunchFeedback() }
  }

  Connections {
    target: ToplevelManager
    function onActiveToplevelChanged() { root.maybeFinishLaunchFeedback() }
  }

  Timer {
    id: launchDelay
    interval: 2000
    onTriggered: {
      if (root.toplevelCount() > root.launchToplevelCount || ToplevelManager.activeToplevel !== root.launchActiveToplevel) return
      root.launchOsdOpen = true
      var osd = { icon: "󱓞", message: root.launchOsdMessage, duration: 0 }
      Quickshell.execDetached(["nova-shell", "osd", "show", JSON.stringify(osd)])
    }
  }

  Timer {
    id: launchTimeout
    interval: 15000
    onTriggered: root.closeLaunchFeedback(root.launchSerial)
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      hiddenEntryScan.running = true
      iconIndexDebounce.restart()
      root.appsChanged()
    }
  }

  Component.onCompleted: {
    hiddenEntryScan.running = true
    iconIndexScan.running = true
  }
}
