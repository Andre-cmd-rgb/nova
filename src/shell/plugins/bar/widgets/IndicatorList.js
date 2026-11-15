.pragma library
.import "../BarModel.js" as BarModel

// Which indicators the indicators widget lists, and in what order it lights
// those that are on, apart from Qt.

const every = ["ScreenRecording", "NightLight", "Dnd", "Caffeine"]
// Stay Awake and Lid Awake became one Caffeine indicator: a layout naming
// either gets it, once.
const renamed = { StayAwake: "Caffeine", LidAwake: "Caffeine" }

// The widget's entries: those its settings name under `items`, or under
// `indicators`, the older name, or else every indicator. An entry that is
// an object is a copy, so the widget never holds on to the layout's own.
function entries(settings) {
  const named = some(settings.items) || some(settings.indicators) || every
  const out = []
  for (let i = 0; i < named.length; i++) {
    let entry = copied(named[i])
    const id = BarModel.entryId(entry)
    if (Object.prototype.hasOwnProperty.call(renamed, id)) {
      entry = renamed[id]
      if (out.some(other => BarModel.entryId(other) === entry)) continue
    }
    if (BarModel.entryId(entry) !== "") out.push(entry)
  }
  return out
}

// A list with something in it, or null.
function some(value) {
  return value && typeof value.length === "number" && value.length > 0 ? value : null
}

function copied(entry) {
  if (entry === null || typeof entry !== "object") return entry
  try {
    return JSON.parse(JSON.stringify(entry))
  } catch (error) {
    return entry
  }
}

// <states>, the ids on, with <id> turned on or off.
function turned(states, id, on) {
  const next = {}
  for (const key in states) {
    if (states[key] === true) next[key] = true
  }
  if (on) next[id] = true
  else delete next[id]
  return next
}

// The order of the lit ones: <order> as it was, but for those no longer on
// or listed in <ids>, and <newcomer> first when it is on, listed and new:
// added last, it would push those lit sideways, as the lit end is the one
// nearest the centre.
function lit(order, states, ids, newcomer) {
  const kept = []
  for (const id of order) {
    if (!kept.includes(id) && ids.includes(id) && states[id] === true) kept.push(id)
  }
  if (newcomer && !kept.includes(newcomer) && ids.includes(newcomer)) kept.unshift(newcomer)
  return kept
}
