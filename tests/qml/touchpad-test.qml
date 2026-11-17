import QtQuick
import Quickshell
import qs.Ui

// The touchpad's scroll, as GTK moves a view: the fingers' delta times the
// view's height to the power 2/3 over 10, never past either end, and a
// handler declared inside a list moved up over it rather than scrolling
// with its rows. Every event of a touchpad's scroll is its own, those of 0
// pixels between the others too, and a wheel's notch Qt's; the view glides
// on as the fingers lift, unless they rested first.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  Item {
    Flickable {
      id: page
      width: 100
      height: 200
      contentHeight: 1000
    }

    TouchpadScroll {
      id: pageScroll
      anchors.fill: page
      flickable: page
    }

    ListView {
      id: list
      width: 100
      height: 100
      model: 3
      delegate: Item { width: 100; height: 10 }

      TouchpadScroll { id: listScroll; flickable: list }
    }
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    var step = 10 * Math.pow(200, 2 / 3) / 10
    pageScroll.scrollBy(-10, 0)
    check(Math.abs(page.contentY - step) < 0.01, "ten pixels of fingers move a 200 px view " + step.toFixed(1) + " px: " + page.contentY)
    pageScroll.scrollBy(100, 20)
    check(page.contentY === 0, "never above the top: " + page.contentY)
    pageScroll.scrollBy(-10000, 40)
    check(page.contentY === 800, "never past the bottom: " + page.contentY)
    check(pageScroll.recent.length === 3, "the last tenth of a second kept for the glide")
    pageScroll.scrollBy(-1, 500)
    check(pageScroll.recent.length === 1, "and nothing older")

    // Whose event it is.
    page.contentY = 400
    check(pageScroll.take(0, Qt.NoScrollPhase, 1000) === false && page.contentY === 400, "a wheel's notch is left to Qt")
    check(pageScroll.take(0, Qt.ScrollUpdate, 1000) === true && page.contentY === 400,
      "a touchpad's event of 0 pixels is taken, and moves nothing")
    check(pageScroll.take(-2, Qt.NoScrollPhase, 1000) === true, "pixels are a touchpad's, phases or not")
    pageScroll.recent = []

    // A swipe: begun, moved, lifted while moving.
    pageScroll.take(0, Qt.ScrollBegin, 2000)
    for (var t = 2000; t <= 2080; t += 10) pageScroll.take(-3, Qt.ScrollUpdate, t)
    pageScroll.take(0, Qt.ScrollEnd, 2085)
    check(page.flicking, "fingers lifted while moving: the view glides on")
    pageScroll.take(0, Qt.ScrollBegin, 2200)
    check(!page.flicking, "fingers back on the touchpad hold the glide")
    for (t = 2200; t <= 2280; t += 10) pageScroll.take(-3, Qt.ScrollUpdate, t)
    pageScroll.take(0, Qt.ScrollEnd, 2500)
    check(!page.flicking, "fingers that rested before they lifted leave the view where it is")

    check(listScroll.parent === list && listScroll.parent !== list.contentItem, "inside a list, it sits on the list, not among its rows")
    check(listScroll.width === 100 && listScroll.height === 100, "and covers it: " + listScroll.width + "x" + listScroll.height)

    console.log("DONE")
    Qt.quit()
  }
}
