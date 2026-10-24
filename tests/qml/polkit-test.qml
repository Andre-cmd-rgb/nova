import QtQuick
import Quickshell
import "plugins/polkit/PolkitModel.js" as PolkitModel

// What the polkit dialog reads from /etc/pam.d/polkit-1: whether the reader is
// in play, so the dialog opens on the fingerprint rather than the password.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    var configured = PolkitModel.fingerprintConfiguredFromPamConfig
    check(configured("auth [success=ignore default=1] pam_exec.so quiet /usr/lib/nova/bin/nova-hw-laptop-open\n"
      + "-auth sufficient pam_fprintd.so timeout=15\nauth include system-auth\n"), "Nova's own polkit-1, its reader on an -auth line")
    check(configured("auth\tsufficient\tpam_fprintd.so\nauth include system-auth"), "a reader on a plain auth line")
    check(!configured("auth include system-auth\naccount include system-auth"), "polkit's own file, no reader")
    check(!configured("# -auth sufficient pam_fprintd.so\nauth include system-auth"), "a reader commented out")
    check(!configured("account required pam_fprintd.so"), "a reader outside the auth stack")
    check(!configured("") && !configured(undefined), "no file at all")
    console.log("DONE")
    Qt.quit()
  }
}
