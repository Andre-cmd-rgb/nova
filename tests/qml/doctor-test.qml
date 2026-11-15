import QtQuick
import Quickshell
import "plugins/settings" as Settings

ShellRoot {
  id: test
  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }
  Settings.DoctorView { id: doctor; width: 600 }
  Component.onCompleted: Qt.callLater(function () {
    doctor.readResults('[{"level":"FAIL","what":"Read-only","how":["Back up","Check disk"]},{"level":"warn","what":"Clock","how":[]}]', 1)
    check(doctor.results.length === 2 && doctor.results[0].how.length === 2 && doctor.failure === "", "a failing diagnosis still displays each check and repair")
    doctor.readResults('[{"level":"ok","what":"Healthy","how":[]}]', 0)
    check(doctor.results.length === 1 && doctor.results[0].level === "ok", "another run replaces previous results")
    doctor.readResults("bad output", 127)
    check(doctor.failure.length > 0, "a command failure has a visible explanation")
    doctor.readResults('[{"level":"unknown","what":"Bad","how":[]}]', 0)
    check(doctor.failure.length > 0, "invalid verdicts do not become result rows")
    console.log("DONE")
    Qt.quit()
  })
}
