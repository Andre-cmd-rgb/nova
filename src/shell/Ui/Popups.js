// The arithmetic BarPopup and PanelSurface share: how big a card may be on
// its screen, and where it may go.
.pragma library

// What a screen <length> long leaves for a card once <near> is taken off one
// end and <far> off the other: never under 120, and 0 until the screen is
// known.
function room(length, near, far) {
  if (length <= 0) return 0
  return Math.max(120, length - near - far)
}

// <want>, held to <room> once the room is known and to <cap> when there is
// one, in whole pixels.
function fit(want, room, cap) {
  let size = want
  if (room > 0) size = Math.min(size, room)
  if (Number(cap) > 0) size = Math.min(size, Number(cap))
  return Math.round(size)
}

// A card for content <width> wide: a pixel at the least.
function cardWidth(width, room, cap) {
  return fit(Math.max(1, Number(width) || 1), room, cap)
}

// A card for content <height> high, with <inset> (border and padding, both
// ends) round it.
function cardHeight(height, inset, room, cap) {
  return fit(inset + Math.max(0, Number(height) || 0), room, cap)
}

// <start> pulled back so that <size> from it stays <margin> inside a span
// <length> long; where it cannot, it keeps the margin at the start.
function within(start, size, length, margin) {
  return Math.max(margin, Math.min(length - size - margin, start))
}

// Closes <card> through its host, so that the host's own state follows,
// or by itself when the host cannot close.
function dismiss(card) {
  if (card.host && typeof card.host.close === "function") card.host.close()
  else card.open = false
}
