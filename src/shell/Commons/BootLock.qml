pragma Singleton
import QtQuick
import Quickshell

// Whether the boot's own lock is still to come. A session nobody signed into
// (greetd's autologin, NOVA_LOGIN other than "password") is locked before
// anything of it shows; until the compositor holds that lock, the windows
// the shell keeps up for good (the bar, the desktop's background) stay
// unmapped, so that no frame of the desktop shows before the lock does. The
// lock service (plugins/lock) clears it once the lock is secure, or once it
// knows the boot's first unlock is done already (a shell started again). It
// is never set again: what is behind a later lock is the lock's to hide.
QtObject {
  property bool pending: Quickshell.env("NOVA_LOGIN") !== "password"
}
