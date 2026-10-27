// What the Performance page's readout says, from `nova-power status --json`:
// the governor's figures in words. A figure the computer does not give is
// null there and left out here.

var tiers = {
  light: "Light, for reading and video",
  mid: "Mid, for work that keeps going",
  full: "Full, for a build or an export",
  turbo: "Turbo, for a long hard job"
}

var fanOwners = {
  auto: "the firmware's curve",
  held: "held quiet by the governor",
  "ec/hot": "the firmware's, as the processor is hot",
  "ec/blind": "the firmware's, with no temperature to go by",
  ec: "the firmware's"
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
  var text = head + (parts.length > 0 ? ": " + parts.join(", ") : "")
  if (info.boost === true && info.source !== "ac") text += ". A boost has lifted the battery's limits"
  return text + "."
}

function fans(info) {
  var g = info.governor || {}
  var parts = []
  if (known(info.fanRpm)) parts.push(info.fanRpm > 0 ? info.fanRpm + " rpm" : "Still")
  if (fanOwners[g.fans]) parts.push(fanOwners[g.fans])
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
