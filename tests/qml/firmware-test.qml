import QtQuick
import Quickshell
import "plugins/settings" as Settings

ShellRoot {
  id: test
  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }
  Settings.FirmwareView { id: firmware; monitor: false; width: 600 }
  Component.onCompleted: Qt.callLater(function () {
    firmware.readState('{"running":true,"action":"install","devices":[{"id":"abc","name":"BIOS","current":"1","version":"2","summary":"Fixes","status":"installing","progress":42}]}')
    check(firmware.busy && firmware.devices[0].progress === 42, "reopening adopts the running job and its progress")
    firmware.readState("broken")
    firmware.readState("null")
    check(firmware.busy && firmware.devices.length === 1, "an unreadable state keeps the last complete result")
    firmware.readState('{"running":false,"reboot":true,"devices":[],"error":""}')
    check(!firmware.busy && firmware.state.reboot, "completed firmware retains its restart requirement")
    check(firmware.shown && firmware.restart, "a restart it waits for is shown")
    firmware.readState('{"running":false,"checked":true,"action":"check","devices":[],"error":""}')
    check(!firmware.shown, "nothing to install, nothing shown")
    firmware.readState('{"running":false,"checked":true,"action":"check","devices":[],"error":"Could not refresh; showing saved updates."}')
    check(!firmware.shown && firmware.error === "", "a check that fails says nothing")
    firmware.readState('{"running":false,"checked":true,"action":"check","devices":[{"id":"abc","name":"System Firmware","current":"0.1.53","version":"0.1.55","summary":"","status":"available","progress":0}]}')
    check(firmware.shown, "an update found is shown")
    firmware.readState('{"running":false,"checked":true,"action":"install","devices":[],"error":"line 1\\nline 2\\nline 3\\nfailed to write"}')
    check(firmware.shown && firmware.error === "line 2\nline 3\nfailed to write", "an install that fails says why, in its last lines")
    firmware.check()
    check(!firmware.busy, "with Settings leaving it off, Check asks nothing")
    console.log("DONE")
    Qt.quit()
  })
}
