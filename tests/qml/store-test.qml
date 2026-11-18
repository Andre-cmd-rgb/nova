import QtQuick
import Quickshell
import "plugins/store/StoreModel.js" as Model

// The App Center in words and lists, apart from its window: the front page,
// a category, the search, what is installed and from where, what an app's
// page says and offers, and the jobs it follows.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function names(apps) {
    return apps.map(function (a) { return a.name }).join(",")
  }

  function run() {
    var arch = { kind: "arch", package: "gimp", repo: "extra", version: "3.0.4-1", desktop: "gimp.desktop" }
    var flathub = { kind: "flathub", app: "org.gimp.GIMP", ref: "app/org.gimp.GIMP/x86_64/stable", version: "3.0.4", download: 100000000, installed: 300000000, runtime: "org.gnome.Platform/x86_64/48", verified: true }
    var text = JSON.stringify({
      format: 1,
      runtimes: { "org.gnome.Platform/x86_64/48": { download: 300000000, installed: 900000000 } },
      apps: [
        { id: "org.gimp.GIMP", name: "GIMP", summary: "Create images and edit photographs", category: "create", keywords: "photoshop paint", desktop: "org.gimp.GIMP.desktop", developer: "The GIMP team", license: "GPL-3.0+ AND LGPL-3.0+", sources: [arch, flathub], featured: "create", position: 1, popular: 1, rank: 1085 },
        { id: "org.inkscape.Inkscape", name: "Inkscape", summary: "Vector graphics editor", category: "create", sources: [{ kind: "flathub", app: "org.inkscape.Inkscape" }], featured: "create", position: 0, rank: 1020 },
        { id: "org.kde.krita", name: "Krita", summary: "Digital painting", category: "create", keywords: "paint", sources: [{ kind: "flathub", app: "org.kde.krita" }], rank: 40 },
        { id: "paint", name: "Paint", summary: "A program", category: "create", sources: [{ kind: "arch", package: "paint" }], rank: 25 },
        { id: "com.google.Chrome", name: "Google Chrome", category: "internet", desktop: "google-chrome.desktop", sources: [{ kind: "nova", package: "google-chrome", maker: "Google" }], featured: "internet", position: 0, popular: 2, rank: 1060 },
        { id: "foot", name: "Foot", category: "utilities", sources: [{ kind: "arch", package: "foot" }], rank: 25 },
        { id: "libfoo", name: "Foo Viewer", category: "utilities", sources: [{ kind: "arch", package: "libfoo", desktop: "foo-viewer" }], rank: 25 }
      ]
    })
    var catalog = Model.read(text)
    var apps = catalog.apps
    check(Model.read("{") === null && Model.read('{"apps":3}') === null, "a file that is not a catalog")
    check(catalog.byId["org.kde.krita"].name === "Krita", "read with an index by ID")

    // ---- lists ----
    check(Model.pages[0].id === "discover" && Model.pages[Model.pages.length - 1].id === "installed", "the front page first, Installed last")
    check(Model.categories().length === 8 && Model.categories()[0].id === "create", "eight kinds on the front page")
    check(names(Model.featured(apps, "create")) === "Inkscape,GIMP", "a kind's chosen few, in their order")
    check(names(Model.featured(apps, "popular")) === "GIMP,Google Chrome", "Popular: the best-known of every kind, in their order, apart from their kinds")
    check(Model.shelves()[0].id === "popular" && Model.shelves().length === 9 && Model.pages.every(function (p) { return p.id !== "popular" }), "the front page's rows: Popular, then the eight kinds; Popular is no page")
    check(names(Model.inCategory(apps, "internet")) === "Google Chrome", "Popular does not change a kind's page")
    check(names(Model.inCategory(apps, "create")) === "Inkscape,GIMP,Krita,Paint", "a kind's page: the chosen few, then the rest in the store's order")
    check(names(Model.search(apps, "paint")) === "GIMP,Paint,Krita", "a search: a known app with the word for a keyword before an unknown one named it")
    check(names(Model.search(apps, "image edit")) === "GIMP" && Model.search(apps, "image vector").length === 0, "every word must match")
    check(Model.search(apps, "  ").length === 0 && Model.search(apps, "a", 2).length === 2, "no words find nothing; a limit")

    // ---- what is installed ----
    var none = { flatpak: [], runtimes: [], pacman: {}, explicit: [], nova: [] }
    var fromArch = { flatpak: [], runtimes: [], pacman: { gimp: "3.0.4-1", foot: "1.24.0-1", libfoo: "1-1" }, explicit: ["gimp"], nova: ["foot"] }
    var fromFlathub = { flatpak: [{ app: "org.gimp.GIMP", installation: "user", version: "3.0.4" }], runtimes: ["org.gnome.Platform/x86_64/48"], pacman: {}, explicit: [], nova: [] }
    var gimp = catalog.byId["org.gimp.GIMP"]
    check(Model.installedFrom(gimp, none) === null, "not installed")
    check(JSON.stringify(Model.installedFrom(gimp, fromArch)) === '{"kind":"arch","scope":"system","version":"3.0.4-1","package":"gimp"}', "installed from Arch")
    check(JSON.stringify(Model.installedFrom(gimp, fromFlathub)) === '{"kind":"flathub","scope":"user","version":"3.0.4","app":"org.gimp.GIMP"}', "installed from Flathub")
    check(names(Model.installedApps(apps, fromArch)) === "Foo Viewer,Foot,GIMP", "the installed apps, by name")
    check(Model.kept(catalog.byId.foot, fromArch) === "Part of Nova" && Model.kept(catalog.byId.libfoo, fromArch) === "Installed with another app" && Model.kept(gimp, fromArch) === "", "why one has no Remove")
    check(Model.removeNote(gimp, fromFlathub) === "Its data goes with it.", "removing a Flathub app: its data goes with it")
    check(Model.removeNote(gimp, fromArch) === "Your files and settings for it stay." && Model.removeNote(catalog.byId["com.google.Chrome"], { flatpak: [], pacman: { "google-chrome": "1" }, explicit: [], nova: [] }) === "Your files and settings for it stay.", "an app of Arch's or Nova's: its files and settings stay")
    check(Model.removeNote(gimp, none) === "" && Model.status(gimp, fromFlathub, {}, false).removeNote === "Its data goes with it.", "the page's status carries it")
    check(Model.installedText(gimp, fromArch) === "Arch Linux · 3.0.4-1" && Model.installedText(catalog.byId.foot, fromArch) === "Part of Nova", "the Installed page's line")

    // ---- an app's page ----
    check(Model.offered(gimp, "").kind === "arch" && Model.offered(gimp, "flathub").kind === "flathub" && Model.offered(gimp, "nova").kind === "arch", "the source an install takes")
    check(JSON.stringify(Model.choices(gimp)) === '[{"value":"arch","label":"Arch Linux"},{"value":"flathub","label":"Flathub"}]' && Model.choices(catalog.byId.foot).length === 0, "a choice only where there is one")
    check(Model.sourceText(arch) === "Arch Linux" && Model.sourceText(flathub) === "Flathub, verified" && Model.sourceText({ kind: "flathub" }) === "Flathub", "where it comes from, in words")
    check(Model.sourceText(catalog.byId["com.google.Chrome"].sources[0]) === "Nova, from Google's release", "Chrome's")
    check(JSON.stringify(Model.flathubSize(flathub, catalog.runtimes, none)) === '{"download":400000000,"installed":1200000000}', "a Flathub app's size with its runtime")
    check(JSON.stringify(Model.flathubSize(flathub, catalog.runtimes, fromFlathub)) === '{"download":100000000,"installed":300000000}', "and without one installed already")
    check(Model.flathubSize(arch, catalog.runtimes, none) === null, "Arch's from elsewhere")
    check(Model.sizeText(268600000) === "269 MB" && Model.sizeText(1100000000) === "1.1 GB" && Model.sizeText(2000000000) === "2 GB" && Model.sizeText(4000) === "4 kB" && Model.sizeText(0) === "", "sizes as a Mac counts them")
    check(Model.licenseText("GPL-3.0+ AND LGPL-3.0+") === "GPL-3.0+ and LGPL-3.0+" && Model.licenseText("LicenseRef-proprietary") === "Proprietary" && Model.licenseText("MIT OR LicenseRef-foo") === "MIT or Other", "licenses in words")
    var facts = Model.facts(gimp, null, flathub, Model.flathubSize(flathub, catalog.runtimes, none))
    check(JSON.stringify(facts) === '[{"label":"From","value":"Flathub, verified"},{"label":"Version","value":"3.0.4"},{"label":"Size","value":"1.2 GB"},{"label":"Developer","value":"The GIMP team"},{"label":"License","value":"GPL-3.0+ and LGPL-3.0+"}]', "the facts")
    check(Model.facts(catalog.byId.paint, null, null, null).length === 0, "and none where none is known")
    check(JSON.stringify(Model.launchWords(gimp, Model.installedFrom(gimp, fromFlathub))) === '["uwsm-app","--","flatpak","run","org.gimp.GIMP"]', "Flathub's opened by its ID")
    check(JSON.stringify(Model.launchWords(gimp, Model.installedFrom(gimp, fromArch))) === '["uwsm-app","--","gimp.desktop"]', "Arch's by the entry its package installs, not Flathub's")
    check(JSON.stringify(Model.launchWords(catalog.byId["com.google.Chrome"], { kind: "nova", package: "google-chrome" })) === '["uwsm-app","--","google-chrome.desktop"]', "Nova's by its own")
    check(JSON.stringify(Model.launchWords(catalog.byId.libfoo, Model.installedFrom(catalog.byId.libfoo, fromArch))) === '["uwsm-app","--","foo-viewer.desktop"]' && Model.launchWords(catalog.byId.foot, Model.installedFrom(catalog.byId.foot, fromArch)).length === 0, "one without an entry is not opened")
    check(Model.find(catalog, "appstream://org.gimp.GIMP") === gimp && Model.find(catalog, "org.gimp.GIMP.desktop") === gimp && Model.find(catalog, "google-chrome") === catalog.byId["com.google.Chrome"] && Model.find(catalog, "krita") === catalog.byId["org.kde.krita"] && Model.find(catalog, "nothing") === null, "an app by its ID, its entry or its name")
    check(Model.find(catalog, "constructor") === null && Model.find(catalog, "toString") === null && Model.find(catalog, "__proto__") === null, "a word that is an object's own member names no app")

    // ---- jobs ----
    var now = 1000
    var running = { "org.gimp.GIMP": { action: "install", state: "running", progress: 45, text: "Downloading", time: now } }
    var waiting = { "org.gimp.GIMP": { action: "install", state: "waiting", progress: -1, text: "Waiting", time: now } }
    var unknown = { "org.gimp.GIMP": { action: "install", state: "running", progress: -1, text: "Waiting for authentication", time: now } }
    var failed = { "org.gimp.GIMP": { action: "install", state: "failed", progress: -1, error: "could not download it; check the connection and try again", time: now } }
    var removeFailed = { "org.gimp.GIMP": { action: "remove", state: "failed", error: "another app needs it: gegl.", time: now } }
    check(JSON.stringify(Model.status(gimp, none, {}, false)) === '{"action":"get","progress":-1,"text":"","error":"","removable":false,"kept":"","removeNote":""}', "not installed: Get")
    check(Model.status(gimp, fromArch, {}, false).action === "open" && Model.status(gimp, fromArch, {}, false).removable, "installed: Open and Remove")
    check(Model.status(catalog.byId.foot, fromArch, {}, false).removable === false, "part of Nova: no Remove")
    check(Model.status(gimp, none, {}, true).action === "busy" && Model.status(gimp, none, {}, true).text === "Starting…", "asked for: starting")
    check(Model.status(gimp, none, waiting, false).text === "Waiting…", "behind another")
    var s = Model.status(gimp, none, running, false)
    check(s.action === "busy" && s.progress === 0.45 && s.text === "Downloading 45%", "how far")
    check(Model.status(gimp, none, unknown, false).progress === -1 && Model.status(gimp, none, unknown, false).text === "Waiting for authentication…", "not known how far")
    check(Model.status(gimp, none, failed, false).error === "Could not install it: could not download it; check the connection and try again." && Model.status(gimp, none, failed, false).action === "get", "a failure says why, and Get again")
    check(Model.status(gimp, fromArch, removeFailed, false).error === "Could not remove it: another app needs it: gegl.", "a removal's")
    check(Model.asked(gimp, {}, { "org.gimp.GIMP": now }) && !Model.asked(gimp, running, { "org.gimp.GIMP": now }) && Model.asked(gimp, running, { "org.gimp.GIMP": now + 1 }), "asked for until a job of that time or later says something")
    var jobs = { a: { state: "failed", time: 10 }, b: { state: "running", time: 5 }, c: { state: "done", time: 20 } }
    check(Object.keys(Model.visibleJobs(jobs, 15)).join(",") === "b,c", "the jobs worth showing: those under way, and those ended since the window opened")
    check(Model.endedSince(jobs, 15) && !Model.endedSince(jobs, 21), "one that ended since: what is installed is read again")

    console.log("DONE")
    Qt.quit()
  }
}
