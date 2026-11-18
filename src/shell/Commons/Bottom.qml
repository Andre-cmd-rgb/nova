pragma Singleton
import QtQuick
import qs.Commons

// The one place at the bottom of the screen where the shell's pop-ups show:
// the dictation's pill, the on-screen display's card. Each is its own window
// and none draws over another. A pop-up claims the place while it has
// something to show and gives it up when it is done; the one that holds it
// is drawn, the others wait out of sight, and come back when the holder lets
// go. A short-lived message (rank 1) holds it over a long-lived pill (rank
// 0), whichever came first; of the same rank, the newest does.
QtObject {
  id: bottom

  // How far the cards' bottom edge is from the screen's.
  readonly property real foot: Style.space(28)

  // Each claim is { name, rank }, by rank and then by age: the holder's last.
  property var claims: []
  // Who holds the place, "" if nobody.
  readonly property string holder: claims.length ? claims[claims.length - 1].name : ""

  // Takes the place, or takes it again with another rank.
  function claim(name, rank) {
    const rest = claims.filter(c => c.name !== name)
    let at = rest.length
    while (at > 0 && rest[at - 1].rank > rank) at--
    rest.splice(at, 0, { name: name, rank: rank })
    claims = rest
  }

  function release(name) {
    if (claims.some(c => c.name === name)) claims = claims.filter(c => c.name !== name)
  }
}
