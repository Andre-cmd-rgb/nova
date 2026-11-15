// The service's arithmetic, apart from the Wayland it watches.

function pad(n) { return (n < 10 ? "0" : "") + n }

// The hour seconds are written to, as `screentime record` takes it after an
// @: 2026-10-24T09, in local time like the day files.
function hourOf(date) {
  return date.getFullYear() + "-" + pad(date.getMonth() + 1) + "-" + pad(date.getDate()) + "T" + pad(date.getHours())
}

// Seconds of an app taken back, newest first: from what is still pending,
// then from what each write made after `after` (epoch seconds) put in its
// hour. Gives the pending left, the writes left, and the negative pairs for
// the hours already written. Nothing is changed in place: these live in QML
// var properties.
function takeBack(pending, written, app, seconds, after) {
  var left = seconds
  var nextPending = ({})
  for (var key in pending) nextPending[key] = pending[key]
  var held = Math.min(left, Math.max(0, nextPending[app] || 0))
  if (held > 0) nextPending[app] -= held
  left -= held

  var nextWritten = []
  var pairs = []
  for (var i = 0; i < written.length; i++) {
    var write = { time: written[i].time, hour: written[i].hour, seconds: ({}) }
    for (var name in written[i].seconds) write.seconds[name] = written[i].seconds[name]
    var take = write.time > after ? Math.min(left, write.seconds[app] || 0) : 0
    if (take > 0) {
      write.seconds[app] -= take
      left -= take
      pairs.push(app + "=" + (-take) + "@" + write.hour)
    }
    nextWritten.push(write)
  }
  return { pending: nextPending, written: nextWritten, pairs: pairs }
}
