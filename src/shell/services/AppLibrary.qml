import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "AppSearch.js" as AppSearch

// The menu's apps: the desktop entries its Apps list shows, the icon drawn
// for each, and launching or removing one. Two lists of desktop IDs keep an
// entry out: Nova's launcher.hides, and the entries this desktop does not
// list (hidden-entries.sh). The lists and the icons are found again when
// the entries change (an install or a removal), never as the menu opens.
// shell.qml makes one; the menu reaches it as shell.appLibrary.
Item {
  id: library

  // Sent when what the Apps list holds may have changed: entries came or
  // went, or a list of IDs to leave out was read again.
  signal appsChanged()

  // Where Nova is installed (a test sets its own).
  property string novaPath: Quickshell.env("NOVA_PATH")

  // The two lists of IDs to leave out, each as { id: true }.
  property var hiddenByNova: ({})
  property var hiddenHere: ({})
  // The IDs whose entries ask for the discrete GPU, as { id: true }.
  property var prefersDiscrete: ({})

  // Icon name to file, for the app and device icons on disk. Qt reads the
  // icon theme once, when the shell starts, and never sees an icon installed
  // later; this, found again whenever the apps change, is how a new app's
  // icon still shows. Each time it is a new object, so that every binding on
  // iconSource() reads it again. It is every icon theme's, whichever is set,
  // so a change of theme changes nothing here.
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

  // Straight to nova-launch, which finds the entry (AppSearch.launchWords): a
  // login shell and gtk-launch in between cost 12 ms and 30 ms of each
  // launch, and the session's environment is the shell's already, as it is
  // for the apps Hyprland's keys start.
  function launch(appId, label) {
    var words = AppSearch.launchWords(appId, prefersDiscrete[String(appId || "").replace(/\.desktop$/, "")] === true)
    if (words.length === 0) return
    launchWatch.begin(label)
    Quickshell.execDetached(words)
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

  // The entries this desktop leaves out, for this session's desktop names,
  // and those that ask for the discrete GPU (PrefersNonDefaultGPU), from one
  // read of the entries.
  Search {
    id: entrySearch
    command: {
      var names = [Quickshell.env("XDG_CURRENT_DESKTOP"), Quickshell.env("XDG_SESSION_DESKTOP"), Quickshell.env("DESKTOP_SESSION")]
      return ["bash", library.novaPath + "/shell/services/hidden-entries.sh", names.filter(Boolean).join(":")]
    }
    onSearched: function(lines) {
      var lists = { hidden: [], discrete: [] }
      for (var line of lines) {
        var space = line.indexOf(" ")
        var list = lists[line.substring(0, space)]
        if (list) list.push(line.substring(space + 1))
      }
      library.hiddenHere = library.idSet(lists.hidden.join("\n"))
      library.prefersDiscrete = library.idSet(lists.discrete.join("\n"))
      library.appsChanged()
    }
  }

  // Every app and device icon file, SVGs before PNGs: under ~/.icons,
  // ~/.local/share/icons and each XDG data dir's icons (each folder once),
  // then in /usr/share/pixmaps, but not below it. A name keeps the first
  // file found for it. Device icons count, as some entries name one
  // ("printer"). One find for them all; the SVGs are taken first here.
  Search {
    id: iconSearch
    command: ["bash", "-c", [
      'declare -A seen; icons=() roots=()',
      'IFS=: read -ra shares <<<"${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"',
      'for share in "${shares[@]}"; do icons+=("${share%/}/icons"); done',
      'for root in "$HOME/.icons" "$HOME/.local/share/icons" "${icons[@]}" /usr/share/pixmaps; do',
      '  [[ -d $root && -z ${seen[$root]:-} ]] || continue',
      '  seen[$root]=1; roots+=("$root")',
      'done',
      '((${#roots[@]})) || exit 0',
      'exec find "${roots[@]}" -path "/usr/share/pixmaps/*" -type d -prune -o \\( -path "*/apps/*" -o -path "*/devices/*" -o -path "/usr/share/pixmaps/*" \\) \\( -name "*.svg" -o -name "*.png" \\) -print 2>/dev/null'
    ].join("\n")]
    onSearched: function(lines) {
      var files = ({})
      for (var type of [".svg", ".png"]) {
        for (var line of lines) {
          var file = line.trim()
          if (!file.endsWith(type)) continue
          var base = file.substring(file.lastIndexOf("/") + 1)
          var name = base.substring(0, base.length - type.length)
          if (name && !(name in files)) files[name] = file
        }
      }
      library.iconFiles = files
    }
  }

  // An install changes many entries at once: one icon search for them all,
  // and another a while after the last change, for the icons a package
  // writes after its entry (applications comes before icons in a package),
  // or a slow one between the two.
  Timer {
    id: iconSearchSoon
    interval: 750
    onTriggered: iconSearch.request()
  }

  Timer {
    id: iconSearchLater
    interval: 10000
    onTriggered: iconSearch.request()
  }

  // Each search waits for the entries: there is nothing to leave out or
  // draw before there is one, and the entries' first reading, as the shell
  // starts, would have each run a second time. The first icon search runs
  // with the entries' first reading; each change after it is an install or
  // a removal.
  property bool searched: false

  function search() {
    entrySearch.request()
    if (!searched) {
      searched = true
      iconSearch.request()
    } else {
      iconSearchSoon.restart()
      iconSearchLater.restart()
    }
  }

  // Quickshell says so once for each entry it adds, many in one turn as it
  // reads them: the searches and the menu's list are made once for them all,
  // the turn after.
  function entriesChanged() {
    search()
    appsChanged()
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() {
      Qt.callLater(library.entriesChanged)
    }
  }

  WatchedFile {
    path: library.novaPath + "/default/launcher.hides"
    onLoaded: library.readNovaHides(text())
    onLoadFailed: library.readNovaHides("")
  }

  function readNovaHides(text) {
    hiddenByNova = idSet(text)
    appsChanged()
  }

  Component.onCompleted: {
    if ((DesktopEntries.applications.values || []).length > 0) search()
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
