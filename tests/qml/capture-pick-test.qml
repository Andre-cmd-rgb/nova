import QtQuick
import Quickshell
import "plugins/capture/Pick.js" as Pick

// The screen picker's rules (plugins/capture/Pick.js), held to what slurp's
// picker does (tests/unit/cli/capture-region.bats): what a point offers, a
// region drawn and a click, a region cut to a screen, and where TAB, CTRL +
// TAB and the arrows move the highlight, among four windows: A and B side by
// side at the top, C across the bottom, and a small floating D over A's
// middle. Reading order is A, B, D, C.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function same(got, want, what) {
    const ok = JSON.stringify(got) === JSON.stringify(want)
    check(ok, what + (ok ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  function name(r, lay) {
    if (!r) return null
    const names = ["A", "B", "C", "D"]
    for (let i = 0; i < lay.windows.length; i++) if (Pick.same(r, lay.windows[i])) return names[i]
    return Pick.format(r)
  }

  function run() {
    const one = Pick.layout("focused 0,0 1000x800\nmonitor 0,0 1000x800\nwindow 50,50 200x200\n")
    same(Pick.format(Pick.offered(one, 100, 100)), "50,50 200x200", "a point inside a window offers the window, not its monitor")
    same(Pick.format(Pick.offered(one, 600, 600)), "0,0 1000x800", "a point beside every window offers the monitor")
    same(Pick.offered(one, 1200, 100), null, "a point off every screen offers nothing")
    same(Pick.format(Pick.highlighted(one, NaN, NaN)), "0,0 1000x800", "RETURN with the pointer unseen takes the screen in focus")
    same(Pick.layout("nonsense\nwindow 1,2\n"), { focused: null, monitors: [], windows: [] }, "lines that say nothing are left out")

    same(Pick.drawn(300.4, 200.6, 10.2, 10.7), { x: 10, y: 11, w: 290, h: 190 }, "a region drawn either way, in whole pixels")
    check(Pick.isClick(Pick.drawn(5, 5, 8, 9)), "under 20 square pixels is a click")
    check(!Pick.isClick(Pick.drawn(5, 5, 10, 10)), "and 25 is a region")
    same(Pick.clip({ x: 900, y: 700, w: 300, h: 300 }, { x: 0, y: 0, w: 1000, h: 800 }), { x: 900, y: 700, w: 100, h: 100 },
      "a region across two screens, the part on each")
    same(Pick.clip({ x: 1100, y: 0, w: 50, h: 50 }, { x: 0, y: 0, w: 1000, h: 800 }), null, "and nothing of it on a screen it is not on")
    same(Pick.parse(" -1920,0 1920x1080 "), { x: -1920, y: 0, w: 1920, h: 1080 }, "a screen left of the first, as Hyprland places it")

    const four = Pick.layout(["focused 0,0 1000x800", "monitor 0,0 1000x800", "window 0,0 500x400", "window 500,0 500x400",
      "window 0,400 1000x400", "window 200,150 100x100"].join("\n"))
    const A = four.windows[0], B = four.windows[1], C = four.windows[2], D = four.windows[3]
    same(Pick.spots(four.windows), [{ x: 187, y: 200 }, { x: 750, y: 200 }, { x: 500, y: 600 }, { x: 250, y: 200 }],
      "each window's point of its own: A's middle is D's, so A's is beside it")
    same(Pick.reading(four.windows).map(r => name(r, four)), ["A", "B", "D", "C"], "reading order: down the screen, then across")
    const from = (current, x, y, way) => name(Pick.step(four.windows, current, x, y, way), four)
    same([from(D, 250, 200, "next"), from(D, 250, 200, "prev")], ["C", "B"], "TAB and CTRL + TAB from D")
    same([from(C, 900, 700, "next"), from(C, 900, 700, "prev")], ["A", "D"], "and from C, round the end")
    same([from(null, 900, 700, "next"), from(null, 900, 700, "prev")], ["A", "C"], "with nothing highlighted, from before the first or after the last")
    same(["left", "right", "up", "down"].map(way => from(D, 250, 200, way)), [null, "B", null, "C"],
      "the arrows from D: the nearest window that way, or nowhere")
    same(from(C, 900, 700, "up"), "A", "three as near: the first in reading order")
    same(Pick.step([], null, 0, 0, "next"), null, "with no windows there is nowhere to go")

    console.log("DONE")
    Qt.quit()
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)
}
