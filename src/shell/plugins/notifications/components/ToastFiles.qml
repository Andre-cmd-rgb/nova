import QtQuick
import Quickshell.Io
import "../NotificationLogic.js" as Notes

// The toasts' files, which files.sh keeps under `folder`: a file for each
// toast on screen, the history's, and the copies of their pictures. The jobs
// run one at a time in the order asked, so that a run of updates does not
// race and a removal asked after a write comes after it; a read takes its
// turn too, and sees the files as they were when it was asked for.
Item {
  id: files

  required property string script
  // $XDG_STATE_HOME/nova/notifications/, with its slash.
  required property string folder
  readonly property string history: folder + "history/"
  readonly property string images: folder + "images/"
  // The history's length.
  readonly property int keep: 10

  // The jobs waiting, each { args, reads, done }: done() after a write,
  // done(text) with what a read read.
  property var waiting: []
  property bool busy: false

  function add(args, done, reads) {
    waiting = waiting.concat([{ args: args, done: done || null, reads: !!reads }])
    pump()
  }

  function pump() {
    if (busy || waiting.length === 0) return
    var job = waiting[0]
    waiting = waiting.slice(1)
    busy = true
    var worker = job.reads ? reader : writer
    worker.job = job
    worker.command = ["bash", script].concat(job.args)
    worker.running = true
  }

  function finished() {
    busy = false
    pump()
  }

  Process {
    id: writer
    property var job: null
    onExited: {
      try {
        if (job.done) job.done()
      } catch (e) {
        console.warn("notifications: what follows a file job failed:", e)
      }
      files.finished()
    }
  }

  // The next job waits for the read to end, whatever it read.
  Process {
    id: reader
    property var job: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: reader.job.done(text)
    }
    onExited: files.finished()
  }

  // A row's pictures as files.sh copies them: from, to, and so on.
  function withCopies(args, copies) {
    return copies.reduce((all, copy) => all.concat([copy.from, copy.to]), args)
  }

  // A toast's file, written as it shows and as it changes, the copies of its
  // pictures made first, while the sender's are still there.
  function write(row) {
    var disk = Notes.forDisk(row, images)
    add(withCopies(["show", folder, images, Notes.fileName(row), Notes.line(disk.entry)], disk.copies))
  }

  // A toast's file gone, with its copies.
  function drop(row) {
    add(["forget", folder, images, Notes.stem(row)])
  }

  // A toast's file into the history, as it leaves the screen.
  function retire(row) {
    add(["archive", folder, history, images, Notes.fileName(row), String(keep)])
  }

  // Straight into the history, as a toast gone would be.
  function record(row, done) {
    var disk = Notes.forDisk(row, images)
    add(withCopies(["record", history, images, Notes.fileName(row), Notes.line(disk.entry), String(keep)], disk.copies), done)
  }

  // The copies no file names, and those a restart cut short.
  function sweep() {
    add(["sweep", folder, history, images])
  }

  function readToasts(done) {
    add(["read", folder], done, true)
  }

  function readHistory(done) {
    add(["read", history], done, true)
  }

  Process {
    id: makeFolders
  }

  function prepare(stateDir) {
    makeFolders.command = ["mkdir", "-p", stateDir, folder, history, images]
    makeFolders.running = true
  }
}
