.pragma library

// The changes asked of Settings and not read back yet, laid over what was
// read (SettingsState). A change names what it sets by its path in
// `nova-settings state`, "bar.transparent" or "battery.limit.on", and the
// value it sets there; an array's place is a number, "displays.displays.0".
// What is laid over is copied along each path alone: everything else stays
// the very object that was read.

// <read> with each change in <asked> ({path, value}, in the order asked) set.
function over(read, asked) {
  var out = read
  for (var i = 0; i < asked.length; i++)
    out = put(out, String(asked[i].path).split("."), 0, asked[i].value)
  return out
}

function put(node, keys, at, value) {
  if (at === keys.length) return value
  var copy = Array.isArray(node) ? node.slice()
    : Object.assign({}, node !== null && typeof node === "object" ? node : {})
  copy[keys[at]] = put(copy[keys[at]], keys, at + 1, value)
  return copy
}

// What a view says it sets, by paths in the part of the state it was given,
// as paths in the whole state: under <path>. Nothing stays nothing.
function under(path, changes) {
  if (!changes) return null
  var out = {}
  for (var key in changes) out[path + "." + key] = changes[key]
  return out
}
