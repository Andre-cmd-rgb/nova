pragma Singleton
import QtQuick
import Quickshell.Io

// The radios' switches as `rfkill event` says them: a line for each switch
// as it starts, then a line at each change ("idx 0 type 2 op 2 soft 1 hard
// 0"). One watch for the whole shell, running while something holds it: the
// bar's Bluetooth on each screen, Mobile Data while it waits on a radio,
// Settings' Bluetooth page. `rfkill event` sleeps on /dev/rfkill between
// changes, so a watch costs a process and no wakeups.
QtObject {
  id: rfkill

  // The kernel's types of switch that the shell reads.
  readonly property int bluetooth: 2
  readonly property int wwan: 5

  // { idx: { type, soft, hard } }, every switch the watch has said, a new
  // object at each change; none while it is not running.
  property var switches: ({})
  // Each switch as it comes, changes (op 0, 2 or 3) or goes (op 1):
  // { idx, type, op, soft, hard }.
  signal heard(var change)

  // How many hold the watch. Let go a turn later, so that a bar built again
  // (every widget made anew) does not stop it and start it again.
  property int holds: 0

  function hold() {
    holds++
    keep()
  }

  function release() {
    Qt.callLater(function () {
      if (rfkill.holds > 0) rfkill.holds--
      rfkill.keep()
    })
  }

  // { idx: blocked } for the switches of <type>, blocked by software or by
  // a hardware switch.
  function blocked(type) {
    const found = {}
    for (const idx in switches) {
      const one = switches[idx]
      if (one.type === type) found[idx] = one.soft || one.hard
    }
    return found
  }

  // The switches as lines of the watch, op 0, as it says them when it
  // starts: for one that begins to listen while the watch already runs.
  function lines() {
    return Object.keys(switches).map(idx => "idx " + idx + " type " + switches[idx].type + " op 0 soft "
      + (switches[idx].soft ? 1 : 0) + " hard " + (switches[idx].hard ? 1 : 0))
  }

  function take(line) {
    const found = /idx (\d+) type (\d+) op (\d+) soft (\d+) hard (\d+)/.exec(String(line))
    if (!found) return
    const change = { idx: found[1], type: Number(found[2]), op: Number(found[3]), soft: found[4] === "1", hard: found[5] === "1" }
    const next = Object.assign({}, switches)
    if (change.op === 1) delete next[change.idx]
    else next[change.idx] = { type: change.type, soft: change.soft, hard: change.hard }
    switches = next
    heard(change)
  }

  // Started and stopped by the holds alone: a watch that ends by itself (no
  // /dev/rfkill) is not started again until the holds change.
  function keep() {
    if (holds > 0 && !watch.running) watch.running = true
    else if (holds === 0 && watch.running) watch.running = false
  }

  property Process watch: Process {
    command: ["rfkill", "event"]
    stdout: SplitParser {
      onRead: line => rfkill.take(line)
    }
    // Stopped, it knows nothing until it starts again and says them all.
    onRunningChanged: if (!running) rfkill.switches = ({})
  }
}
