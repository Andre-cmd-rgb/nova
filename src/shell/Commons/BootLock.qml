pragma Singleton
import QtQuick
import Quickshell

// The boot's own lock, as the shell's parts need to know it.
QtObject {
  // Whether the boot's own lock is still to come. A session nobody signed into
  // (greetd's autologin, NOVA_LOGIN other than "password") is locked before
  // anything of it shows; until the compositor holds that lock, the windows
  // the shell keeps up for good (the bar, the desktop's background) stay
  // unmapped, so that no frame of the desktop shows before the lock does. The
  // lock service (plugins/lock) clears it once the lock is secure, or once it
  // knows the boot's first unlock is done already (a shell started again). It
  // is never set again: what is behind a later lock is the lock's to hide.
  property bool pending: Quickshell.env("NOVA_LOGIN") !== "password"

  // Whether the boot's first unlock is done: its password, or the greeter's,
  // has opened the login keyring too (pam_gnome_keyring). What reads the
  // keyring of itself, such as the calendar's sync, waits for it: asked
  // earlier, behind the lock, the keyring asks for its password on a card
  // that stays up after the unlock has opened it. The lock service sets it,
  // read back from the runtime folder in a shell started again, and it stays
  // set: a later lock leaves the keyring open.
  property bool unlocked: Quickshell.env("NOVA_LOGIN") === "password"
}
