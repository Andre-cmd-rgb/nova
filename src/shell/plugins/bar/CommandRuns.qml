import QtQuick

// The users' commands (CommandWidget), each run once for every screen's copy
// of its widget: a run (CommandRun) for each command and interval, made as
// its first copy comes and gone a turn after its last, so that a bar built
// again keeps the runs it still has.
Item {
  id: commands
  visible: false

  // { "<interval> <exec>": CommandRun }
  property var runs: ({})

  // The run of <exec> every <interval> seconds, held by <holder>.
  function hold(holder, exec, interval) {
    const key = interval + " " + exec
    let run = runs[key]
    if (!run) {
      run = made.createObject(commands, { exec: exec, interval: interval })
      runs = Object.assign({}, runs, { [key]: run })
    }
    run.hold(holder)
    return run
  }

  function release(holder, run) {
    run.release(holder)
    Qt.callLater(commands.sweep)
  }

  function sweep() {
    const kept = {}
    for (const key in runs) {
      if (runs[key].holders.length > 0) kept[key] = runs[key]
      else runs[key].destroy()
    }
    runs = kept
  }

  Component {
    id: made
    CommandRun {}
  }
}
