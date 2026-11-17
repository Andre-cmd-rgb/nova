.pragma library

// The power panel's rules, apart from its items: what the battery is doing,
// in one word, and what the panel shows for it (the icon, the line under
// "Battery", the four figures); and what nova-battery-info --shell and
// nova-power-profile list --active-state print. UPower's state comes in as
// a word as well: "charging", "full", "pending", or "" for any other.

// A battery in tenths, from empty to full, with a bolt and without.
var TENTHS = {
  bolt: ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"],
  bare: ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
}

// While the current flows the line under "Battery" is a phrase, turned
// every few seconds, from one set each way; else the state in a word or two.
var STATES = { charging: "Charging", spending: "On battery", held: "At charge limit", stopped: "Not charging", full: "Fully charged", topped: "Fully charged" }

// Kept short of full by a charge limit, asked while it is plugged in: a
// limit is on (Charge.limited), and UPower says it holds in one of three
// ways: pending-charge; fully-charged below 99%; or charging below 99% with
// next to nothing flowing in (0.2 W at most, or eight hours or more to go).
// The charger's own rest after a full charge is no limit's, and Charge reads
// it as full. <level> is Charge's, 0 to 1.
function held(device, state, level, limited) {
  if (!limited) return false
  var short = level < 0.99
  var trickle = Number(device.changeRate || 0) <= 0.2 || Number(device.timeToFull || 0) >= 8 * 60 * 60
  return state === "pending" || (state === "full" && short) || (state === "charging" && short && trickle)
}

// What the battery is doing: "none" without one; "held" by its limit;
// "full" by UPower's word; "spending" on the battery; and plugged in,
// "stopped" when UPower says pending-charge with no limit on (a charger too
// weak, a battery too warm), "topped" at 100%, else "charging".
function flow(device, onBattery, state, level, limited) {
  if (!device || !device.isPresent) return "none"
  if (!onBattery && held(device, state, level, limited)) return "held"
  if (state === "full") return "full"
  if (onBattery) return "spending"
  if (state === "pending") return "stopped"
  return level >= 1 ? "topped" : "charging"
}

// Full, and taking nothing in.
function still(flow) {
  return flow === "full" || flow === "topped"
}

// The battery at its tenth of <charge>: with a bolt while it charges or is
// full, without on the battery or held by its limit or stopped, which
// charge no more.
function icon(flow, charge) {
  if (flow === "none") return ""
  var tenth = flow === "full" ? 9 : Math.max(0, Math.min(9, Math.floor(charge * 10)))
  return TENTHS[flow === "held" || flow === "spending" || flow === "stopped" ? "bare" : "bolt"][tenth]
}

// The line under "Battery".
function line(flow) {
  return STATES[flow] || ""
}

// The figures under the charge bar, in reading order, each [name, value]
// from what nova-battery-info printed. Held by its limit, the limit and
// "Holding" stand where the time and the current would.
function figures(facts, flow, onBattery) {
  var quiet = still(flow) || flow === "stopped"
  var limited = flow === "held"
  return [
    ["Battery size", facts.size || ""],
    limited ? ["Charge limit", facts.threshold || "-"]
      : [onBattery ? "Time left" : "Time to full", quiet ? "-" : facts.time || "—"],
    ["Charge cycles", facts.cycles || "—"],
    limited ? ["Battery state", "Holding"]
      : [onBattery ? "Discharging" : "Charging", quiet ? "-" : facts.rate || ""]
  ]
}

// nova-battery-info --shell: a field's name, a tab and its value, a line
// each.
function fields(text) {
  var read = {}
  String(text || "").split("\n").forEach(function(line) {
    var tab = line.indexOf("\t")
    if (tab > 0) read[line.slice(0, tab)] = line.slice(tab + 1).trim()
  })
  return read
}

// nova-power-profile list --active-state: a mode, a tab, and 1 on the one in
// use, a line each.
function modes(text) {
  var read = { names: [], active: "" }
  String(text || "").split("\n").forEach(function(line) {
    var cells = line.trim().split("\t")
    if (cells[0] === "") return
    read.names.push(cells[0])
    if (cells[1] === "1") read.active = cells[0]
  })
  return read
}

function modeIcon(name) {
  switch (name) {
  case "power-saver": return "󰌪"
  case "balanced": return "󰊚"
  case "performance": return "󰓅"
  }
  return "󰂄"
}

// <index> kept among <count> entries; 0 with none.
function within(index, count) {
  return count > 0 ? Math.max(0, Math.min(count - 1, index)) : 0
}
