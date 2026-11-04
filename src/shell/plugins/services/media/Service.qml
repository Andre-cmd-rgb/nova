import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import "MediaModel.js" as Media

// Nova's media players: the one the media keys, the bar's media widget and
// the audio panel act on (activePlayer), and the list the widget offers.
// The keys come as `nova-shell media <action>`, and what each did shows on
// the on-screen display.
Item {
  id: media

  // Injected by the shell.
  property var shell: null

  readonly property var players: Mpris.players ? Mpris.players.values : []

  // The keys of the players playing, in the order they began to: the one
  // playing longest is the one meant, so that a second one starting does
  // not take the keys from the first.
  property var playOrder: []
  // The player last chosen (picked in the widget's list, acted on, switched
  // to), by its key; forgotten when it goes.
  property string chosenKey: ""

  // Each player and whether it plays, to keep the two above.
  readonly property string lineup: players.map(player => player ? Media.playerKey(player) + (player.isPlaying ? " >" : "") : "").join("\n")
  onLineupChanged: notePlaying()
  Component.onCompleted: notePlaying()

  function notePlaying() {
    var here = players.filter(Boolean).map(Media.playerKey).filter(Boolean)
    var playing = players.filter(player => player && player.isPlaying).map(Media.playerKey).filter(Boolean)
    playOrder = playOrder.filter(key => playing.includes(key)).concat(playing.filter(key => !playOrder.includes(key)))
    if (chosenKey && !here.includes(chosenKey)) chosenKey = ""
  }

  // Pipewire's playback streams, by name. A player one of them belongs to
  // is heard, which a player that only says it plays is not.
  readonly property var playbackStreams: (Pipewire.nodes ? Pipewire.nodes.values : [])
    .filter(node => Media.isPlaybackStream(node) && node.audio)
  readonly property var streamKeys: playbackStreams.map(Media.streamKey)

  PwObjectTracker { objects: media.playbackStreams }

  // The players as the service weighs them. `since` is a player's place in
  // playOrder; one playing that is not in it yet comes after those that are,
  // in the order of the list.
  readonly property var roster: players.map((player, place) => player && {
    player: player,
    key: Media.playerKey(player),
    own: !Media.isProxy(player),
    named: Media.isNamed(player),
    heard: Media.heardIn(player, streamKeys),
    playing: player.isPlaying,
    since: playOrder.includes(Media.playerKey(player)) ? playOrder.indexOf(Media.playerKey(player)) : Infinity,
    place: place
  }).filter(Boolean)

  function entryFor(key) {
    return key ? roster.find(entry => entry.key === key) || null : null
  }

  // Of those that pass, the first of the players' own, else the first proxy.
  function firstOf(test) {
    var passing = roster.filter(test)
    return passing.find(entry => entry.own) || passing[0] || null
  }

  // The player playing longest, of those heard if `heardOnly`; a proxy only
  // when none of the players' own plays.
  function playingLongest(heardOnly) {
    return roster.filter(entry => entry.playing && (entry.heard || !heardOnly))
      .sort(Media.ranked(entry => [entry.own ? 0 : 1, entry.since, entry.place]))[0] || null
  }

  // The chosen player, while it plays. Else the one heard playing longest,
  // the one playing longest, the chosen one if heard; failing those, the
  // first heard, the chosen one, the first with a track, the first that can
  // be controlled, the first with a name.
  readonly property var activePlayer: {
    var chosen = roster.find(entry => chosenKey !== "" && entry.key === chosenKey && entry.named) || null
    if (chosen && chosen.playing) return chosen.player
    var pick = playingLongest(true) || playingLongest(false) || (chosen && chosen.heard ? chosen : null)
      || firstOf(entry => entry.heard) || chosen
      || firstOf(entry => Media.hasTrack(entry.player)) || firstOf(entry => Media.isControllable(entry.player))
      || firstOf(entry => entry.named)
    return pick ? pick.player : null
  }

  // The widget's list: every named player, those playing first and longest
  // first, proxies after the rest, then by label.
  readonly property var listed: roster.filter(entry => entry.named)
    .sort(Media.ranked(entry => [entry.playing ? 0 : 1, entry.own ? 0 : 1, entry.playing ? entry.since : 0, Media.label(entry.player)]))
    .map(entry => entry.player)

  // What the source keys step through, in an order that stays: proxies last,
  // then by label.
  readonly property var cycle: roster.filter(entry => Media.isSource(entry.player))
    .sort(Media.ranked(entry => [entry.own ? 0 : 1, Media.label(entry.player)]))
    .map(entry => entry.player)

  // The widget's list, clicked: that player is the one acted on.
  function choose(player) {
    var entry = entryFor(Media.playerKey(player))
    if (entry && entry.named) chosenKey = entry.key
  }

  // The player an action goes to: the one known by `key`; for playPause the
  // one playing longest; else the active one if it can, the first listed
  // that can, or the active one all the same.
  function target(action, key) {
    var given = entryFor(key)
    if (given) return given.player
    var longest = action === "playPause" ? playingLongest(true) || playingLongest(false) : null
    if (longest) return longest.player
    return [activePlayer].concat(listed).find(player => Media.can(player, action)) || activePlayer
  }

  // playPause, next or previous: true when a player took it, which is then
  // the one chosen. Unless `quiet`, the on-screen display says what was
  // done, after a skip once the next track is there.
  function press(action, quiet, key) {
    var player = target(action, key)
    var track = Media.trackSignature(player)
    var said = Media.feedback(action, !!player && player.isPlaying)
    var done = Media.apply(player, action)
    if (done && Media.playerKey(player)) chosenKey = Media.playerKey(player)
    if (quiet) return done
    if (done && action !== "playPause") trackWait.watch(said, player, track)
    else Qt.callLater(() => announce(said, player))
    return done
  }

  // The source `step` away in the cycle, chosen. If the one before was
  // playing, the new one plays in its place, and the old one pauses once it
  // does.
  function stepSource(step) {
    var list = cycle
    if (list.length === 0) return false
    var current = activePlayer
    var at = Math.max(0, list.findIndex(player => Media.playerKey(player) === Media.playerKey(current)))
    var next = list[(at + step + list.length) % list.length]
    var takesOver = !!current && current.isPlaying && Media.playerKey(next) !== Media.playerKey(current)
    chosenKey = Media.playerKey(next)
    if (takesOver && (next.isPlaying || next.canPlay)) {
      if (!next.isPlaying) next.play()
      Media.halt(current)
    }
    Qt.callLater(() => announce({ words: "Source", icon: "media-source" }, next))
    return true
  }

  function announce(said, player) {
    if (!shell) return
    shell.summon("nova.osd", JSON.stringify({ icon: said.icon, message: Media.osdMessage(player || activePlayer, said.words) }))
  }

  // After a skip: a look every 120 ms for the next track, ten at most, then
  // the display, with whatever there is.
  Timer {
    id: trackWait
    interval: 120

    property var said: null
    // The player skipped, and its key, to find it by should it come back.
    property var player: null
    property string key: ""
    property string before: ""
    property int looks: 0

    function watch(said, player, before) {
      trackWait.said = said
      trackWait.player = player
      trackWait.key = Media.playerKey(player)
      trackWait.before = before
      looks = 0
      restart()
    }

    onTriggered: {
      var entry = media.entryFor(key)
      var now = entry ? entry.player : player
      if (Media.trackSignature(now) === before && looks < 10) {
        looks++
        restart()
      } else {
        media.announce(said, now)
      }
    }
  }

  IpcHandler {
    target: "media"

    function playPause(): string { return media.press("playPause") ? "ok" : "unhandled" }
    function next(): string { return media.press("next") ? "ok" : "unhandled" }
    function previous(): string { return media.press("previous") ? "ok" : "unhandled" }
    // nova-audio-source-switch: the next or previous source, playback
    // moving over.
    function sourceSwitch(): string { return media.stepSource(1) ? "ok" : "unhandled" }
    function sourceSwitchPrevious(): string { return media.stepSource(-1) ? "ok" : "unhandled" }
  }
}
