// What the Performance page says about the CPU's undervolt, from `nova power
// undervolt status --json` ({core, cache, state, reason, intel}), and the
// command a change of depth runs. Offsets are whole millivolts, 0 or below.

function mv(offset) {
  return offset === 0 ? "None" : "−" + Math.abs(offset) + " mV"
}

// "−70 mV on the core and cache", or "−80 mV on the core, −70 mV on the cache".
function describe(core, cache) {
  if (core === cache) return mv(core) + " on the core and cache"
  function part(offset) { return offset === 0 ? "none" : mv(offset) }
  return part(core) + " on the core, " + part(cache) + " on the cache"
}

function isSet(undervolt) {
  return !!undervolt && undervolt.core !== null && undervolt.core !== undefined
}

function headline(undervolt) {
  if (!isSet(undervolt)) return "No undervolt"
  var what = describe(undervolt.core, undervolt.cache)
  if (undervolt.state === "applied") return what
  if (undervolt.state === "held") return "Held: " + what
  return "Set: " + what
}

// Only what needs saying: why it is held, or that it is not on.
function detail(undervolt) {
  if (!undervolt || undervolt.state === "held") {
    var why = String((undervolt && undervolt.reason) || "")
    return why.length > 0 ? why.charAt(0).toUpperCase() + why.slice(1) + "." : ""
  }
  if (undervolt.state === "pending") return "Not on the CPU in this boot."
  return ""
}

// Whether the sliders' depths are not what is set.
function changed(undervolt, core, cache) {
  if (!isSet(undervolt)) return core !== 0 || cache !== 0
  return core !== undervolt.core || cache !== undervolt.cache
}

function applyCommand(core, cache) {
  if (core === 0 && cache === 0) return ["nova-power-undervolt", "off"]
  return ["nova-power-undervolt", "set", String(core), String(cache)]
}
