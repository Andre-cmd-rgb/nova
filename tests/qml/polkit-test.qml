import QtQuick
import Quickshell
import "plugins/polkit/PolkitModel.js" as PolkitModel

// What the polkit dialog reads from /etc/pam.d/polkit-1: whether the reader is
// in play, so the dialog opens on the fingerprint rather than the password;
// what the dialog says a request is for; and whose password it asks for.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    var configured = PolkitModel.fingerprintInPam
    check(configured("auth [success=ignore default=1] pam_exec.so quiet /usr/lib/nova/bin/nova-hw-laptop-open\n"
      + "-auth sufficient pam_fprintd.so timeout=15\nauth include system-auth\n"), "Nova's own polkit-1, its reader on an -auth line")
    check(configured("auth\tsufficient\tpam_fprintd.so\nauth include system-auth"), "a reader on a plain auth line")
    check(!configured("auth include system-auth\naccount include system-auth"), "polkit's own file, no reader")
    check(!configured("# -auth sufficient pam_fprintd.so\nauth include system-auth"), "a reader commented out")
    check(!configured("account required pam_fprintd.so"), "a reader outside the auth stack")
    check(!configured("") && !configured(undefined), "no file at all")
    const labels = ["Authentication is needed to run `/usr/bin/foo' as the super user", "Authentication is required to run '/usr/bin/bar --x' as root\nmore",
      "authentication IS NEEDED to run `x' as y", "Authentication is needed to change settings", "", null, undefined, "  Authentication is needed to run `x' as",
      "Authentication is needed to run `a`b' as", "Authentication is needed to run `$1 & co' as the super user", "Authentication is needed to run `x' as "]
    check(JSON.stringify(labels.map(PolkitModel.requestLabel)) === JSON.stringify(["Authorize running '/usr/bin/foo'", "Authorize running '/usr/bin/bar --x'",
      "Authorize running 'x'", "Authentication is needed to change settings", "", "", "", "  Authentication is needed to run `x' as",
      "Authentication is needed to run `a`b' as", "Authorize running '$1 & co'", "Authorize running 'x'"]), "pkexec's request as what it runs, any other as it is")
    const account = PolkitModel.accountName
    check(account({ displayName: "andres", string: "unix-user:andres", isGroup: false }) === "andres"
      && account({ displayName: " ", string: "unix-user:bob" }) === "bob", "the account polkit chose, by its name, or by its identity's")
    check(account({ displayName: "wheel", string: "unix-group:wheel", isGroup: true }) === "" && account(null) === ""
      && account(undefined) === "" && account({}) === "", "no one account: a group's, or none")
    check(PolkitModel.passwordPrompt("andres") === "Password for andres" && PolkitModel.passwordPrompt("") === "Enter password",
      "the field names whose password it asks for, or asks for a password")
    console.log("DONE")
    Qt.quit()
  }
}
