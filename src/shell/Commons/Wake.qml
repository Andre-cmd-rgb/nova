pragma Singleton
import QtQuick

// The wall clock, looked at every ten seconds for all that must notice the
// machine slept: a Timer runs on the monotonic clock, which stands still
// meanwhile, so what waits on one comes back as it went. One look for the
// whole shell, rather than one a widget. looked() at each look; woke() as
// well when the wall clock moved half a minute or more since the last,
// which only a sleep (or the clock being set) does.
QtObject {
  id: wake

  signal looked()
  signal woke()

  property double lastLook: Date.now()

  property Timer looker: Timer {
    interval: 10000
    running: true
    repeat: true
    onTriggered: {
      const now = Date.now()
      const slept = now - wake.lastLook > 30000
      wake.lastLook = now
      wake.looked()
      if (slept) wake.woke()
    }
  }
}
