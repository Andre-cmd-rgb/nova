// platform: wayland
import QtQuick
import Quickshell
import Quickshell.Io
import "services"

// The menu's app library: the entries this desktop hides and those that ask
// for the discrete GPU, from one read of them, and an app's icon found
// though its package writes the icon after the entry, with nothing asked of
// the library (the menu no longer looks for icons as it opens). The apps are
// in the scratch home's ~/.local/share, which Quickshell's DesktopEntries
// reads and watches.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  readonly property string apps: home + "/.local/share/applications"
  readonly property string iconDir: home + "/.local/share/icons/hicolor/scalable/apps"
  property var library: null
  property int iconSearches: 0
  property Item stage: Item {}

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  // <then> once <ready> holds, looked at every 100 ms; <what> fails after
  // <seconds>.
  function when(ready, seconds, what, then) {
    waiter.ready = ready
    waiter.then = then
    waiter.what = what
    waiter.left = seconds * 10
    waiter.restart()
  }

  Timer {
    id: waiter
    property var ready: null
    property var then: null
    property string what: ""
    property int left: 0
    interval: 100
    repeat: true
    onTriggered: {
      if (ready()) {
        stop()
        then()
      } else if (--left <= 0) {
        stop()
        test.check(false, what)
        test.finish()
      }
    }
  }

  Process {
    id: write
    property var then: null
    onExited: if (then) then()
  }

  function shell(script, then) {
    write.then = then
    write.command = ["bash", "-c", script, "bash", apps, iconDir]
    write.running = true
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(begin)

  function begin() {
    shell('mkdir -p "$1" "$2"\n'
      + 'printf "[Desktop Entry]\\nType=Application\\nName=Shown\\nExec=true\\nIcon=nova-shown\\n" >"$1/nova-shown.desktop"\n'
      + 'printf "[Desktop Entry]\\nType=Application\\nName=Hidden\\nExec=true\\nNoDisplay=true\\n" >"$1/nova-hidden.desktop"\n'
      + 'printf "[Desktop Entry]\\nType=Application\\nName=Game\\nExec=true\\nPrefersNonDefaultGPU=true\\n" >"$1/nova-game.desktop"\n'
      + 'printf "<svg/>" >"$2/nova-shown.svg"', start)
  }

  Component {
    id: made
    AppLibrary {}
  }

  function start() {
    library = made.createObject(stage, { novaPath: Quickshell.env("TEST_PLUGINS") + "/../..", systemIcons: home + "/.local/share/icons" })
    library.iconFilesChanged.connect(() => iconSearches++)
    when(() => library.hiddenHere["nova-hidden"] === true && library.prefersDiscrete["nova-game"] === true
      && library.iconFiles["nova-shown"] !== undefined, 10, "the library reads the entries and the icons", read)
  }

  function read() {
    check(library.hiddenHere["nova-shown"] !== true && library.hiddenHere["nova-game"] !== true && library.prefersDiscrete["nova-hidden"] !== true,
      "one read of the entries gives both lists, each with its own entries")
    check(String(library.iconSource("nova-shown")).endsWith("/hicolor/scalable/apps/nova-shown.svg"), "an entry's icon is the file found for it")
    // An install: the entry, and its icon two seconds later, as a package
    // with much between its applications and its icons writes them.
    const before = iconSearches
    shell('printf "[Desktop Entry]\\nType=Application\\nName=Late\\nExec=true\\nIcon=nova-late\\n" >"$1/nova-late.desktop"\n'
      + 'sleep 2; printf "<svg/>" >"$2/nova-late.svg"', () => {
      when(() => library.iconFiles["nova-late"] !== undefined, 15,
        "an icon written two seconds after its entry is found, with nothing asked of the library", () => {
          check(String(library.iconSource("nova-late")).endsWith("/nova-late.svg"), "an icon written after its entry is drawn")
          check(iconSearches - before <= 3, "an install is a few icon searches, not one a change (" + (iconSearches - before) + ")")
          themeAlone()
        })
    })
  }

  // An icon theme installed on its own: a folder beside the others, and no
  // entry changes (the folder watched is this test's own, for /usr/share/icons).
  function themeAlone() {
    shell('mkdir -p "$2/../../../NovaTheme/apps" && printf "<svg/>" >"$2/../../../NovaTheme/apps/nova-themed.svg"', () => {
      when(() => library.iconFiles["nova-themed"] !== undefined, 10,
        "an icon theme installed alone is found, with no entry changed", () => {
          check(true, "an icon theme installed alone is found, with no entry changed")
          finish()
        })
    })
  }
}
