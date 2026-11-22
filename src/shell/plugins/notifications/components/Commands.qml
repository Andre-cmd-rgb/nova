import QtQuick
import Quickshell
import Quickshell.Io
import "../NotificationLogic.js" as Notes

// The commands Nova's own programs attach to their notifications: what a
// click runs, and the buttons. Any program on the session bus may send a
// notification's hints, a sandboxed app's too (its calls come through a bus
// proxy, which runs outside the sandbox), so no hint carries a command. The
// sender writes it into a file in Nova's runtime folder,
// $XDG_RUNTIME_DIR/nova/notifications/, private to the user's own programs
// (0700; a Flatpak or a snap does not see it), as {"argv": [...], "buttons":
// [{"says": ..., "argv": [...], "main": true}]}, each optional, under a name
// of 32 random hex digits; the notification's nova-command hint names it.
// nova-notification-send is the one that does (the iPhone's daemon writes its
// pairing question's itself, the same way). A file with neither also counts:
// the notification is Nova's own, which do-not-disturb lets through as
// "nova-action" (Notes.breaksThroughDnd).
//
// A name is claimed once, by the first notification that names it: its file
// becomes the toast's own, <stem>.json (files.sh claim), and stays as long as
// the toast or its place in the history does, so that a toast back after a
// restart, or replayed, still runs it. The folder goes with the session.
//
// A command belongs to what the notification said when it brought it. Any
// program may send a notification under the id of one on screen
// (replaces_id), a sandboxed app's too: the new words come to the same
// notification, or to a new one under the same file name if both came in one
// millisecond. Words that bring no claim of their own take the file away, or
// a click on them, from the history or after a restart, would run what Nova's
// program had attached to its own.
Item {
  id: commands

  // ToastFiles, whose jobs move and remove the files.
  required property var files

  readonly property string runtime: Quickshell.env("XDG_RUNTIME_DIR") || ""
  // With its slash; "" without a runtime folder, and then nothing is claimed.
  readonly property string folder: runtime !== "" ? runtime + "/nova/notifications/" : ""

  readonly property var none: ({ own: false, execArgv: "", buttons: "" })

  // The claims of the notifications still open, by name: the notification,
  // its toast's stem and what its file said. A sender's update comes as one
  // signal a property, and each asks again; the file has been moved by then.
  // A claim stays until its notification closes or its words change, never
  // pushed out by others: any program may send notifications naming files
  // that are not there, and those are not kept at all.
  property var claims: ({})
  // The names whose file is still being moved, which no other notification
  // may claim meanwhile. Once moved, a name names nothing.
  property var moving: ({})

  // The commands of a notification, toast `stem`, from the file its
  // nova-command hint names; none for a notification whose hint names none,
  // or a file another has claimed. What it, or another under the same file
  // name, had claimed with other words goes first.
  function claim(notification, stem) {
    var name = Notes.commandName(notification)
    var known = claims[name]
    if (name !== "" && known && known.by === notification) return known.said
    for (var lost of Object.keys(claims).filter(other => claims[other].by === notification || claims[other].stem === stem)) {
      lose(lost)
    }
    if (name === "" || folder === "" || claims[name] || moving[name]) return none
    var file = Notes.commandsOf(read(folder + name))
    if (!file) return none
    var said = Object.assign({ own: true }, file)
    claims = Object.assign({}, claims, { [name]: { by: notification, stem: stem, said: said } })
    moving = Object.assign({}, moving, { [name]: true })
    files.claim(name, stem, () => {
      var left = Object.assign({}, commands.moving)
      delete left[name]
      commands.moving = left
    })
    return said
  }

  function forget(name) {
    var left = Object.assign({}, claims)
    delete left[name]
    claims = left
  }

  // A claim's file gone, its notification's words being others now.
  function lose(name) {
    files.unclaim(claims[name].stem)
    forget(name)
  }

  // A notification closed: its claims let go, and its file stays with its
  // toast, which may be in the history.
  function release(notification) {
    for (var name of Object.keys(claims).filter(other => claims[other].by === notification)) forget(name)
  }

  // What toast `stem` from before (a restart, the history) runs: its own
  // file's commands, none once the session it came in has ended.
  function kept(stem) {
    if (folder === "" || !/^\d+-\d+$/.test(String(stem))) return none
    var said = Notes.commandsOf(read(folder + stem + ".json"))
    return said ? Object.assign({ own: true }, said) : none
  }

  // A file read at once, "" for none: it is small, on a tmpfs, and what it
  // says decides how the toast shows.
  FileView {
    id: reader
    blockAllReads: true
    printErrors: false
  }

  function read(path) {
    reader.path = path
    reader.reload()
    return String(reader.text() || "")
  }
}
