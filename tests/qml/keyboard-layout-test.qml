import QtQuick
import Quickshell
import "plugins/bar/widgets/KeyboardLayoutModel.js" as Keyboards

// What the keyboard layout widget makes of `hyprctl -j devices`: which
// devices are typed on, and the one it speaks for.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function board(name, layout, index, keymap) {
    return { name: name, layout: layout, active_layout_index: index, active_keymap: keymap }
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    // A ThinkPad P1 Gen 4i with a Logitech G603 mouse, as Hyprland 0.56
    // lists it: one keyboard, a mouse with keys, and buttons.
    const p1 = JSON.stringify({ keyboards: [
      board("video-bus", "es", 0, "Spanish"),
      board("logitech-g603", "es", 0, "Spanish"),
      board("sof-hda-dsp-headphone", "es", 0, "Spanish"),
      board("video-bus-1", "es", 0, "Spanish"),
      board("power-button", "es", 0, "Spanish"),
      board("sleep-button", "es", 0, "Spanish"),
      board("at-translated-set-2-keyboard", "es", 0, "Spanish"),
      board("thinkpad-extra-buttons", "es", 0, "Spanish"),
      board("asus-wmi-hotkeys", "es", 0, "Spanish"),
      board("hda-intel-pch-headphone", "es", 0, "Spanish")
    ] })
    const seen = Keyboards.seat(p1, "")
    check(seen.count === 2, "buttons, the jack and hotkeys are not typed on; a mouse with keys has no name to tell it by")
    check(seen.keyboard.name === "logitech-g603", "a tie: the first typed on")
    check(Keyboards.seat(p1, "at-translated-set-2-keyboard").keyboard.name === "at-translated-set-2-keyboard", "the keyboard the last switch named")

    const two = JSON.stringify({ keyboards: [
      board("at-translated-set-2-keyboard", "us,de", 0, "English (US)"),
      board("keychron-k2", "us,de", 1, "German")
    ] })
    check(Keyboards.seat(two, "").keyboard.name === "keychron-k2", "otherwise the one furthest along")
    check(Keyboards.seat(two, "gone").keyboard.name === "keychron-k2", "a named keyboard since unplugged is not spoken for")
    check(Keyboards.seat("{\"keyboards\": [", "") === null, "a reading cut short says nothing")
    check(Keyboards.seat(JSON.stringify({ keyboards: [board("power-button", "us", 0, "English (US)")] }), "").count === 0, "no keyboard typed on")

    console.log("DONE")
    Qt.quit()
  }
}
