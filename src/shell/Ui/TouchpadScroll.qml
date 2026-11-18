import QtQuick

// A touchpad scrolls <flickable> as GTK, and so every other window here,
// scrolls one. Qt moves a view by the touchpad's delta itself, which Nova's
// touchpad factor (0.4, for apps that speed a scroll up themselves) turns
// into a crawl, and stops dead when the fingers lift; GTK multiplies the
// delta by the view's size to the power 2/3 over 10 and glides on. A mouse
// wheel's notch is left to Qt, which moves it as far as GTK does. Every
// event of a touchpad's scroll is this one's (take), so the two never take
// turns at one view.
//
// The view stops at its ends, a glide too: Qt's own views run on past an
// end and spring back, which reads as the page catching at its end and
// holding the fingers' next scroll.
//
// Over a list, it takes the touchpad before the rows do, and lets clicks and
// hovers through. Under a page (z: -1), a control on the page that takes the
// wheel itself, a slider, keeps it. Over a view that moves across (across:
// true), a row of pictures on a page, it takes the swipes that go across,
// and leaves those that go up or down to the page.
MouseArea {
  id: root

  property Flickable flickable: null
  property bool across: false

  acceptedButtons: Qt.NoButton
  // The last tenth of a second of the view's movement, which the glide
  // carries on.
  property var recent: []
  // Over a view that moves across, the swipe under way: "" until it has
  // gone far enough to tell, then "across", or "down" for one the page
  // takes; and how far it has gone each way until then.
  property string swipe: ""
  property real swipeAlong: 0
  property real swipeAside: 0

  // Declared inside the view (a list in a Column has no room beside it), it
  // covers the view, and never its rows, which it would scroll with.
  Component.onCompleted: {
    if (!flickable) return
    if (parent === flickable.contentItem) parent = flickable
    if (parent === flickable) anchors.fill = flickable
    flickable.boundsBehavior = Flickable.StopAtBounds
  }

  // Moves the view by a touchpad's <delta> its way, as GTK would. What the
  // view moved is kept for the glide, not what the fingers asked: fingers
  // that push on at an end move nothing, and nothing glides on from them.
  function scrollBy(delta, now) {
    var view = root.flickable
    if (!view) return
    var d = delta * Math.pow(across ? view.width : view.height, 2 / 3) / 10
    var was = across ? view.contentX : view.contentY
    view.cancelFlick()
    if (across) {
      var left = view.originX - view.leftMargin
      var right = view.originX + view.contentWidth + view.rightMargin - view.width
      view.contentX = Math.max(left, Math.min(right, was - d))
    } else {
      var top = view.originY - view.topMargin
      var bottom = view.originY + view.contentHeight + view.bottomMargin - view.height
      view.contentY = Math.max(top, Math.min(bottom, was - d))
    }
    var moved = was - (across ? view.contentX : view.contentY)
    recent = recent.filter(function (s) { return now - s.t < 100 }).concat([{ t: now, d: moved }])
  }

  // Whether a wheel event is a touchpad's. Qt gives a touchpad's scroll
  // phases, from the fingers' first movement (ScrollBegin) to their lift
  // (ScrollEnd), and pixels; a wheel's notches have neither. Pixels alone
  // will not do: Qt rounds them, carrying what it drops to the next event,
  // so a slow scroll has many events of 0 pixels between its others.
  function isTouchpad(dx, dy, phase) {
    return dx !== 0 || dy !== 0 || phase !== Qt.NoScrollPhase
  }

  // Takes a wheel event at <now>, in ms, of <dx>, <dy> pixels: a touchpad's
  // moves the view and is taken whole, its events of 0 pixels too, so that
  // Qt's own wheel scrolling never moves the view between them; a wheel's is
  // left to Qt (false), as is, over a view that moves across, a swipe up or
  // down. The view glides on from the lift, or where there are no phases,
  // once events stop coming.
  function take(dx, dy, phase, now) {
    if (!root.flickable || !isTouchpad(dx, dy, phase)) return false
    // Fingers back on the touchpad hold a glide where it is, and the page
    // under a view that moves across sees them land too.
    if (phase === Qt.ScrollBegin) {
      root.flickable.cancelFlick()
      recent = []
      swipe = ""
      swipeAlong = 0
      swipeAside = 0
      if (across) return false
    }
    if (across && !goesAcross(dx, dy, phase)) {
      if (phase === Qt.ScrollEnd) swipe = ""
      return false
    }
    var delta = across ? dx : dy
    if (delta !== 0) scrollBy(delta, now)
    if (phase === Qt.ScrollEnd) {
      glide.stop()
      release(now)
      swipe = ""
    } else if (phase === Qt.NoScrollPhase) {
      glide.restart()
    }
    return true
  }

  // Whether the event is part of a swipe across: told by the swipe's first
  // few pixels, the way it went furthest, and until then not; without
  // phases, by the event itself.
  function goesAcross(dx, dy, phase) {
    if (phase === Qt.NoScrollPhase) return Math.abs(dx) > Math.abs(dy)
    if (swipe === "") {
      swipeAlong += Math.abs(dx)
      swipeAside += Math.abs(dy)
      if (swipeAlong + swipeAside >= 4) swipe = swipeAlong > swipeAside ? "across" : "down"
    }
    return swipe === "across"
  }

  // The fingers lifted at <now>: the view glides on at the speed of their
  // last tenth of a second, unless they rested before they lifted.
  function release(now) {
    var r = recent
    recent = []
    if (r.length < 2 || !root.flickable || now - r[r.length - 1].t > 100) return
    var moved = 0
    for (var i = 1; i < r.length; i++) moved += r[i].d
    if (moved === 0) return
    var speed = moved / Math.max(0.016, (r[r.length - 1].t - r[0].t) / 1000)
    if (across) root.flickable.flick(speed, 0)
    else root.flickable.flick(0, speed)
  }

  onWheel: function (wheel) {
    wheel.accepted = root.take(wheel.pixelDelta.x, wheel.pixelDelta.y, wheel.phase, Date.now())
  }

  // Without phases, no event for this long: the fingers have lifted (or
  // stopped).
  Timer {
    id: glide
    interval: 50
    onTriggered: {
      var r = root.recent
      if (r.length > 0) root.release(r[r.length - 1].t + interval)
    }
  }
}
