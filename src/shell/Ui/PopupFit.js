// The size of a popup's card on its screen, for PopupCard and KeyboardPanel.
.pragma library

// <desired>, no more than <available> when that is known (above zero), nor
// than <cap> when one is given above zero; rounded to a whole pixel.
function fit(desired, available, cap) {
  var most = available > 0 ? available : desired
  if (cap !== undefined && Number(cap) > 0) most = Math.min(most, Number(cap))
  return Math.round(Math.min(desired, most))
}
