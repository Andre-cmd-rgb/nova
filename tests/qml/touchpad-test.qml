import QtQuick
import QtQuick.Controls
import Quickshell
import qs.Ui

// The touchpad's scroll, as GTK moves a view: the fingers' delta times the
// view's size to the power 2/3 over 10, never past either end, and a
// handler declared inside a list moved up over it rather than scrolling
// with its rows. Every event of a touchpad's scroll is its own, those of 0
// pixels between the others too, and a wheel's notch Qt's; the view glides
// on as the fingers lift, unless they rested first, or pushed on at an end.
// A glide stops at the end it reaches, in a ScrollView too, whose view Qt
// lets run past it. Over a row that moves across, a swipe across is the
// row's, and one down the page's.
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
      property real furthest: 0
      onContentYChanged: furthest = Math.max(furthest, contentY)
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

    ScrollView {
      id: scrolled
      width: 100
      height: 100
      Column {
        Repeater { model: 20; Item { width: 100; height: 20 } }

        TouchpadScroll {
          anchors.fill: parent
          z: -1
          flickable: scrolled.contentItem
        }
      }
    }

    ListView {
      id: row
      width: 100
      height: 50
      orientation: ListView.Horizontal
      model: 10
      delegate: Item { width: 40; height: 50 }

      TouchpadScroll { id: rowScroll; flickable: row; across: true }
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
    check(pageScroll.recent[2].d === -800, "as far as the view moved, not as far as the fingers asked: " + pageScroll.recent[2].d)
    pageScroll.scrollBy(-1, 500)
    check(pageScroll.recent.length === 1, "and nothing older")

    // Whose event it is.
    page.contentY = 400
    check(pageScroll.take(0, 0, Qt.NoScrollPhase, 1000) === false && page.contentY === 400, "a wheel's notch is left to Qt")
    check(pageScroll.take(0, 0, Qt.ScrollUpdate, 1000) === true && page.contentY === 400,
      "a touchpad's event of 0 pixels is taken, and moves nothing")
    check(pageScroll.take(0, -2, Qt.NoScrollPhase, 1000) === true, "pixels are a touchpad's, phases or not")
    pageScroll.recent = []

    // A swipe: begun, moved, lifted while moving.
    pageScroll.take(0, 0, Qt.ScrollBegin, 2000)
    for (var t = 2000; t <= 2080; t += 10) pageScroll.take(0, -3, Qt.ScrollUpdate, t)
    pageScroll.take(0, 0, Qt.ScrollEnd, 2085)
    check(page.flicking, "fingers lifted while moving: the view glides on")
    pageScroll.take(0, 0, Qt.ScrollBegin, 2200)
    check(!page.flicking, "fingers back on the touchpad hold the glide")
    for (t = 2200; t <= 2280; t += 10) pageScroll.take(0, -3, Qt.ScrollUpdate, t)
    pageScroll.take(0, 0, Qt.ScrollEnd, 2500)
    check(!page.flicking, "fingers that rested before they lifted leave the view where it is")

    // At the bottom, fingers that push on and lift.
    page.contentY = 800
    pageScroll.take(0, 0, Qt.ScrollBegin, 3000)
    for (t = 3000; t <= 3080; t += 10) pageScroll.take(0, -3, Qt.ScrollUpdate, t)
    pageScroll.take(0, 0, Qt.ScrollEnd, 3085)
    check(!page.flicking && page.contentY === 800, "fingers that pushed on at the end: nothing glides, the view stays")

    check(page.boundsBehavior === Flickable.StopAtBounds, "the view stops at its ends")
    check(scrolled.contentItem.boundsBehavior === Flickable.StopAtBounds, "a ScrollView's too, which Qt lets run past them")

    check(listScroll.parent === list && listScroll.parent !== list.contentItem, "inside a list, it sits on the list, not among its rows")
    check(listScroll.width === 100 && listScroll.height === 100, "and covers it: " + listScroll.width + "x" + listScroll.height)

    // A row that moves across.
    check(rowScroll.take(0, 0, Qt.ScrollBegin, 4000) === false, "fingers landing on a row: the page under it sees them too")
    check(rowScroll.take(0, -3, Qt.ScrollUpdate, 4010) === false && rowScroll.take(0, -3, Qt.ScrollUpdate, 4020) === false && row.contentX === 0,
      "a swipe down over the row is the page's")
    check(rowScroll.take(-1, 0, Qt.ScrollUpdate, 4030) === false, "and stays the page's, sideways or not")
    check(rowScroll.take(0, 0, Qt.ScrollEnd, 4040) === false, "to its lift")
    rowScroll.take(0, 0, Qt.ScrollBegin, 5000)
    check(rowScroll.take(-3, 0, Qt.ScrollUpdate, 5010) === false, "a swipe's first pixels do not tell yet")
    var taken = true
    for (t = 5020; t <= 5080; t += 10) taken = rowScroll.take(-3, -1, Qt.ScrollUpdate, t) && taken
    var across = 3 * Math.pow(100, 2 / 3) / 10
    check(taken && Math.abs(row.contentX - 7 * across) < 0.01, "a swipe across moves the row by its width's rule: " + row.contentX.toFixed(1))
    check(rowScroll.take(0, 0, Qt.ScrollEnd, 5085) === true && row.flicking, "and glides on across")
    row.cancelFlick()
    check(rowScroll.take(-2, 0, Qt.NoScrollPhase, 6000) === true && rowScroll.take(0, -2, Qt.NoScrollPhase, 6010) === false,
      "without phases, each event goes the way it goes")

    // A glide that runs into the bottom stops at it.
    page.contentY = 600
    page.furthest = 600
    pageScroll.take(0, 0, Qt.ScrollBegin, 7000)
    for (t = 7000; t <= 7080; t += 10) pageScroll.take(0, -3, Qt.ScrollUpdate, t)
    pageScroll.take(0, 0, Qt.ScrollEnd, 7085)
    check(page.flicking && page.contentY < 800, "lifted short of the bottom, the view glides on toward it")
    settle.start()
  }

  Timer {
    id: settle
    interval: 1500
    onTriggered: {
      check(page.contentY === 800 && page.furthest === 800,
        "a glide into the bottom stops there, and never runs past it: " + page.contentY + ", at most " + page.furthest)
      console.log("DONE")
      Qt.quit()
    }
  }
}
