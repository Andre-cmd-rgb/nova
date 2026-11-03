import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "AppSearch.js" as AppSearch

// The menu's apps: the desktop entries its Apps list shows, the icon drawn
// for each, and launching or removing one. Two lists of desktop IDs keep an
// entry out: Nova's launcher.hides, and the entries this desktop does not
// list (hidden-entries.sh). shell.qml makes one; the menu reaches it as
// shell.appLibrary.
Item {
  id: library

  // Sent when what the Apps list holds may have changed: entries came or
  // went, or a list of IDs to leave out was read again.
  signal appsChanged()

  readonly property string novaPath: Quickshell.env("NOVA_PATH")

  // The two lists of IDs to leave out, each as { id: true }.
  property var hiddenByNova: ({})
  property var hiddenHere: ({})

  // Icon name to file, for the app and device icons on disk. Qt reads the
  // icon theme once, when the shell starts, and never sees an icon installed
  // later; this, found again whenever the apps change, is how a new app's
  // icon still shows. Each time it is a new object, so that every binding on
  // iconSource() reads it again.
  property var iconFiles: ({})

  function entryName(entry) {
    return AppSearch.entryName(entry)
  }

  function entrySubtext(entry) {
    return AppSearch.entrySubtext(entry)
  }

  // The rows the Apps list shows, in its order (AppSearch.sortedEntries).
  function sortedEntries() {
    return AppSearch.sortedEntries(DesktopEntries.applications.values || [], function(entry) {
      var id = String(entry && entry.id || "")
      return library.hiddenByNova[id] === true || library.hiddenHere[id] === true
    })
  }

  // What to draw for an entry's Icon: a URL as it is, a path as a URL, an
  // icon name as the file found for it, else as the theme has it, and no
  // icon, or one found nowhere, as a generic program's.
  function iconSource(icon) {
    var name = String(icon || "")
    if (!name) return genericIcon
    if (/^(file|image):\/\//.test(name)) return name
    if (name[0] === "/") return Util.fileUrl(name)
    // The files found before the theme: they are only app and device
    // icons, where the theme can answer an app's name with an action's
    // icon ("zoom").
    if (iconFiles[name]) return Util.fileUrl(iconFiles[name])
    return Quickshell.iconPath(name, true) || genericIcon
  }

  readonly property string genericIcon: Quickshell.iconPath("application-x-executable", true)

  // The menu asks for this each time it opens, for icons that came after
  // the shell started (on a first install, for one). A search under way is
  // left to finish.
  function refreshIcons() {
    if (!iconSearch.running) iconSearch.running = true
  }

  // gtk-launch finds the entry, and copes with IDs that have spaces and
  // entries uwsm will not take; it wants the .desktop suffix, or an ID such
  // as org.telegram.desktop is not found. uwsm-app runs it in a scope of
  // its own under app-graphical.slice, not in the compositor's service.
  function launch(appId, label) {
    if (!appId) return
    launchWatch.begin(label)
    Util.execArgv(["uwsm-app", "--", "gtk-launch", appId + ".desktop"])
  }

  function remove(appId, label) {
    if (appId) Util.execArgv(["nova-remove-launcher-entry", String(appId), String(label || appId)])
  }

  // A desktop ID a line, as { id: true }; an ID may end in .desktop.
  function idSet(lines) {
    var ids = ({})
    for (var line of String(lines || "").split("\n")) {
      var id = line.trim().replace(/\.desktop$/, "")
      if (id) ids[id] = true
    }
    return ids
  }

  // ------------------------------------------------------- the searches

  // A bash script run for its output, a line an item. Asked for while it
  // runs, it runs once more when it ends, as the run under way may have read
  // the entries before the change that asked. Bash without a login shell:
  // a login shell reads the user's profile, and a tool such as mise touches
  // ~/.local/share as it starts, which the desktop entry watcher sees, and
  // each run would set off the next.
  component Search: Process {
    id: search

    property var found: []
    property bool askedAgain: false
    signal searched(var lines)

    function request() {
      if (running) askedAgain = true
      else running = true
    }

    stdout: SplitParser {
      onRead: function(line) { search.found.push(line) }
    }
    onStarted: found = []
    onExited: {
      var rerun = askedAgain
      askedAgain = false
      searched(found)
      if (rerun) running = true
    }
  }

  // The entries this desktop leaves out, for this session's desktop names.
  Search {
    id: hiddenSearch
    command: {
      var names = [Quickshell.env("XDG_CURRENT_DESKTOP"), Quickshell.env("XDG_SESSION_DESKTOP"), Quickshell.env("DESKTOP_SESSION")]
      return ["bash", library.novaPath + "/shell/services/hidden-entries.sh", names.filter(Boolean).join(":")]
    }
    onSearched: function(lines) {
      library.hiddenHere = library.idSet(lines.join("\n"))
      library.appsChanged()
    }
  }

  // Every app and device icon file, SVGs before PNGs: under ~/.icons,
  // ~/.local/share/icons and each XDG data dir's icons, then in
  // /usr/share/pixmaps. A name keeps the first file found for it. Device
  // icons count, as some entries name one (Print Settings: "printer").
  Search {
    id: iconSearch
    command: ["bash", "-c", [
      'roots=("$HOME/.icons" "$HOME/.local/share/icons")',
      'IFS=: read -ra shares <<<"${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"',
      'for share in "${shares[@]}"; do roots+=("$share/icons"); done',
      'for type in svg png; do',
      '  for root in "${roots[@]}"; do',
      '    [[ -d $root ]] || continue',
      '    find "$root" \\( -path "*/apps/*" -o -path "*/devices/*" \\) -name "*.$type" 2>/dev/null',
      '  done',
      '  find /usr/share/pixmaps -maxdepth 1 -name "*.$type" 2>/dev/null',
      'done'
    ].join("\n")]
    onSearched: function(lines) {
      var files = ({})
      for (var line of lines) {
        var file = line.trim()
        var base = file.substring(file.lastIndexOf("/") + 1)
        var name = base.lastIndexOf(".") > 0 ? base.substring(0, base.lastIndexOf(".")) : base
        if (name && !(name in files)) files[name] = file
      }
      library.iconFiles = files
    }
  }

  // An install changes many entries at once: one icon search for them all.
  Timer {
    id: iconSearchSoon
    interval: 750
    onTriggered: iconSearch.request()
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      hiddenSearch.request()
      iconSearchSoon.restart()
      library.appsChanged()
    }
  }

  FileView {
    path: library.novaPath + "/default/launcher.hides"
    watchChanges: true
    printErrors: false
    onLoaded: library.readNovaHides(text())
    onLoadFailed: library.readNovaHides("")
    // text() keeps what was read before the change until it is read again.
    onFileChanged: reload()
  }

  function readNovaHides(text) {
    hiddenByNova = idSet(text)
    appsChanged()
  }

  Component.onCompleted: {
    hiddenSearch.running = true
    iconSearch.running = true
  }

  // ------------------------------------------------------- launch feedback

  // An OSD for a launch slow to show: up when no window has opened or taken
  // the focus two seconds after it, and down once one does, or fifteen
  // seconds after it. It is shown with no time limit, so only end() takes
  // it down, also after a later launch.
  QtObject {
    id: launchWatch

    property int windowsBefore: 0
    property var focusBefore: null
    property string osdText: ""
    property bool osdUp: false

    // nova-shell osd <words...>.
    function osd(words) {
      Quickshell.execDetached(["nova-shell", "osd"].concat(words))
    }

    function windowCount() {
      try {
        return ToplevelManager.toplevels.values.length
      } catch (e) {
        return 0
      }
    }

    function windowCame() {
      return windowCount() > windowsBefore || ToplevelManager.activeToplevel !== focusBefore
    }

    function watching() {
      return osdWait.running || giveUp.running || osdUp
    }

    function begin(name) {
      windowsBefore = windowCount()
      focusBefore = ToplevelManager.activeToplevel
      osdText = "Launching " + String(name || "application") + "…"
      osdWait.restart()
      giveUp.restart()
    }

    function end() {
      osdWait.stop()
      giveUp.stop()
      if (!osdUp) return
      osdUp = false
      osd(["close"])
    }

    function check() {
      if (watching() && windowCame()) end()
    }

    property Timer osdWait: Timer {
      interval: 2000
      onTriggered: {
        if (launchWatch.windowCame()) return
        launchWatch.osdUp = true
        launchWatch.osd(["show", JSON.stringify({ icon: "󱓞", message: launchWatch.osdText, duration: 0 })])
      }
    }

    property Timer giveUp: Timer {
      interval: 15000
      onTriggered: launchWatch.end()
    }
  }

  Connections {
    target: ToplevelManager.toplevels
    function onValuesChanged() { launchWatch.check() }
  }

  Connections {
    target: ToplevelManager
    function onActiveToplevelChanged() { launchWatch.check() }
  }
}
