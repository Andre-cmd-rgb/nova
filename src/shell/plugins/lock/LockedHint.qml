import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// logind's LockedHint for this session, as the lock is: true once the lock is
// secure, false once it ends. It is what `loginctl show-session -p LockedHint`
// says, and what tools built on logind read. The session is the one Hyprland
// runs in, $XDG_SESSION_ID, which Hyprland's start hands to the user manager;
// without it, logind's "auto", the user's display session: the shell runs in
// a user service, which belongs to none. nova-sessiond follows logind's Lock
// for the same one (src/session/daemon/src/sleep.rs). A session's owner may
// set its hint, so nothing asks. Set only as the lock changes: logind starts
// a session with it false, and a shell that crashed under the lock leaves it
// true, as the lock it left is. One call at a time; a change while one runs
// is made after it, and a call that fails is made once more. A logind
// started again knows nothing of the hint the last one held: nova-sessiond
// writes $XDG_RUNTIME_DIR/nova/logind when one comes, and a secure lock says
// so again.
Process {
  id: hint

  // Whether the lock is secure.
  required property bool secure
  // logind's name for the session, or "" for its "auto".
  property string login: Quickshell.env("XDG_SESSION_ID") || ""
  readonly property string sessionPath: "/org/freedesktop/login1/session/" + pathName(login)
  // What the call under way, or the last, said; whether it is the second
  // try; whether one more is owed once it ends.
  property bool said: false
  property bool again: false
  property bool owed: false

  // logind's object path for a session's name ("1", "c2"), as sd-bus
  // escapes it: letters and digits stay, but a digit first is _ and its two
  // hex digits ("1" is _31). A name logind would not give is "auto".
  function pathName(name) {
    if (!/^[A-Za-z0-9]+$/.test(name)) return "auto"
    return name.split("").map((c, i) => /[A-Za-z]/.test(c) || i > 0 ? c : "_" + c.charCodeAt(0).toString(16)).join("")
  }

  function apply() {
    if (running) owed = true
    else call(false)
  }

  function call(retry) {
    owed = false
    again = retry
    said = secure
    command = ["busctl", "--system", "--", "call", "org.freedesktop.login1", sessionPath,
      "org.freedesktop.login1.Session", "SetLockedHint", "b", said ? "true" : "false"]
    running = true
  }

  onSecureChanged: apply()
  onExited: exitCode => {
    if (owed || said !== secure) call(false)
    else if (exitCode !== 0 && !again) call(true)
  }

  // The folder first, once: Quickshell hears of a file in a folder that is
  // there as it starts to watch.
  property bool watching: false
  property Process maker: Process {
    running: true
    command: ["mkdir", "-p", Quickshell.env("XDG_RUNTIME_DIR") + "/nova"]
    onExited: hint.watching = true
  }

  // What the file held as the shell started is not news.
  property string stamp: ""
  property bool read: false
  function take(text) {
    const line = String(text || "").trim()
    const news = read && line !== "" && line !== stamp
    read = true
    if (line !== "") stamp = line
    if (news && secure) apply()
  }
  property WatchedFile newLogind: WatchedFile {
    path: hint.watching ? Quickshell.env("XDG_RUNTIME_DIR") + "/nova/logind" : ""
    onLoaded: hint.take(text())
    onLoadFailed: hint.take("")
  }
}
