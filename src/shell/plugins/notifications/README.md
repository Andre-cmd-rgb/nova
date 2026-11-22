# Notifications

Nova's notification server (`org.freedesktop.Notifications`, Quickshell's
`NotificationServer`) and its toasts at the top right of every screen:
`Service.qml`. Do Not Disturb and its hours, the history (the last ten
toasts, replayed on Super+Shift+Alt+comma) and the toasts on screen across a
shell's restart are kept in `$XDG_STATE_HOME/nova/` (`files.sh`,
`components/ToastFiles.qml`). The rules apart from the QML, what a toast may
show and how long it stays, are in `NotificationLogic.js`.

## What a notification runs

A toast of Nova's own can run a command when it is clicked (Super+Alt+comma
clicks the newest), and can have up to three buttons, each with a command of
its own: AirDrop's Decline and Accept, a crashed app's Reopen, the iPhone's
Cancel and Pair. The shell runs these as they are, never through a shell,
and outside any sandbox, so they must come from Nova and nowhere else.

A notification's hints cannot say that: any program on the session bus may
send them, a sandboxed app's too, since a Flatpak's calls arrive through its
bus proxy, which runs outside the sandbox. So no hint carries a command. A
sender writes the commands into a file of its own in Nova's runtime folder,
`$XDG_RUNTIME_DIR/nova/notifications/`, which only the user's own programs can
reach (0700; a Flatpak or a snap is not given it), under a name of 32 random
hex digits, and the notification's `nova-command` hint carries that name:

```json
{"argv": ["xdg-open", "/home/me/Downloads/a.pdf"],
 "buttons": [{"says": "Open", "argv": ["xdg-open", "/home/me/Downloads/a.pdf"], "main": true}]}
```

Both keys are optional; a file with neither still says that the notification
is Nova's own, which is what lets a toast sent as `nova-action` through Do Not
Disturb (one that only calls itself so is kept back like any app's). An argv
written in a hint (the old `nova-exec-argv` and `nova-buttons`) runs nothing
and shows no button, whoever sends it.

- **Sending.** `nova-notification-send` (`nova notification send`) is how a
  Nova program sends one: `--exec <program> [args...]` for a click,
  `--button <words>` to put that on a button, `--buttons <json>` for buttons
  with commands of their own; AirDrop sends through it too. The iPhone daemon
  writes its pairing question's file itself, the same way
  (`commands_file` in `src/iphone/daemon/src/service.rs`).
- **Claiming.** The first notification that names a file claims it
  (`components/Commands.qml`): the file becomes the toast's own,
  `<stem>.json`, its time and id, and no other notification gets anything
  from that name.
- **Belonging.** A command belongs to what the notification said when it
  brought it. Any program may send a notification under the id of one on
  screen (`replaces_id`), a sandboxed app's too; new words that bring no
  claim of their own, in place or as a new notification under the same file
  name, take the file away, so that a click on them runs nothing, live, from
  the history or after a restart. A Nova program updating its own toast
  sends a new file with it.
- **Keeping.** The toast's file stays while the toast is on screen or in the
  history, so that a toast back after a restart, or replayed, still runs it;
  it goes with the toast when that asked something (an offer) or was let go,
  and with the history's oldest when a newer one pushes it out. A sweep as the
  shell starts takes away the rest, and the folder itself ends with the
  session, so nothing runs from a toast of an earlier boot. The files in the
  state folder keep no command.

The names never leave the runtime folder and the two programs: hints are not
sent on to other clients, the server's `GetServerInformation` says only its
name and version, and the history keeps no name.

Tests: `tests/qml/notifications-test.qml` (the rules),
`tests/qml/notifications-commands-test.qml` (the service against the
installed `nova-notification-send`), `tests/qml/notifications-keep-test.qml`
(what the files keep across the history and a restart, and whose a command
is), `tests/unit/cli/notification-send.bats`
and `tests/unit/tools/notification-commands.bats`.
