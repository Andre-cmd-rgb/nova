import QtQuick
import Quickshell
import qs.Ui

// The touchpad's scroll, as GTK moves a view: the fingers' delta times the
// view's height to the power 2/3 over 10, never past either end, and a
// handler declared inside a list moved up over it rather than scrolling
// with its rows.
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

    check(listScroll.parent === list && listScroll.parent !== list.contentItem, "inside a list, it sits on the list, not among its rows")
    check(listScroll.width === 100 && listScroll.height === 100, "and covers it: " + listScroll.width + "x" + listScroll.height)

    console.log("DONE")
    Qt.quit()
  }
}
