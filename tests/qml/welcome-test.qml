// stub: bin/nova-settings nova-settings
// stub: bin/nova-welcome record
// stub: bin/nova-update-run record
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/settings" as Settings
import "plugins/settings/WelcomeModel.js" as Model

// The welcome: which pages come, and when; Chrome and VS Code in its words;
// the wordmark read from its text; and the window gone through with
// Continue and Back, which takes the account's marker away as it closes.
// There is no bus here, so no network: the Wi-Fi page is there for a card.
ShellRoot {
  id: test

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function same(got, want, what) {
    const ok = JSON.stringify(got) === JSON.stringify(want)
    check(ok, what + (ok ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  // The pages one Continue after another, from the first.
  function walk(facts) {
    const out = ["welcome"]
    for (let next = Model.next("welcome", facts); next !== ""; next = Model.next(next, facts)) out.push(next)
    return out
  }

  // Waits for <done> to hold, then calls <then>; fails <what> after 5 s.
  function when(done, then, what) {
    waiter.done = done
    waiter.then = then
    waiter.what = what
    waiter.left = 50
    waiter.start()
  }

  Timer {
    id: waiter
    property var done: null
    property var then: null
    property string what: ""
    property int left: 0
    interval: 100
    repeat: true
    onTriggered: {
      if (done()) {
        stop()
        then()
      } else if (--left <= 0) {
        stop()
        test.check(false, what)
        test.finish()
      }
    }
  }

  FileView {
    id: stateFile
    path: Quickshell.env("HOME") + "/settings-state.json"
    printErrors: false
    blockWrites: true
  }

  FileView {
    id: calls
    path: Quickshell.env("HOME") + "/stub-calls"
    printErrors: false
    blockLoading: true
  }

  Settings.Welcome { id: welcome }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    const both = ["google-chrome", "visual-studio-code-bin"]
    // An install over the network, on a laptop with Wi-Fi: nothing to fetch.
    same(walk({ loaded: true, wifi: true, online: true, nightlight: true, missing: [] }),
      ["welcome", "look", "nightlight", "keys"], "online, with the apps: the look, the night light and the keys")
    // From a stick with every package, and no network yet.
    same(walk({ loaded: true, wifi: true, online: false, nightlight: true, missing: both }),
      ["welcome", "wifi", "look", "nightlight", "keys"], "offline: the Wi-Fi first, and no apps to fetch without it")
    // Joined on the Wi-Fi page: the apps come after all.
    same(Model.next("nightlight", { wifi: true, online: true, nightlight: true, missing: both }), "apps", "a network joined on the way brings the apps")
    same(walk({ loaded: true, wifi: true, portal: true, nightlight: true, missing: both }),
      ["welcome", "look", "nightlight", "keys"], "a network that wants a sign-in is no Wi-Fi page, and no internet yet")
    same(walk({ loaded: true, wifi: false, online: false, nightlight: false, missing: both }),
      ["welcome", "look", "keys"], "a desktop offline with no Wi-Fi card, the night light switched off: nothing to join")
    same(walk({ loaded: true, wifi: true, laptop: true, online: true, onWifi: false, missing: [] }),
      ["welcome", "wifi", "look", "keys"], "a laptop installed on a cable, still on it: a Wi-Fi network for when it is out")
    same(walk({ loaded: true, wifi: true, laptop: true, online: true, onWifi: true, missing: [] }),
      ["welcome", "look", "keys"], "a laptop on its Wi-Fi: nothing to join")
    same(walk({ loaded: true, wifi: true, laptop: false, online: true, onWifi: false, missing: [] }),
      ["welcome", "look", "keys"], "a desktop on a cable with a Wi-Fi card: the cable is its network")
    same(walk({ online: false, installing: true, missing: [] }), ["welcome", "look", "apps", "keys"], "an install of the apps going on keeps their page")
    same(Model.next("keys", {}), "", "nothing after the keys")

    same(Model.missing({ browsers: ["chrome"], editors: ["code", "nvim"] }), [], "Chrome and VS Code there: none missing")
    same(Model.missing({ browsers: ["firefox"], editors: ["code"] }), ["google-chrome"], "Chrome missing alone")
    same(Model.missing({ browsers: [], editors: [] }), both, "both missing")
    same(Model.missing(undefined), [], "nothing known before the state is read")

    same(Model.apps("", {}, both), { detail: "Not installed", action: "install" }, "not installed: Install")
    same(Model.apps("running", { text: "Building Chrome" }, both), { detail: "Building Chrome…", action: "" }, "while it installs, what it does")
    same(Model.apps("done", {}, []), { detail: "Installed", action: "" }, "in")
    same(Model.apps("failed", { error: "not authorized to install updates" }, both),
      { detail: "Could not install: not authorized to install updates.", action: "retry" }, "refused: why, and Try Again")
    same(Model.apps("problems", { failed: ["google-chrome"] }, ["google-chrome"]), { detail: "Could not install.", action: "retry" }, "an app that did not build: Try Again")
    same(Model.apps("cancelled", {}, both), { detail: "Not installed", action: "install" }, "the password not given: Install again")

    // Two lines of half blocks: a spark right of where the bottom row ends.
    const art = Model.wordmark("   █\n██ ▀\n▀▀\n")
    same([art.columns, art.rows], [4, 5], "the wordmark's size in pixels, two rows a line, the empty last row dropped")
    same(art.runs, [
      { x: 3, y: 0, length: 1, spark: true }, { x: 3, y: 1, length: 1, spark: true },
      { x: 0, y: 2, length: 2, spark: false }, { x: 3, y: 2, length: 1, spark: true },
      { x: 0, y: 3, length: 2, spark: false }, { x: 0, y: 4, length: 2, spark: false }
    ], "its pixels in runs, the spark apart")
    same(Model.wordmark(""), { columns: 0, rows: 0, runs: [] }, "no text, no wordmark")

    // The window: a laptop with a Wi-Fi card, offline, Chrome and VS Code in.
    stateFile.setText(JSON.stringify({ radios: ["wlan"], apps: { browsers: ["chrome"], editors: ["code"] },
      appearance: { theme: "white", themes: [], backgrounds: 1 } }))
    welcome.open("")
    check(welcome.page === "welcome" && welcome.history.length === 0, "it opens on the first page")
    welcome.forward()
    when(() => welcome.page === "wifi", afterWifi, "Continue, pressed before the state was read, goes on once it is")
  }

  function afterWifi() {
    check(welcome.history.length === 1, "the Wi-Fi page next, with no network")
    welcome.back()
    check(welcome.page === "welcome" && welcome.history.length === 0, "Back goes to the first page")
    welcome.forward()
    welcome.forward()
    check(welcome.page === "look", "then the look")
    welcome.forward()
    check(welcome.page === "keys" && welcome.last, "no night light without its service, no apps without the internet: the keys, last")
    welcome.forward()
    when(() => { calls.reload(); return calls.text().indexOf("nova-welcome done") >= 0 }, () => {
      check(true, "Done closes it, and the account is done with it")
      welcome.open(JSON.stringify({ page: "keys" }))
      check(welcome.page === "keys", "opened again on the page asked for")
      finish()
    }, "Done closes it, and the account is done with it")
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }
}
