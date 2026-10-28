import QtQuick
import Quickshell
import "plugins/settings" as Settings
import "plugins/settings/Fingerprints.js" as Fingerprints

ShellRoot {
  id: test
  property int saves: 0
  property bool waitForCancellation: false

  // No fingerprint service is contacted. Only this harmless line producer
  // runs; the other checks feed the same parser with recorded result lines.
  Settings.FingerprintSheet {
    id: sheet
    width: 700
    height: 500
    stages: 9
    function commandForFinger() {
      if (test.waitForCancellation) return ["sleep", "10"]
      return ["sh", "-c", "printf 'Enroll result: enroll-stage-passed\\nEnroll result: enroll-retry-scan\\nEnroll result: enroll-completed\\n'"]
    }
    onSaved: {
      test.saves++
      check(completed && acceptedTouches === 9 && progress === 1, "line-buffered process output completes the sheet")
      check(test.saves === 1, "completion reports one saved fingerprint")
      cancel()
      test.waitForCancellation = true
      open()
      start()
      cancelSoon.start()
    }
  }

  Settings.FingerprintSheet { id: realCommand; width: 700; height: 500 }
  Settings.FingerprintSettings { id: section; active: false; width: 600 }

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  Component.onCompleted: Qt.callLater(function () {
    check(Fingerprints.device('o "/net/reactivated/Fprint/Device/3"\n') === "/net/reactivated/Fprint/Device/3", "default device comes from the bus, with no fixed device index")
    check(Fingerprints.stages("i 9\n") === 9 && Fingerprints.stages("i 0") === 0 && Fingerprints.stages("unavailable") === 0, "progress uses a valid stage count")
    var list = "found 1 devices\nUsing device /net/reactivated/Fprint/Device/0\nFingerprints for user test:\n - #0: right-index-finger\n - #1: left-thumb\n - #2: left-thumb\n - #3: invalid\n"
    check(JSON.stringify(Fingerprints.enrolled(list)) === '["right-index-finger","left-thumb"]', "enrolled fingers are parsed, checked and deduplicated")
    check(Fingerprints.enrolled("No fingers enrolled").length === 0, "an empty enrolment list stays empty")
    check(Fingerprints.label("right-index-finger") === "Right index", "finger names stay short")
    var one = Fingerprints.deleteCommand("left-thumb", true)
    var all = Fingerprints.deleteCommand("left-thumb", false)
    check(one[2].indexOf('"$@"') >= 0 && JSON.stringify(one.slice(-2)) === '["-f","left-thumb"]', "single-finger deletion passes the finger as a literal argument")
    check(all.length === 4 && all.indexOf("-f") < 0, "older fprintd deletes all only after the all-fingers confirmation")
    realCommand.finger = "right-index-finger"
    check(JSON.stringify(realCommand.commandForFinger()) === '["stdbuf","-oL","-eL","fprintd-enroll","-f","right-index-finger"]', "enrolment runs directly with immediate line output")

    sheet.open()
    check(sheet.finger === "right-index-finger", "right index is the first choice")
    sheet.enrolled = ["right-index-finger"]
    sheet.open()
    check(sheet.available.indexOf("right-index-finger") < 0 && sheet.finger === "right-thumb", "already enrolled fingers cannot be overwritten")
    sheet.enrolling = true
    sheet.acceptLine("Enroll result: enroll-stage-passed")
    check(sheet.acceptedTouches === 1 && sheet.progress === 1 / 9, "one accepted touch advances one stage")
    var retries = ["enroll-retry-scan", "enroll-swipe-too-short", "enroll-finger-not-centered", "enroll-remove-and-retry", "enroll-too-fast"]
    var hints = ["Lift your finger and touch again", "Too short", "Centre your finger", "Lift your finger and touch again", "Touch more slowly"]
    for (var i = 0; i < retries.length; i++) {
      sheet.acceptLine("Enroll result: " + retries[i])
      check(sheet.hint === hints[i] && sheet.acceptedTouches === 1, retries[i] + " keeps progress and gives a hint")
    }
    sheet.acceptLine("Enroll result: enroll-duplicate")
    check(!sheet.enrolling && sheet.error === "This finger is already added.", "a duplicate is a short, recoverable error")
    sheet.cancel()
    sheet.acceptLine("Enroll result: enroll-completed")
    check(!sheet.completed && saves === 0, "late lines after cancellation cannot save a fingerprint")
    sheet.open()
    sheet.enrolling = true
    sheet.finish(0)
    check(!sheet.completed && sheet.error === "The fingerprint was not saved.", "exit zero without enroll-completed is not success")
    sheet.open()
    sheet.start()
  })

  Timer {
    id: cancelSoon
    interval: 100
    onTriggered: {
      sheet.cancel()
      check(!sheet.opened && !sheet.enrolling, "cancel closes the sheet and stops enrolment")
      verifyStopped.start()
    }
  }
  Timer {
    id: verifyStopped
    interval: 200
    onTriggered: {
      check(test.saves === 1 && !sheet.completed && sheet.error === "", "a cancelled process exit neither saves nor shows an error")
      console.log("DONE")
      Qt.quit()
    }
  }
}
