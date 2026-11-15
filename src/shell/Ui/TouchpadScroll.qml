import QtQuick

// A touchpad scrolls <flickable> as GTK, and so every other window here,
// scrolls one. Qt moves a view by the touchpad's delta itself, which Nova's
// touchpad factor (0.4, for apps that speed a scroll up themselves) turns
// into a crawl, and stops dead when the fingers lift; GTK multiplies the
// delta by the view's height to the power 2/3 over 10 and glides on. A mouse
// wheel's notch is left to Qt, which moves it as far as GTK does.
//
// Over a list, it takes the touchpad before the rows do, and lets clicks and
// hovers through. Under a page (z: -1), a control on the page that takes the
// wheel itself, a slider, keeps it.
MouseArea {
  id: root

  property Flickable flickable: null

  acceptedButtons: Qt.NoButton
  // The last tenth of a second of movement, which the glide carries on.
  property var recent: []

  // Declared inside the view (a list in a Column has no room beside it), it
  // covers the view, and never its rows, which it would scroll with.
  Component.onCompleted: {
    if (!flickable) return
    if (parent === flickable.contentItem) parent = flickable
    if (parent === flickable) anchors.fill = flickable
  }

  // Moves the view by a touchpad's <pixelDelta>, as GTK would.
  function scrollBy(pixelDelta, now) {
    var view = root.flickable
    if (!view) return
    var dy = pixelDelta * Math.pow(view.height, 2 / 3) / 10
    var top = view.originY - view.topMargin
    var bottom = view.originY + view.contentHeight + view.bottomMargin - view.height
    view.cancelFlick()
    view.contentY = Math.max(top, Math.min(bottom, view.contentY - dy))
    recent = recent.filter(function (s) { return now - s.t < 100 }).concat([{ t: now, dy: dy }])
    glide.restart()
  }

  onWheel: function (wheel) {
    if (!root.flickable || wheel.pixelDelta.y === 0) {
      wheel.accepted = false
      return
    }
    root.scrollBy(wheel.pixelDelta.y, Date.now())
  }

  // No event for this long: the fingers have lifted (or stopped).
  Timer {
    id: glide
    interval: 50
    onTriggered: {
      var r = root.recent
      root.recent = []
      if (r.length < 2 || !root.flickable) return
      var moved = 0
      for (var i = 1; i < r.length; i++) moved += r[i].dy
      root.flickable.flick(0, moved / Math.max(0.016, (r[r.length - 1].t - r[0].t) / 1000))
    }
  }
}
