// What PopupCard and KeyboardPanel share: the size of a card on its screen,
// keeping it off the screen's edges, and the bar's one place for a popup.
.pragma library

// The room a screen <length> long leaves a card, with <near> taken off one
// end and <far> off the other: at least 120, or 0 before the screen is
// known.
function room(length, near, far) {
  return length > 0 ? Math.max(120, length - near - far) : 0
}

// <want>, no more than <room> when that is known (above zero), nor than
// <cap> when one is given above zero; rounded to a whole pixel.
function fit(want, room, cap) {
  let most = room > 0 ? room : want
  if (cap !== undefined && Number(cap) > 0) most = Math.min(most, Number(cap))
  return Math.round(Math.min(want, most))
}

// A card's width for content <width> wide, at least a pixel.
function cardWidth(width, room, cap) {
  return fit(Math.max(1, Number(width) || 1), room, cap)
}

// A card's height round content <height> high, with <inset> (its padding
// and border) above and below it.
function cardHeight(height, inset, room, cap) {
  return fit(Math.max(inset, (Number(height) || 0) + inset), room, cap)
}

// <start> moved so that something <size> long from it stays <margin> inside
// a span of <length>; the near end wins when it cannot.
function within(start, size, length, margin) {
  return Math.max(margin, Math.min(start, length - size - margin))
}

// The bar shows one popup at a time: opening asks it for the place under
// <key>, and closing gives the place back if <key> still has it.
function claim(bar, key, open) {
  if (!bar) return
  if (open) bar.requestPopout(key)
  else if (bar.activePopout === key) bar.releasePopout(key)
}

// Closes <card> through its owner when the owner can close, so the owner's
// own state follows.
function dismiss(card) {
  if (card.owner && "close" in card.owner) card.owner.close()
  else card.open = false
}
