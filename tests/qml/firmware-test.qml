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
    console.log("DONE")
    Qt.quit()
  })
}
