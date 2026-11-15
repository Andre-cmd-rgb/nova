// The options a ButtonGroup or a Dropdown offers: each is a string, which is
// both what it sets and what it shows, or a { value, label } object, which
// shows its label, or its value when it has none.
.pragma library

function valueOf(option) {
  return String(option !== null && typeof option === "object" ? option.value : option)
}

function labelOf(option) {
  if (option === null || typeof option !== "object") return String(option)
  return String(option.label ?? option.value)
}

// Where the option setting <value> is in <options>; -1 if none does.
function find(options, value) {
  return (options || []).findIndex(option => valueOf(option) === value)
}
