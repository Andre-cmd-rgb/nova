import QtQuick
import Quickshell
import "plugins/settings/DisplaysModel.js" as Model

// The Displays page's choices, from `nova monitor list --json` objects: a
// 1440p display with two rates at its own resolution, the resolution and
// rate a change asks for, scales in percent, where one display sits next to
// another, the arrangement drawn small, and the clock on a change.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    var modes = [
      { width: 2560, height: 1440, refresh: 120, mode: "2560x1440@120.00" },
      { width: 2560, height: 1440, refresh: 59.95, mode: "2560x1440@59.95" },
      { width: 1920, height: 1080, refresh: 60, mode: "1920x1080@60.00" }
    ]
    check(JSON.stringify(Model.resolutions(modes)) === JSON.stringify([
      { value: "2560x1440", label: "2560 × 1440" }, { value: "1920x1080", label: "1920 × 1080" }]), "each resolution once, widest first")
    check(JSON.stringify(Model.rates(modes, "2560x1440").map(function (r) { return r.label })) === '["120 Hz","59.95 Hz"]', "its rates, fastest first, 59.95 not rounded to 60")
    check(Model.hz(59.999) === "60 Hz" && Model.hz(143.97) === "143.97 Hz", "a rate a hair off a whole number is that number")
    check(Model.rateValue(modes, "2560x1440", 59.951) === "2560x1440@59.95", "the rate Hyprland reports picks its mode")
    check(Model.rateValue(modes, "2560x1440", 75) === "", "a rate the display has no mode for picks none")
    check(Model.modeAt(modes, "2560x1440", 59.951) === "2560x1440@59.95", "a resolution keeps the rate it has there")
    check(Model.modeAt(modes, "1920x1080", 120) === "1920x1080@60.00", "else takes the fastest there is")
    check(Model.modeAt(modes, "800x600", 60) === "", "and a resolution not offered asks for nothing")

    check(Model.percent(1) === "100%" && Model.percent(1.6) === "160%" && Model.percent(4 / 3) === "133%", "scales in percent")
    check(JSON.stringify(Model.scaleOptions([1, 1.25, 2], 1.25).map(function (o) { return o.label })) === '["100%","125%","200%"]', "the scales offered")
    check(Model.scaleValue([1, 1.25, 2], 1.25) === "1.25" && Model.scaleValue([1, 2], 2.0000001) === "2", "the one the display is at")
    check(JSON.stringify(Model.scaleOptions([1, 2], 1.5).map(function (o) { return o.value })) === '["1","1.5","2"]'
      && Model.scaleValue([1, 2], 1.5) === "1.5", "a scale from monitors.lua the page has not got is offered too, in its place")

    check(Model.rotation(0) === "0" && Model.rotation(1) === "90" && Model.rotation(3) === "270", "Hyprland's turns as degrees")
    check(Model.rotation(4) === "", "a flipped display is none of the page's rotations")

    var panel = { name: "eDP-1", label: "Built-in Display", enabled: true, focused: true, x: 0, y: 0, logicalWidth: 1920, logicalHeight: 1200 }
    var dell = { name: "DP-2", label: "Dell Inc. DELL U2724D", enabled: true, focused: false, x: 1920, y: 0, logicalWidth: 2560, logicalHeight: 1440 }
    check(Model.relation(dell, panel) === "right-of" && Model.relation(panel, dell) === "left-of", "side by side")
    check(Model.relation({ x: 0, y: 1200, logicalWidth: 1920, logicalHeight: 1080 }, panel) === "below", "one under the other")
    check(Model.relation({ x: 0, y: 0, logicalWidth: 1920, logicalHeight: 1080 }, panel) === "", "mirrored, overlapping, neither")
    check(Model.relation(dell, null) === "", "and next to nothing, nowhere")

    check(Model.pick([panel, dell], "DP-2") === dell && Model.pick([panel, dell], "") === panel && Model.pick([], "x") === null, "the display Position is next to")

    var twin = { name: "DP-3", label: "Dell Inc. DELL U2724D" }
    var names = Model.labels([panel, dell, twin])
    check(names["eDP-1"] === "Built-in Display" && names["DP-2"] === "Dell Inc. DELL U2724D (DP-2)" && names["DP-3"] === "Dell Inc. DELL U2724D (DP-3)", "two of one model told apart by their connectors")

    var drawn = Model.layout([panel, dell, { name: "HDMI-A-1", enabled: false, logicalWidth: 0, logicalHeight: 0, x: 0, y: 0 }], 448, 200)
    check(drawn.length === 2, "only the displays that are on are drawn")
    check(drawn[0].x === 0 && Math.abs(drawn[1].x - 192) < 0.001 && Math.abs(drawn[1].width - 256) < 0.001, "to scale, side by side: " + drawn[1].x + ", " + drawn[1].width)
    check(Math.abs(drawn[0].y - 28) < 0.001 && Math.abs(drawn[1].height - 144) < 0.001, "and centred in the box: " + drawn[0].y)
    check(drawn[0].focused === true && drawn[1].focused === false, "with the one in use marked")
    check(Model.layout([], 100, 100).length === 0 && Model.layout([panel], 0, 100).length === 0, "nothing to draw, or nowhere to draw it")

    check(Model.secondsLeft(1000, 990000) === 10 && Model.secondsLeft(1000, 999500) === 1 && Model.secondsLeft(1000, 1002000) === 0, "the clock in whole seconds")
    check(Model.countdown(12) === "Going back in 12 seconds." && Model.countdown(1) === "Going back in 1 second." && Model.countdown(0) === "Going back…", "and in words")

    console.log("DONE")
    Qt.quit()
  }
}
