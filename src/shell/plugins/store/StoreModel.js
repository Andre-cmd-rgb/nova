// The App Center's logic, apart from its window: its pages, the search, what
// an app's page says and offers, from three things the helpers give it:
//
//   catalog    nova-apps-catalog's file: { runtimes, apps: [{ id, name,
//              summary, category, icon, sources: [{ kind, ... }], featured, popular,
//              position, rank, ... }] }, the apps in the store's own order
//   installed  nova-apps-installed: { flatpak: [{ app, installation,
//              version }], runtimes, pacman: { name: version }, explicit,
//              nova }
//   jobs       $XDG_RUNTIME_DIR/nova/apps/status.json: { id: { action,
//              source, state, progress, text, error, time } }

.pragma library

// The sidebar: the front page, the categories, and what is installed.
var pages = [
  { id: "discover", label: "Discover", icon: "󰀻" },
  { id: "create", label: "Create", icon: "󰏘", group: true },
  { id: "work", label: "Work", icon: "󰈙" },
  { id: "play", label: "Play", icon: "󰊗" },
  { id: "develop", label: "Develop", icon: "󰅩" },
  { id: "internet", label: "Internet", icon: "󰖟" },
  { id: "media", label: "Music & Video", icon: "󰝚" },
  { id: "learn", label: "Learn", icon: "󰑴" },
  { id: "utilities", label: "Utilities", icon: "󰒓" },
  { id: "installed", label: "Installed", icon: "󰄬", group: true }
]

function pageLabel(id) {
  for (var i = 0; i < pages.length; i++)
    if (pages[i].id === id) return pages[i].label
  return ""
}

// The categories the front page shows, in order: every page but itself and
// Installed.
function categories() {
  return pages.filter(function (p) { return p.id !== "discover" && p.id !== "installed" })
}

// The rows of the front page, in order: Popular, which is no page of its
// own, and then each category.
function shelves() {
  return [{ id: "popular", label: "Popular" }].concat(categories())
}

// The catalog's text as an object with an index by ID, or null when it is
// not one.
function read(text) {
  var catalog
  try {
    catalog = JSON.parse(String(text || ""))
  } catch (e) {
    return null
  }
  if (!catalog || !Array.isArray(catalog.apps)) return null
  var byId = Object.create(null)
  for (var i = 0; i < catalog.apps.length; i++) byId[catalog.apps[i].id] = catalog.apps[i]
  catalog.byId = byId
  catalog.runtimes = catalog.runtimes || {}
  return catalog
}

// ---- lists ------------------------------------------------------------------

// A row's apps from the front page, in their order: a category's, or
// "popular", the best-known of every kind, which an app can be in as well as
// in its category.
function featured(apps, category) {
  if (category === "popular")
    return (apps || []).filter(function (a) { return a.popular > 0 })
      .sort(function (a, b) { return a.popular - b.popular })
  return (apps || []).filter(function (a) { return a.featured === category })
    .sort(function (a, b) { return (a.position || 0) - (b.position || 0) })
}

// A category's apps, its front page's first; the catalog is in the store's
// order already.
function inCategory(apps, category) {
  var first = featured(apps, category)
  var rest = (apps || []).filter(function (a) { return a.category === category && a.featured !== category })
  return first.concat(rest)
}

// How well an app matches one word: its name, the start of a word of its
// name, a keyword, its summary, its ID. The same as nova apps search's.
function wordScore(app, word) {
  var name = String(app.name || "").toLowerCase()
  if (name === word) return 100
  if (name.indexOf(word) === 0) return 80
  if (name.split(" ").some(function (w) { return w.indexOf(word) === 0 })) return 60
  if (String(app.keywords || "").toLowerCase().split(" ").some(function (w) { return w.indexOf(word) === 0 })) return 40
  if (String(app.summary || "").toLowerCase().indexOf(word) >= 0) return 20
  if (String(app.id || "").toLowerCase().indexOf(word) >= 0) return 10
  return 0
}

function words(query) {
  return String(query || "").toLowerCase().split(" ").filter(function (w) { return w.length > 0 })
}

// Every word matched, and how well, with a quarter of the app's rank: an app
// of the front page that matches at all before one with the word for a name.
function order(app, list) {
  if (list.length === 0) return 0
  var total = 0
  for (var i = 0; i < list.length; i++) {
    var s = wordScore(app, list[i])
    if (s === 0) return 0
    total += s
  }
  return total + Math.floor((app.rank || 0) / 4)
}

function search(apps, query, limit) {
  var list = words(query)
  var found = []
  for (var i = 0; i < (apps || []).length; i++) {
    var o = order(apps[i], list)
    if (o > 0) found.push({ app: apps[i], order: o })
  }
  found.sort(function (a, b) {
    if (a.order !== b.order) return b.order - a.order
    var an = String(a.app.name).toLowerCase(), bn = String(b.app.name).toLowerCase()
    return an < bn ? -1 : an > bn ? 1 : 0
  })
  return found.slice(0, limit || 60).map(function (f) { return f.app })
}

// ---- what is installed ------------------------------------------------------------

// Where the app is installed: { kind, scope, version, package } for the
// first of its sources that is, or null.
function installedFrom(app, installed) {
  if (!app || !installed) return null
  var sources = app.sources || []
  for (var i = 0; i < sources.length; i++) {
    var s = sources[i]
    if (s.kind === "flathub") {
      var list = installed.flatpak || []
      for (var j = 0; j < list.length; j++)
        if (list[j].app === s.app) return { kind: "flathub", scope: list[j].installation, version: list[j].version || "", app: s.app }
    } else if (s.package && installed.pacman && installed.pacman[s.package] !== undefined) {
      return { kind: s.kind, scope: "system", version: installed.pacman[s.package], package: s.package }
    }
  }
  return null
}

// The installed apps, by name.
function installedApps(apps, installed) {
  return (apps || []).filter(function (a) { return installedFrom(a, installed) !== null })
    .sort(function (a, b) {
      var an = String(a.name).toLowerCase(), bn = String(b.name).toLowerCase()
      return an < bn ? -1 : an > bn ? 1 : 0
    })
}

// The Installed page's line under a name: where it came from and its
// version, or why it stays.
function installedText(app, installed) {
  var from = installedFrom(app, installed)
  if (!from) return ""
  var why = kept(app, installed)
  if (why) return why
  return sourceName(from.kind) + (from.version ? " · " + from.version : "")
}

// What Remove says of the app's data: a Flathub app's sandbox folder goes
// with it; an app of Arch's or Nova's keeps its files in the home folder,
// where Nova cannot tell which are its, so they stay.
function removeNote(app, installed) {
  var from = installedFrom(app, installed)
  if (!from) return ""
  return from.kind === "flathub" ? "Its data goes with it." : "Your files and settings for it stay."
}

// Why an installed app has no Remove: part of Nova, or installed with
// another app, which needs it; "" when it can be removed.
function kept(app, installed) {
  var from = installedFrom(app, installed)
  if (!from || from.kind === "flathub") return ""
  if ((installed.nova || []).indexOf(from.package) >= 0) return "Part of Nova"
  if (from.kind === "arch" && (installed.explicit || []).indexOf(from.package) < 0) return "Installed with another app"
  return ""
}

// ---- an app's page ---------------------------------------------------------------

var sourceNames = { nova: "Nova", arch: "Arch Linux", flathub: "Flathub" }

function sourceName(kind) {
  return sourceNames[kind] || String(kind || "")
}

// The source an install takes: the one picked on the page, when the app has
// it, else the store's first.
function offered(app, picked) {
  var sources = (app && app.sources) || []
  for (var i = 0; i < sources.length; i++)
    if (sources[i].kind === picked) return sources[i]
  return sources.length > 0 ? sources[0] : null
}

// The picker's choices, only for an app that comes from more than one place.
function choices(app) {
  var sources = (app && app.sources) || []
  if (sources.length < 2) return []
  return sources.map(function (s) { return { value: s.kind, label: sourceName(s.kind) } })
}

// Where it comes from, as its facts say it: Nova's with its maker's name,
// Flathub's checked as its developer's own.
function sourceText(source) {
  if (!source) return ""
  if (source.kind === "nova") return "Nova, from " + (source.maker || "its maker") + "'s release"
  if (source.kind === "flathub") return source.verified ? "Flathub, verified" : "Flathub"
  return sourceName(source.kind)
}

// What an install from Flathub adds: the app, and its runtime when it is
// not installed already (installed.runtimes as flatpak list names them,
// "org.gnome.Platform/x86_64/48"). Arch's comes from nova-apps-size instead.
function flathubSize(source, runtimes, installed) {
  if (!source || source.kind !== "flathub") return null
  var size = { download: source.download || 0, installed: source.installed || 0 }
  var runtime = String(source.runtime || "")
  var have = ((installed && installed.runtimes) || []).map(function (r) { return String(r).replace(/^runtime\//, "") })
  if (runtime && have.indexOf(runtime) < 0 && runtimes && runtimes[runtime]) {
    size.download += runtimes[source.runtime].download || 0
    size.installed += runtimes[source.runtime].installed || 0
  }
  return size.installed > 0 ? size : null
}

// 268600000 -> "269 MB", 1100000000 -> "1.1 GB", as a Mac counts.
function sizeText(bytes) {
  var n = Number(bytes || 0)
  if (!(n > 0)) return ""
  if (n >= 1e9) return (n / 1e9).toFixed(1).replace(/\.0$/, "") + " GB"
  if (n >= 1e6) return Math.round(n / 1e6) + " MB"
  return Math.max(1, Math.round(n / 1e3)) + " kB"
}

// The app a word names, as nova apps does: its ID (with or without
// .desktop), its desktop entry's, or its name; null when none is.
function find(catalog, word) {
  if (!catalog || !word) return null
  var w = String(word).replace(/^appstream:(\/\/)?/, "")
  if (catalog.byId[w]) return catalog.byId[w]
  var bare = w.replace(/\.desktop$/, "").toLowerCase()
  var apps = catalog.apps || []
  for (var i = 0; i < apps.length; i++) {
    var a = apps[i]
    if (String(a.id).replace(/\.desktop$/, "").toLowerCase() === bare) return a
    if (String(a.desktop || "").replace(/\.desktop$/, "").toLowerCase() === bare) return a
  }
  for (var j = 0; j < apps.length; j++)
    if (String(apps[j].name).toLowerCase() === w.toLowerCase()) return apps[j]
  return null
}

// The jobs worth showing: those under way, and those that ended since
// <since> (seconds), the window's opening: an error from an hour ago is
// not news.
function visibleJobs(jobs, since) {
  var out = {}
  for (var id in (jobs || {})) {
    var job = jobs[id]
    if (!job) continue
    if (job.state === "waiting" || job.state === "running" || Number(job.time || 0) >= since) out[id] = job
  }
  return out
}

// Asked for (<pending>: { id: seconds }) and not begun: no job of that time
// or later yet.
function asked(app, jobs, pending) {
  if (!app || !pending || pending[app.id] === undefined) return false
  var job = jobOf(app, jobs)
  return !job || Number(job.time || 0) < pending[app.id]
}

// Whether a job has ended since <since>: the installed apps are read again.
function endedSince(jobs, since) {
  for (var id in (jobs || {})) {
    var job = jobs[id]
    if (job && (job.state === "done" || job.state === "failed" || job.state === "cancelled") && Number(job.time || 0) >= since)
      return true
  }
  return false
}

// The job the store started for an app: { state, action, progress, text,
// error, time }, or null.
function jobOf(app, jobs) {
  return app && jobs && jobs[app.id] ? jobs[app.id] : null
}

// What the page's button and the line under it say, and how far a job is:
// { action: "get" | "open" | "busy", progress (0..1, or -1 while not
// known), text, error, removable, kept, removeNote }. <waiting> is a job asked for that
// has not said anything yet (asked()).
function status(app, installed, jobs, waiting) {
  var job = jobOf(app, jobs)
  var from = installedFrom(app, installed)
  var out = { action: from ? "open" : "get", progress: -1, text: "", error: "", removable: false, kept: "", removeNote: "" }
  if (from) {
    out.removeNote = removeNote(app, installed)
    out.kept = kept(app, installed)
    out.removable = out.kept === ""
  }
  if (waiting) {
    out.action = "busy"
    out.text = "Starting…"
  } else if (job && job.state === "waiting") {
    out.action = "busy"
    out.text = "Waiting…"
  } else if (job && job.state === "running") {
    out.action = "busy"
    var p = Number(job.progress)
    out.progress = isFinite(p) && p >= 0 ? Math.min(1, p / 100) : -1
    out.text = (job.text || (job.action === "remove" ? "Removing" : "Installing"))
      + (out.progress >= 0 ? " " + Math.round(out.progress * 100) + "%" : "…")
  } else if (job && job.state === "failed") {
    var error = String(job.error || "it did not work")
    out.error = (job.action === "remove" ? "Could not remove it: " : "Could not install it: ") + error
      + (/[.!?]$/.test(error) ? "" : ".")
  }
  return out
}

// What opens it: Flathub's app by its ID; one from Arch by the desktop entry
// its package installs, which can be named otherwise than Flathub's
// (firefox.desktop); Nova's by its own.
function launchWords(app, from) {
  if (!app || !from) return []
  if (from.kind === "flathub") return ["uwsm-app", "--", "flatpak", "run", from.app]
  var desktop = String(app.desktop || "")
  if (from.kind === "arch") {
    var own = (app.sources || []).filter(function (s) { return s.kind === "arch" && s.package === from.package })[0]
    desktop = String((own && own.desktop) || "")
  }
  if (!desktop) return []
  if (!/\.desktop$/.test(desktop)) desktop += ".desktop"
  return ["uwsm-app", "--", desktop]
}

// The page's facts, in order: [{ label, value }], the empty ones left out:
// where it is installed from, or comes from; the version installed, or the
// one the source offered has.
function facts(app, from, source, size) {
  var list = [
    { label: "From", value: sourceText(source) },
    { label: "Version", value: from ? from.version : (source ? source.version || "" : "") },
    { label: "Size", value: size ? sizeText(size.installed) : "" },
    { label: "Developer", value: app.developer || "" },
    { label: "License", value: licenseText(app.license) }
  ]
  return list.filter(function (f) { return String(f.value || "").length > 0 })
}

// "GPL-3.0+ AND LGPL-3.0+" -> "GPL-3.0+ and LGPL-3.0+"; a proprietary one
// as Flathub writes it (LicenseRef-proprietary) -> "Proprietary".
function licenseText(license) {
  var text = String(license || "")
  if (/LicenseRef-proprietary/i.test(text)) return "Proprietary"
  return text.replace(/LicenseRef-[^ ]*/g, "Other").replace(/ AND /g, " and ").replace(/ OR /g, " or ").replace(/ WITH /g, " with ")
}
