import QtQuick

// AirDrop as the menu's row toggles it, through the shell's summon and hide:
// open switches AirDrop on, close switches it off, and `opened` is whether
// it is on. The service (AirDrop.qml) does the work; this is kept loaded so
// that the toggle reads it from the start.
Item {
  // Set by the shell.
  property var shell: null
  property var service: null

  readonly property var airdrop: service || (shell ? shell.serviceFor("nova.airdrop") : null)
  readonly property bool opened: !!airdrop && airdrop.opened

  function open(payload) {
    if (airdrop) airdrop.turnOn()
  }

  function close() {
    if (airdrop) airdrop.turnOff()
  }
}
