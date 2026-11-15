import QtQuick
import Quickshell
import "plugins/panels/monitor/Model.js" as Model

// The display panel's rules: what nova-monitor-state prints, the scales
// Hyprland takes, the brightness in words, the stops of a slider, the call
// that turns a display off or on, and the keys' cursor. The answers are
// those of the rules as they were before their rewrite.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // JSON leaves out what is undefined, and so does the test's answer.
  function same(one, other) {
    return JSON.stringify(one === undefined ? null : one) === JSON.stringify(other)
  }

  function state(first, displays) {
    return [first, "a", "b", "c", "d", "eDP-1", " 1.25 ", displays].join("\n")
  }
  function counts() {
    return { scale: 4, monitors: 3 }
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    check(same([Model.readState(state("55", JSON.stringify([{ name: "eDP-1", enabled: true }, { name: "DP-3", enabled: false }, null]))), Model.readState(state("unavailable", "[]")), Model.readState(state("", "{}")), Model.readState(state("140", "garbage")), Model.readState(state("-3", "")), Model.readState(""), Model.readState(null), Model.readState("70\n"), Model.readState(state("abc", "[{\"enabled\":1}]"))], [{"hasBacklight":true,"brightness":55,"focused":"eDP-1","scale":"1.25","displays":[{"name":"eDP-1","enabled":true},{"name":"DP-3","enabled":false},null],"enabled":1},{"hasBacklight":false,"brightness":0,"focused":"eDP-1","scale":"1.25","displays":[],"enabled":0},{"hasBacklight":false,"brightness":0,"focused":"eDP-1","scale":"1.25","displays":[],"enabled":0},{"hasBacklight":true,"brightness":100,"focused":"eDP-1","scale":"1.25","displays":[],"enabled":0},{"hasBacklight":true,"brightness":0,"focused":"eDP-1","scale":"1.25","displays":[],"enabled":0},{"hasBacklight":false,"brightness":0,"focused":"","scale":"","displays":[],"enabled":0},{"hasBacklight":false,"brightness":0,"focused":"","scale":"","displays":[],"enabled":0},{"hasBacklight":true,"brightness":70,"focused":"","scale":"","displays":[],"enabled":0},{"hasBacklight":true,"brightness":null,"focused":"eDP-1","scale":"1.25","displays":[{"enabled":1}],"enabled":1}]), "what nova-monitor-state prints")
    check(same([Model.readDisplays(""), Model.readDisplays("null"), Model.readDisplays("5"), Model.readDisplays("[1, {\"enabled\": true}, {\"enabled\": false}]"), Model.readDisplays(undefined)], [{"displays":[],"enabled":0},{"displays":[],"enabled":0},{"displays":[],"enabled":0},{"displays":[1,{"enabled":true},{"enabled":false}],"enabled":1},{"displays":[],"enabled":0}]), "the displays read")
    check(same([Model.screensIcon(0), Model.screensIcon(1), Model.screensIcon(2), Model.screensIcon(5)].concat([0, 1, 0.4, 50.5, 100, 140, -3, "x", "", null, "70", Infinity].map(v => Model.percent(v))), ["󰍹","󰍹","󰍺","󰍺",1,1,1,51,100,100,1,1,1,1,70,1]), "glyphs and percents")
    check(same([1, 1.25, "1.333333", 2, "2.0", 0, "", null, undefined, "x", "1.5x", 1.005, " 1.2 ", 0.004].map(s => Model.scaleText(s)), ["1","1.25","1.33","2","2","","","","","","1.5","1","1.2","0"]), "a scale as text")
    check(same([[1, 1920, 1080], [1.25, 1920, 1080], [1.3, 1920, 1080], [1.5, 2560, 1600], [1.6, 2560, 1600], [2, 3840, 2160], [1.15, 1366, 768], [3, 100, 100], [0, 1920, 1080], [1, 0, 1080], ["x", 1920, 1080], [1.25, 1920.5, 1080], [-1, 1920, 1080]].map(([s, w, h]) => Model.snapScale(s, w, h)), ["1","1.25","1.33","1.6","1.6","2","2","3.13","","","","0.5",""]), "the scale Hyprland gives")
    check(same([[12, 8], [8, 12], [7, 3], [0, 5], [5, 0], [230400, 129600]].map(([a, b]) => Model.gcd(a, b)), [4,4,1,5,5,14400]), "the greatest common divisor")
    check(same([Model.scalesFor(["1", "1.25", "1.5", "1.75", "2"], 1920, 1080), Model.scalesFor(["1", "1.25", "1.5", "1.6", "2"], 2560, 1600), Model.scalesFor(["1", "1.1", "1.15", "1.2"], 1366, 768), Model.scalesFor(["1", "2"], 0, 1080), Model.scalesFor(["x", "1"], 1920, 1080), Model.scalesFor([], 1920, 1080), Model.scalesFor(["2", "1"], 1920, 1080)], [["1","1.25","1.5","1.75","2"],["1","1.25","1.6","2"],["1","1.2"],["1","2"],["1"],[],["2","1"]]), "the presets a display takes")
    check(same([Model.scaleIndex(["1", "1.25", "1.5", "2"], 1.25, 1920, 1080), Model.scaleIndex(["1", "1.25", "1.5", "2"], 1.33, 1920, 1080), Model.scaleIndex(["1", "1.25", "1.5", "2"], "x", 1920, 1080), Model.scaleIndex(["1.3", "1.25"], 1.25, 1920, 1080), Model.scaleIndex([], 1, 1920, 1080), Model.scaleIndex(["1", "1"], 1, 1920, 1080)], [1,-1,-1,1,-1,0]), "which one it is at")
    check(same([100, 95, 94.5, 94.4, 80, 79, 65, 45, 44, 30, 20, 10, 9.6, 9.4, 0, -5].map(v => Model.mood(v)), ["Sun blast","Sun blast","Sun blast","Solar flare","Solar flare","Golden hour","Golden hour","Even day","Soft glow","Soft glow","Lamp light","Candlelit","Candlelit","Night owl","Night owl","Night owl"]), "the brightness in words")
    check(same([[[0, 50, 100], 60], [[0, 50, 100], 75], [[0, 50, 100], -20], [[0, 50, 100], 1000], [[], 5], [[10, 10], 10], [[0, 40, 60], 50]].map(([s, p]) => Model.nearestStop(s, p)), [1,1,0,2,0,0,1]), "the nearest stop")
    check(same([Model.displayCall("eDP-1", true), Model.displayCall("DP-3", false), Model.displayCall("we\"ird\\name", true)], ["hl.monitor({ output = \"eDP-1\", disabled = true })","hl.monitor({ output = \"DP-3\", disabled = false, mode = \"preferred\", position = \"auto\", scale = \"auto\" })","hl.monitor({ output = \"we\\\"ird\\\\name\", disabled = true })"]), "the call that turns a display off or on")
    check(same([Model.sections(true, 2), Model.sections(false, 1), Model.sections(true, 0), Model.sections(false, 3)].concat([["brightness"], ["textsize"], ["scale"], ["monitors"]].map(([s]) => [Model.isSlider(s), Model.oneStop(s), Model.entry(s), Model.rows(s, counts())])), [["brightness","textsize","scale","monitors"],["textsize","scale"],["brightness","textsize","scale"],["textsize","scale","monitors"],[true,true,-1,0],[true,true,-1,0],[false,true,0,4],[false,false,0,3]]), "the sections")
    check(same([["brightness", -1], ["textsize", -1], ["scale", 2], ["monitors", 0], ["monitors", 2], ["gone", 4]].map(([s, i]) => Model.move(Model.at(s, i), 1, Model.sections(true, 3), counts())), [{"section":"textsize","index":-1},{"section":"scale","index":0},{"section":"monitors","index":0},{"section":"monitors","index":1},{"section":"monitors","index":2},{"section":"brightness","index":-1}]), "the cursor down")
    check(same([["brightness", -1], ["textsize", -1], ["scale", 2], ["monitors", 0], ["monitors", 2], ["gone", 4]].map(([s, i]) => Model.move(Model.at(s, i), -1, Model.sections(true, 3), counts())).concat([Model.move(Model.at("scale", 0), -1, ["textsize", "scale", "monitors"], { scale: 0, monitors: 0 })]), [{"section":"brightness","index":-1},{"section":"brightness","index":-1},{"section":"textsize","index":-1},{"section":"scale","index":0},{"section":"monitors","index":1},{"section":"brightness","index":-1},{"section":"textsize","index":-1}]), "and up")
    check(same([[0, 1, 4], [3, 1, 4], [0, -1, 4], [2, -1, 4], [5, 1, 4], [0, 1, 0]].map(([i, d, c]) => Model.along(i, d, c)), [1,3,0,1,3,-1]), "along the presets")
    check(same([["brightness", 3], ["scale", 7], ["scale", -1], ["scale", 2], ["monitors", 5], ["monitors", -2], ["gone", 1]].map(([s, i]) => Model.clamp(Model.at(s, i), Model.sections(true, 3), counts())).concat([Model.clamp(Model.at("monitors", 1), ["textsize", "scale", "monitors"], { scale: 4, monitors: 0 }), Model.clamp(Model.at("monitors", 1), ["monitors"], { scale: 4, monitors: 0 }), Model.clamp(Model.at("scale", 1), ["textsize", "scale"], { scale: 0 })]), [{"section":"brightness","index":-1},{"section":"scale","index":0},{"section":"scale","index":0},{"section":"scale","index":2},{"section":"monitors","index":2},{"section":"monitors","index":0},{"section":"brightness","index":-1},{"section":"scale","index":0},{"section":"monitors","index":0},{"section":"scale","index":0}]), "the cursor kept")

    console.log("DONE")
    Qt.quit()
  }
}
