.pragma library

var fingers = [
  "right-index-finger", "right-thumb", "right-middle-finger", "right-ring-finger", "right-little-finger",
  "left-thumb", "left-index-finger", "left-middle-finger", "left-ring-finger", "left-little-finger"
]

function label(finger) {
  var name = finger.replace(/-finger$/, "").replace(/-/g, " ")
  return name.charAt(0).toUpperCase() + name.slice(1)
}

function enrolled(text) {
  var found = []
  String(text).split(/\r?\n/).forEach(function (line) {
    var match = /^\s*-\s*#\d+:\s*([a-z-]+)\s*$/.exec(line)
    if (match && fingers.indexOf(match[1]) >= 0 && found.indexOf(match[1]) < 0)
      found.push(match[1])
  })
  return found
}

function device(text) {
  var match = /^o "(\/net\/reactivated\/Fprint\/Device\/[0-9]+)"\s*$/.exec(String(text).trim())
  return match ? match[1] : ""
}

function stages(text) {
  var match = /^i ([1-9][0-9]*)$/.exec(String(text).trim())
  return match ? Number(match[1]) : 0
}

function deleteCommand(finger, single) {
  // Older fprintd can only remove them all. Never try a single-finger flag
  // unless its own help advertised it, and make the confirmation say all.
  var command = ["sh", "-c", 'exec fprintd-delete "$(id -un)" "$@"', "nova-fingerprint-delete"]
  return single ? command.concat(["-f", finger]) : command
}
