// stub: bin/nova-apps-catalog apps
// stub: bin/nova-apps-installed apps
// stub: bin/nova-apps-refresh apps
// stub: bin/nova-apps-run apps
// stub: bin/nova-apps-shots apps
// stub: bin/nova-apps-size apps
// stub: bin/uwsm-app record
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/store" as Store

// The App Center's window with its helpers stubbed (stubs/apps): the front
// page, a search, an app's page and its choice of source, an install from
// Flathub followed from its status to Open, Open and Remove, the Installed
// page, and an appstream:// link.
ShellRoot {
  id: test

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  Store.Panel { id: store }

  function window() {
    for (var i = 0; i < store.data.length; i++)
      if (store.data[i] && store.data[i].contentItem !== undefined) return store.data[i]
    return null
  }

  // Every item in the window that <ok> says is one, shown or not.
  function all(ok) {
    var found = []
    function walk(item) {
      if (!item) return
      if (ok(item)) found.push(item)
      for (var i = 0; i < item.children.length; i++) walk(item.children[i])
    }
    walk(window().contentItem)
    return found
  }

  // The shown button with these words, or null.
  function button(text) {
    var list = all(function (i) { return i.text === text && i.clicked !== undefined && i.iconText !== undefined && shown(i) })
    return list.length > 0 ? list[0] : null
  }

  // Whether the window shows a line with exactly these words.
  function note(text) {
    return all(function (i) { return i.text === text && i.clicked === undefined && shown(i) }).length > 0
  }

  function shown(item) {
    for (var i = item; i; i = i.parent)
      if (!i.visible) return false
    return true
  }

  function tiles() {
    return all(function (i) { return i.st !== undefined && i.app !== undefined && i.store !== undefined && shown(i) })
  }

  function page() {
    var list = all(function (i) { return i.picked !== undefined && i.archSize !== undefined })
    return list.length > 0 ? list[0] : null
  }

  FileView {
    id: calls
    path: Quickshell.env("HOME") + "/stub-calls"
    printErrors: false
    blockLoading: true
  }

  function called(line) {
    calls.reload()
    return String(calls.text()).split("\n").indexOf(line) >= 0
  }

  // Each step returns false to be asked again a moment later, up to five
  // seconds: the helpers answer as processes do, a little later.
  property var steps: []
  property int tries: 0

  Timer {
    id: next
    interval: 50
    onTriggered: {
      if (test.steps.length === 0) {
        console.log("DONE")
        Qt.quit()
        return
      }
      if (test.steps[0]() === false && test.tries < 100) {
        test.tries++
      } else {
        if (test.tries >= 100) check(false, "a step that never came true (" + test.steps.length + " left)")
        test.tries = 0
        test.steps.shift()
      }
      next.restart()
    }
  }

  Component.onCompleted: {
    store.open("{}")
    steps = [
      function () { return store.catalog !== null && store.installed !== null },
      function () {
        check(window().visible && window().title === "App Center", "the window opens")
        check(store.page === "discover", "on its front page")
        var names = tiles().map(function (t) { return t.app.name })
        check(names.join(",") === "Google Chrome,Steam,GIMP,Inkscape,Steam,Google Chrome,Firefox", "the front page: Popular first, then the chosen few of each kind, in order")
        var heads = all(function (i) { return i.text === "Popular" && shown(i) })
        check(heads.length === 1 && button("See All") !== null && all(function (i) { return i.text === "See All" && i.clicked !== undefined && shown(i) }).length === 3, "Popular has no See All; each of the three kinds shown has")
        var firefox = tiles().filter(function (t) { return t.app.id === "org.mozilla.firefox" })[0]
        check(firefox.st.action === "open", "one installed is offered to open")
      },
      function () { store.choose("create") },
      function () {
        check(tiles().map(function (t) { return t.app.name }).join(",") === "GIMP,Inkscape,Krita", "a kind: its chosen apps, then the rest")
        store.query = "paint"
      },
      function () { return store.searched === "paint" },
      function () {
        var names = tiles().map(function (t) { return t.app.name })
        check(names[0] === "GIMP" && names.indexOf("Krita") > 0 && names.indexOf("Steam") < 0, "a search: the best known first")
        store.show(store.catalog.byId["org.gimp.GIMP"])
      },
      function () { return page() !== null },
      function () {
        var p = page()
        check(p.app.id === "org.gimp.GIMP" && store.backLabel === "Search", "an app's page, with the way back to the search")
        check(p.choices.length === 2 && p.source.kind === "arch", "two places it comes from, Arch's first")
        check(button("Get") !== null && button("Open") === null, "Get, and no Open")
        var group = all(function (i) { return i.options !== undefined && i.value === "arch" && shown(i) })
        check(group.length === 1, "the choice of where from")
        group[0].changed("flathub")
      },
      function () {
        var p = page()
        check(p.source.kind === "flathub" && p.facts.some(function (f) { return f.label === "Size" && f.value === "1.2 GB" }), "from Flathub, with its runtime in its size")
        button("Get").clicked()
      },
      function () { return called("nova-apps-run install org.gimp.GIMP --from flathub") },
      function () { return page() && page().st.action === "busy" && page().st.text === "Downloading 40%" },
      function () { check(true, "the install's progress, from its status") },
      function () { return page().st.action === "open" },
      function () {
        check(button("Open") !== null && button("Remove…") !== null, "installed: Open and Remove")
        button("Open").clicked()
      },
      function () { return called("uwsm-app -- flatpak run org.gimp.GIMP") },
      function () {
        check(true, "Open starts it as Flathub's")
        button("Remove…").clicked()
      },
      function () {
        check(button("Remove Now") !== null && button("Cancel") !== null, "Remove asks again")
        check(note("Its data goes with it."), "a Flathub app: its data goes with it")
        button("Remove Now").clicked()
      },
      function () { return called("nova-apps-run remove org.gimp.GIMP") },
      function () {
        check(true, "and removes it")
        store.back()
      },
      function () {
        check(page() === null && store.searched === "paint", "Back: the search again")
        store.choose("installed")
      },
      function () {
        var rows = all(function (i) { return i.confirming !== undefined && i.app !== undefined && i.st !== undefined && shown(i) })
        check(rows.map(function (r) { return r.app.name }).join(",") === "Firefox,Foot,GIMP", "Installed: by name")
        var firefoxRow = rows.filter(function (r) { return r.app.id === "org.mozilla.firefox" })[0]
        firefoxRow.confirming = true
        check(note("Your files and settings for it stay."), "an Arch app: its files and settings stay")
        firefoxRow.confirming = false
        var foot = rows.filter(function (r) { return r.app.id === "foot" })[0]
        check(foot.st.kept === "Part of Nova" && !foot.st.removable, "part of Nova: no Remove")
        button("Open").clicked()
      },
      function () { return called("uwsm-app -- firefox.desktop") },
      function () {
        check(true, "Firefox from Arch opens by the entry Arch's package has")
        store.open(JSON.stringify({ app: "appstream://org.mozilla.firefox" }))
      },
      function () { return page() !== null },
      function () {
        check(page().app.id === "org.mozilla.firefox", "an appstream:// link opens its app's page")
        store.open(JSON.stringify({ app: "nothing-called-this" }))
      },
      function () {
        check(page() === null && store.searched === "nothing-called-this", "an app not known is looked for")
      }
    ]
    next.start()
  }
}
