import QtQuick
import Quickshell.Io

// logind's LockedHint for this session, as the lock is: true once the lock is
// secure, false once it ends. It is what `loginctl show-session -p LockedHint`
// says, and what tools built on logind read. The session is the user's
// display session, logind's "auto", which the call names: the shell runs in
// a user service, which belongs to no session. A session's owner may set its
// hint, so nothing asks. Set only as the lock changes: logind starts a
// session with it false, and a shell that crashed under the lock leaves it
// true, as the lock it left is. One call at a time; a change while one runs
// is made after it.
Process {
  id: hint

  // Whether the lock is secure.
  required property bool secure
  // What the call under way, or the last, said.
  property bool said: false

  function apply() {
    if (running) return
    said = secure
    command = ["busctl", "--system", "--", "call", "org.freedesktop.login1", "/org/freedesktop/login1/session/auto",
      "org.freedesktop.login1.Session", "SetLockedHint", "b", said ? "true" : "false"]
    running = true
  }

  onSecureChanged: apply()
  onExited: if (said !== secure) apply()
}
