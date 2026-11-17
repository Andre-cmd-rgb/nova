.pragma library

// The battery's charge as the shell shows it, from what UPower says. Charge.qml
// feeds it UPower's display device; it is apart so that it can be tested, as
// UPower's device cannot be faked.
//
// Plugged in with its charging done, a battery at 95% or more reads full. A
// charger fills the battery and then lets it rest: plugged in again at 96-99%,
// it waits until the charge falls a few percent before it tops it up, which
// spares the battery. A Mac and a phone show that rest as 100%; 99% beside
// "Fully charged" reads as a charge that stuck. A charge limit is different:
// where it stops is the point of it, so a battery a limit holds reads what it
// holds. Below 95% a charge that stopped is not a rest (a charger too weak, a
// battery too warm), and reads as it is. The battery's record keeps the
// figures the battery gives.

// From where a stopped charge is a rest, in whole percent as it is shown
// (nova-battery-info has the same).
var REST_FROM = 95

// Whether the battery is resting full: plugged in, charging done by UPower's
// word (fully-charged), no charge limit holding it, and at REST_FROM or more.
// <fraction> is UPower's, 0 to 1.
function resting(fraction, plugged, fullyCharged, limited) {
  return plugged === true && fullyCharged === true && limited !== true
    && Math.round(Number(fraction) * 100) >= REST_FROM
}

// The charge to show, 0 to 1: UPower's <fraction>, or 1 while resting.
function level(fraction, plugged, fullyCharged, limited) {
  if (resting(fraction, plugged, fullyCharged, limited)) return 1
  var value = Number(fraction)
  return isFinite(value) ? Math.max(0, Math.min(1, value)) : 0
}
