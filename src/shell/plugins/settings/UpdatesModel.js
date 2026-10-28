// What the Updates page says, from nova update --check's line ("available
// <version>", "apps <name>...", "current", or "" while it is asked, "error"
// when it could not be) and the run's status.json ({state, text, progress,
// version, error, restart, held, apps, failed}), and the button beside it.

var names = { "google-chrome": "Chrome", "visual-studio-code-bin": "VS Code" }

function appName(pkg) {
  return names[pkg] || String(pkg)
}

// ["google-chrome", "visual-studio-code-bin"] -> "Chrome and VS Code"
function appList(packages) {
  var out = (packages || []).filter(function (p) { return String(p).length > 0 }).map(appName)
  return out.length > 1 ? out.slice(0, -1).join(", ") + " and " + out[out.length - 1] : out.join("")
}

function sentence(text) {
  var s = String(text || "")
  return s.length > 0 ? s.charAt(0).toUpperCase() + s.slice(1) : s
}

// "running" only while the service is: one stopped from outside (killed)
// left its last word behind.
function state(status, alive) {
  var s = status && status.state ? String(status.state) : ""
  return s === "running" && !alive ? "stopped" : s
}

// {detail, action}: action is "update", "check", "restart", "retry" or "".
function summary(status, check, alive) {
  var s = state(status, alive)
  if (s === "running") return { detail: (status.text || "Updating") + "…", action: "" }
  if (s === "failed") return { detail: "The update did not finish: " + (status.error || "it failed") + ".", action: "retry" }
  if (s === "stopped") return { detail: "The update stopped before it finished.", action: "retry" }
  if (s === "done" && status.restart === true) return { detail: "Restart to finish the update.", action: "restart" }

  var line = String(check || "")
  if (line === "") return { detail: "Checking for updates…", action: "" }
  if (line.indexOf("available ") === 0) return { detail: "Nova " + line.slice(10) + " is available.", action: "update" }
  if (line.indexOf("apps ") === 0) return { detail: "Updates for " + appList(line.slice(5).split(" ")) + " are available.", action: "update" }
  if (line === "current") return { detail: "Nova and its apps are up to date.", action: "check" }
  return { detail: "Could not check for updates.", action: "check" }
}

// The bar's fill, 0 to 1, or -1 while how far is not known.
function fraction(status) {
  var p = Number(status && status.progress)
  return isFinite(p) && p >= 0 ? Math.min(1, p / 100) : -1
}

// What a run left undone, after it ended: apps that did not build or go in.
function leftOver(status, alive) {
  var s = state(status, alive)
  if (s !== "done" && s !== "failed") return ""
  var failed = status.failed || []
  return failed.length > 0 ? appList(failed) + (failed.length > 1 ? " were" : " was") + " not updated." : ""
}

// The release a check found, for its notes.
function availableVersion(check) {
  var line = String(check || "")
  return line.indexOf("available ") === 0 ? line.slice(10) : ""
}

// `nova apps install --review` prints "commit <hash>" first, then the change.
function reviewCommit(text) {
  var m = /^commit ([0-9a-f]{40,64})\n/.exec(String(text || ""))
  return m ? m[1] : ""
}

function reviewBody(text) {
  return String(text || "").replace(/^commit [0-9a-f]{40,64}\n/, "")
}

// The run a reviewed recipe gets: that app alone, at that commit.
function approveCommand(pkg, commit) {
  return ["nova-update-run", "--apps-only", "--only", pkg, "--approve", pkg + "=" + commit]
}

// The last lines of the log, which is all a glance needs.
function tail(text, lines) {
  var all = String(text || "").replace(/\n$/, "").split("\n")
  return all.slice(Math.max(0, all.length - lines)).join("\n")
}
