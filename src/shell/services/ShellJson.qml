import QtQuick
import Quickshell
import Quickshell.Io

// shell.json, the two of it: Nova's, in $NOVA_PATH/default, and the user's,
// in ~/.config/nova. The config in effect is the user's when it is an object
// with version 1, else Nova's when that is one, else the fallback below;
// they are never merged. It is worked out once both files have been read
// (or found missing or unreadable), and again each time one is read anew.
QtObject {
  id: shellJson

  readonly property string defaultsPath: Quickshell.env("NOVA_PATH") + "/default/shell.json"
  readonly property string userPath: Quickshell.env("HOME") + "/.config/nova/shell.json"

  // What the shell has when Nova's shell.json cannot be read: enough for a
  // working bar, no more.
  readonly property var fallback: ({
    version: 1,
    idle: { lock: 300 },
    bar: {
      position: "top",
      transparent: false,
      centerAnchor: "nova.clock",
      layout: {
        left: [{ id: "nova.menu" }, { id: "nova.workspaces" }],
        center: [{ id: "nova.clock", format: "dddd HH:mm" }],
        right: [{ id: "nova.audio" }]
      }
    },
    plugins: []
  })

  // Nova's shell.json, or the fallback.
  property var defaults: fallback
  // The config in effect: a new object each time it is worked out or
  // saved, even one that reads the same.
  property var current: fallback
  // Set for good once the config in effect has first been worked out from
  // both files.
  property bool ready: false

  property bool defaultsSeen: false
  property bool userSeen: false

  // Reads the user's shell.json again.
  function reload() {
    userFile.reload()
  }

  // Calls change(draft) with a copy of the config in effect to change in
  // place, and saves the draft, unless change answers false. Whether it
  // saved.
  function edit(change) {
    var draft = JSON.parse(JSON.stringify(current || fallback))
    if (change(draft) === false) return false
    save(draft)
    return true
  }

  // Makes <config>, at version 1, the config in effect, and writes it to
  // the user's shell.json.
  function save(config) {
    var saved = JSON.parse(JSON.stringify(config))
    saved.version = 1
    current = saved
    userFile.setText(JSON.stringify(saved, null, 2) + "\n")
  }

  function readDefaults(text) {
    var parsed = null
    var trimmed = String(text || "").trim()
    if (trimmed !== "") {
      try {
        parsed = JSON.parse(trimmed)
      } catch (e) {
        console.warn("default shell.json parse failed, using builtin: " + e)
      }
    }
    defaults = isConfig(parsed) ? parsed : fallback
    defaultsSeen = true
    settle()
  }

  function readUser() {
    userSeen = true
    settle()
  }

  function settle() {
    if (!defaultsSeen || !userSeen) return
    current = chosen()
    ready = true
  }

  // The user's config when it is one, else Nova's. A user's file that is
  // JSON but not an object (null, a list) falls back without a word.
  function chosen() {
    var text = userFile.text() || ""
    if (!text.trim()) return defaults
    var user
    try {
      user = JSON.parse(text)
    } catch (e) {
      console.warn("shell.json parse failed, using defaults: " + e)
      return defaults
    }
    if (isConfig(user)) return user
    if (user && typeof user === "object" && !Array.isArray(user)) console.warn("shell.json missing version: 1, using defaults")
    return defaults
  }

  function isConfig(value) {
    return !!value && typeof value === "object" && !Array.isArray(value) && value.version === 1
  }

  property FileView defaultsFile: FileView {
    path: shellJson.defaultsPath
    watchChanges: true
    printErrors: false
    onLoaded: shellJson.readDefaults(text())
    onLoadFailed: function(error) {
      console.warn("default shell.json load failed: " + error + " path=" + shellJson.defaultsPath)
      shellJson.readDefaults("")
    }
    onFileChanged: reload()
  }

  property FileView userFile: FileView {
    path: shellJson.userPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: shellJson.readUser()
    onLoadFailed: shellJson.readUser()
    onFileChanged: reload()
  }
}
