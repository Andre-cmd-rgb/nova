// What the Performance page's readout says, from `nova-power status --json`:
// the governor's figures in words. A figure the computer does not give is
// null there and left out here.

var tiers = { light: "Light", mid: "Mid", full: "Full", turbo: "Turbo" }

// Whose the fans are: a level of Nova's curve, 0 (still) to 7 or full, or
// the firmware's, with or without a temperature to go by. Nova's is the
// usual, and goes without saying.
var fanOwners = {
  full: "full speed",
  "ec/blind": "set by the firmware, no temperature reading",
  ec: "set by the firmware"
}

function fanOwner(fans) {
  if (/^[1-7]$/.test(String(fans))) return "level " + fans + " of 7"
  return fanOwners[fans] || ""
}

function known(value) {
  return value !== null && value !== undefined
}

function watts(value) {
  return (value >= 10 ? value.toFixed(0) : value.toFixed(1)) + " W"
}

function processor(info) {
  var g = info.governor || {}
  var parts = []
  if (known(g.busy)) parts.push(g.busy + "% busy")
  if (known(g.temp)) parts.push(g.temp + " °C")
  if (known(g.watts)) parts.push(watts(g.watts))
  return parts.join(", ")
}

function limits(info) {
  var g = info.governor || {}
  var parts = []
  if (known(info.pl1)) parts.push(info.pl1 + " W sustained")
  if (known(info.pl2)) parts.push(info.pl2 + " W in bursts")
  if (known(info.ceiling) && info.ceiling < 100) parts.push("up to " + info.ceiling + "% speed")
  if (info.turbo === false) parts.push("no turbo")
  var head = info.source === "ac" ? "Plugged in" : (tiers[g.tier] || "On battery")
  if (info.boost === true && info.source !== "ac") head += ", boosted"
  return head + (parts.length > 0 ? ": " + parts.join(", ") : "")
}

function fans(info) {
  var g = info.governor || {}
  var parts = []
  if (known(info.fanRpm) && info.fanRpm > 0) parts.push(info.fanRpm + " rpm")
  else if (known(info.fanRpm) || g.fans === "0") parts.push("Still")
  if (fanOwner(g.fans)) parts.push(fanOwner(g.fans))
  return parts.join(", ")
}

// The whole computer's draw, which only the battery reports, and only while
// it is the one supplying it.
function battery(info) {
  return info.source === "battery" && info.batteryWatts > 0 ? watts(info.batteryWatts) + " from the battery" : ""
}

if (typeof module !== "undefined") {
  module.exports = { processor: processor, limits: limits, fans: fans, battery: battery }
}
