.pragma library

// The power panel's rules, apart from its items: what UPower's battery shows
// as an icon and a level, when a charge limit is holding it, and what
// nova-battery-info --shell and nova-power-profile list --active-state print.
// `states` holds UPowerDeviceState's values the rules compare against.

var chargingIcons = ["󰢜", "󰂆", "󰂇", "󰂈", "󰢝", "󰂉", "󰢞", "󰂊", "󰂋", "󰂅"]
var batteryIcons = ["󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]

// The charge from 0 to 1, or 0 with no battery.
function level(device) {
  if (!device || !device.isPresent) return 0
  return Math.max(0, Math.min(1, device.percentage))
}

// Plugged in and kept short of full by a charge limit. UPower says so in
// three ways: pending-charge; fully-charged below 99%; or charging below 99%
// with next to nothing flowing in (0.2 W at most, or eight hours or more to
// go).
function holding(device, onBattery, states) {
  if (!device || !device.isPresent || onBattery) return false
  var s = states || {}
  var charge = level(device)
  switch (device.state) {
  case s.PendingCharge:
    return true
  case s.FullyCharged:
    return charge < 0.99
  case s.Charging:
    if (charge >= 0.99) return false
    return Number(device.changeRate || 0) <= 0.2 || Number(device.timeToFull || 0) >= 8 * 60 * 60
  }
  return false
}

// A battery in tenths; one with a bolt while it charges. A battery held by
// its limit charges no more, so it shows without; a full one is full.
function icon(device, onBattery, states) {
  if (!device || !device.isPresent) return ""
  var tenth = Math.max(0, Math.min(9, Math.floor(device.percentage * 10)))
  if (holding(device, onBattery, states)) return batteryIcons[tenth]
  if (device.state === states.FullyCharged) return "󰂅"
  return onBattery ? batteryIcons[tenth] : chargingIcons[tenth]
}

// The state in a word or two, for when no phrase turns: only while the
// battery is plugged in and charges no more, held by its limit or full.
function mode(device, onBattery, states) {
  if (!device || !device.isPresent) return ""
  return holding(device, onBattery, states) ? "Threshold" : "Fully charged"
}

// nova-battery-info --shell: a field's name, a tab and its value, a line
// each.
function fields(text) {
  var found = {}
  String(text || "").split("\n").forEach(function(line) {
    var tab = line.indexOf("\t")
    if (tab > 0) found[line.substring(0, tab)] = line.substring(tab + 1).trim()
  })
  return found
}

// nova-power-profile list --active-state: a mode, a tab, and 1 on the one in
// use, a line each.
function modes(text) {
  var names = []
  var active = ""
  String(text || "").split("\n").forEach(function(line) {
    line = line.trim()
    if (line === "") return
    var parts = line.split("\t")
    names.push(parts[0])
    if (parts[1] === "1") active = parts[0]
  })
  return { names: names, active: active }
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
