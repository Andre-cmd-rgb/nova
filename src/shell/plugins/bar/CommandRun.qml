import QtQuick
import Quickshell.Io
import qs.Ui

// One user command (CommandWidget), run with `bash -l` every <interval>
// seconds while a copy of its widget holds it, and once as the first comes:
// <output> is what it last printed, which every copy shows.
BarWidgetService {
  id: run

  required property string exec
  required property real interval

  property string output: ""

  Process {
    id: job
    command: ["bash", "-lc", run.exec]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: run.output = text
    }
  }

  Timer {
    interval: run.interval * 1000
    running: run.wanted && run.exec !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!job.running) job.running = true
  }
}
