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
Item {
  id: commands

  // ToastFiles, whose jobs move and remove the files.
  required property var files

  readonly property string runtime: Quickshell.env("XDG_RUNTIME_DIR") || ""
  // With its slash; "" without a runtime folder, and then nothing is claimed.
  readonly property string folder: runtime !== "" ? runtime + "/nova/notifications/" : ""

  readonly property var none: ({ own: false, execArgv: "", buttons: "" })

  // The names claimed, each with the notification that claimed it and what
  // its file said: a sender's update comes as one signal a property, and each
  // asks again. The newest `most` are kept, more than ever show at once.
  property var claims: ({})
  property var order: []
  readonly property int most: 64

  // The commands of a notification, toast `stem`, from the file its
  // nova-command hint names; none for a notification whose hint names none,
  // or a file another has claimed.
  function claim(notification, stem) {
    var name = Notes.commandName(notification)
    if (name === "" || folder === "") return none
    var known = claims[name]
    if (known) return known.by === notification ? known.said : none
    var said = Notes.commandsOf(read(folder + name))
    remember(name, notification, said ? Object.assign({ own: true }, said) : none)
    if (said) files.claim(name, stem)
    return claims[name].said
  }

  function remember(name, notification, said) {
    var next = Object.assign({}, claims)
    next[name] = { by: notification, said: said }
    var names = order.concat([name])
    while (names.length > most) delete next[names.shift()]
    claims = next
    order = names
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
