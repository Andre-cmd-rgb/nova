import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import "MediaModel.js" as Media

// The MPRIS players, and the one the media keys, the bar's media widget and
// the audio panel act on: activePlayer. The keys reach it as
// `nova-shell media <action>`, and each action shows on the on-screen
// display.
Item {
  id: root

  property var shell: null

  readonly property var players: Mpris.players ? Mpris.players.values : []

  // ----- playing, heard, chosen -----

  // When each player playing began to, as a count: { key: n }. The player
  // playing longest is the one meant, so a second one starting does not
  // take the keys from the first.
  property var playerStartedAt: ({})
  property int playSerial: 0

  // The player chosen last, by its key: clicked in the widget's list, acted
  // on, or switched to. It goes when its player does.
  property string preferredPlayerKey: ""

  function syncPlayingOrder() {
    var started = {}
    var present = {}
    var serial = playSerial
    for (var i = 0; i < players.length; i++) {
      var key = Media.playerKey(players[i])
      if (!key) continue
      present[key] = true
      if (!players[i].isPlaying) continue
      if (playerStartedAt[key] === undefined) started[key] = ++serial
      else started[key] = playerStartedAt[key]
    }
    if (preferredPlayerKey && !present[preferredPlayerKey]) preferredPlayerKey = ""
    playSerial = serial
    playerStartedAt = started
  }

  function startedAt(player, otherwise) {
    var key = Media.playerKey(player)
    var count = key ? playerStartedAt[key] : undefined
    return count === undefined ? otherwise : count
  }

  Component.onCompleted: syncPlayingOrder()
  onPlayersChanged: syncPlayingOrder()

  Instantiator {
    model: root.players
    delegate: Connections {
      required property var modelData
      target: modelData
      function onIsPlayingChanged() { root.syncPlayingOrder() }
    }
  }

  // Pipewire's playback streams. A player with one is heard, which a player
  // that only says it plays is not.
  readonly property var playbackStreams: {
    var nodes = Pipewire.nodes ? Pipewire.nodes.values : []
    var streams = []
    for (var i = 0; i < nodes.length; i++) {
      if (Media.isPlaybackStream(nodes[i]) && nodes[i].audio) streams.push(nodes[i])
    }
    return streams
  }
  readonly property var streamKeys: playbackStreams.map(function(node) { return Media.nameKey(Media.streamName(node)) })

  PwObjectTracker { objects: root.playbackStreams }

  function isHeard(player) {
    return Media.isHeard(player, streamKeys)
  }

  // The player playing longest, of those heard if `heard`. A proxy only when
  // no player of its own plays.
  function longestPlaying(heard) {
    var own = null
    var ownStart = 0
    var proxy = null
    var proxyStart = 0
    for (var i = 0; i < players.length; i++) {
      var player = players[i]
      if (!player || !player.isPlaying) continue
      if (heard && !isHeard(player)) continue
      var start = startedAt(player, i + 1000)
      if (!Media.isProxy(player)) {
        if (!own || start < ownStart) {
          own = player
          ownStart = start
        }
      } else if (!proxy || start < proxyStart) {
        proxy = player
        proxyStart = start
      }
    }
    return own || proxy || null
  }

  // ----- the players shown -----

  // The one acted on. The player chosen, while it plays; else the one heard
  // playing longest, the one playing longest, the one chosen if heard; and
  // failing those, the first heard, the one chosen, the first with a track,
  // the first that can be controlled, the first with a name. At each step
  // a player of its own comes before a proxy.
  readonly property var activePlayer: {
    var preferred = null
    // The first of each kind, [own, proxy]: heard, with a track,
    // controllable, named. A player counts as its best kind only.
    var first = [[null, null], [null, null], [null, null], [null, null]]
    for (var i = 0; i < players.length; i++) {
      var player = players[i]
      if (!player) continue
      if (preferredPlayerKey && Media.playerKey(player) === preferredPlayerKey && Media.isNamed(player)) preferred = player
      var kind = isHeard(player) ? 0
        : Media.hasTrack(player) ? 1
        : Media.isControllable(player) ? 2
        : Media.isNamed(player) ? 3
        : -1
      var proxy = Media.isProxy(player) ? 1 : 0
      if (kind !== -1 && !first[kind][proxy]) first[kind][proxy] = player
    }
    if (preferred && preferred.isPlaying) return preferred
    return longestPlaying(true) || longestPlaying(false)
      || (preferred && isHeard(preferred) ? preferred : null)
      || first[0][0] || first[0][1] || preferred
      || first[1][0] || first[1][1] || first[2][0] || first[2][1] || first[3][0] || first[3][1] || null
  }

  readonly property bool hasMedia: activePlayer !== null && (activePlayer.trackTitle || activePlayer.trackArtist)

  // The widget's list: every named player, those playing first, longest
  // first, proxies after the rest, then by label.
  readonly property var sourcePlayers: players.filter(Media.isNamed).sort(function(a, b) {
    if (!!a.isPlaying !== !!b.isPlaying) return a.isPlaying ? -1 : 1
    if (Media.isProxy(a) !== Media.isProxy(b)) return Media.isProxy(a) ? 1 : -1
    if (a.isPlaying && b.isPlaying) {
      var sooner = startedAt(a, 1000) - startedAt(b, 1000)
      if (sooner !== 0) return sooner
    }
    return Media.label(a).localeCompare(Media.label(b))
  })

  // What the source keys step through, in a fixed order: proxies last, then
  // by label.
  readonly property var sourceCyclePlayers: players.filter(Media.isSource).sort(function(a, b) {
    if (Media.isProxy(a) !== Media.isProxy(b)) return Media.isProxy(a) ? 1 : -1
    return Media.label(a).localeCompare(Media.label(b))
  })

  function playerKey(player) {
    return Media.playerKey(player)
  }

  function playerForKey(key) {
    if (!key) return null
    for (var i = 0; i < players.length; i++) {
      if (Media.playerKey(players[i]) === key) return players[i]
    }
    return null
  }

  // The widget's list, clicked: that player becomes the one acted on.
  function selectPlayer(key) {
    var player = playerForKey(key)
    if (!player || !Media.isNamed(player)) return false
    preferredPlayerKey = Media.playerKey(player)
    return true
  }

  // ----- actions -----

  // The player an action goes to: the one named by `targetKey`; for
  // playPause, the one playing longest; else the active one if it can, the
  // first in the list that can, or the active one all the same.
  function playerForAction(action, targetKey) {
    var named = playerForKey(targetKey)
    if (named) return named
    if (action === "playPause") {
      var playing = longestPlaying(true) || longestPlaying(false)
      if (playing) return playing
    }
    if (Media.can(activePlayer, action)) return activePlayer
    for (var i = 0; i < sourcePlayers.length; i++) {
      if (Media.can(sourcePlayers[i], action)) return sourcePlayers[i]
    }
    return activePlayer
  }

  // playPause, next or previous: true if a player took it. The player that
  // did becomes the one chosen. With `showFeedback` (the default)
  // the on-screen display says what was done, and after a skip, once the
  // new track is there, what plays.
  function runAction(action, showFeedback, targetKey) {
    var player = playerForAction(action, targetKey)
    var key = Media.playerKey(player)
    var before = Media.trackSignature(player)
    var playing = !!player && player.isPlaying
    var done = false
    var label = "Play/pause"
    var icon = "media"

    if (action === "next") {
      label = "Next"
      icon = "media-next"
      if (player && player.canGoNext) {
        player.next()
        done = true
      }
    } else if (action === "previous") {
      label = "Previous"
      icon = "media-previous"
      if (player && player.canGoPrevious) {
        player.previous()
        done = true
      }
    } else if (action === "playPause") {
      label = playing ? "Pause" : "Play"
      icon = playing ? "media-pause" : "media-play"
      if (player && player.isPlaying && player.canPause) {
        player.pause()
        done = true
      } else if (player && !player.isPlaying && player.canPlay) {
        player.play()
        done = true
      } else if (player && player.canTogglePlaying) {
        player.togglePlaying()
        done = true
      }
    }

    if (done && key) preferredPlayerKey = key
    if (showFeedback !== false) {
      if (done && (action === "next" || action === "previous")) awaitTrack(label, icon, player, before)
      else Qt.callLater(function() { root.showOsd(label, icon, player) })
    }
    return done
  }

  // Play, or with only a toggle, start it.
  function play(player) {
    if (!player) return false
    if (player.canPlay) {
      player.play()
      return true
    }
    if (player.canTogglePlaying && !player.isPlaying) {
      player.togglePlaying()
      return true
    }
    return false
  }

  // Pause, or with only a toggle, stop it.
  function pause(player) {
    if (!player) return false
    if (player.canPause) {
      player.pause()
      return true
    }
    if (player.canTogglePlaying && player.isPlaying) {
      player.togglePlaying()
      return true
    }
    return false
  }

  // The next or previous source by `step`, made the one chosen. It plays in
  // place of the one that was playing, which pauses once it does.
  function switchSource(step) {
    var list = sourceCyclePlayers
    if (list.length === 0) return false

    var current = activePlayer
    var at = 0
    for (var i = 0; i < list.length; i++) {
      if (Media.playerKey(list[i]) === Media.playerKey(current)) {
        at = i
        break
      }
    }
    var next = list[(at + step + list.length) % list.length]
    var wasPlaying = current && current.isPlaying
    preferredPlayerKey = Media.playerKey(next)

    if (wasPlaying && next && Media.playerKey(next) !== Media.playerKey(current)) {
      var playing = next.isPlaying || (next.canPlay && play(next))
      if (playing) pause(current)
    }
    Qt.callLater(function() { root.showOsd("Source", "media-source", next) })
    return true
  }

  // ----- the on-screen display -----

  function showOsd(label, icon, player) {
    if (!shell) return
    shell.summon("nova.osd", JSON.stringify({
      icon: icon || "media",
      message: Media.osdMessage(player || activePlayer, label)
    }))
  }

  // After a skip, the display waits for the new track: up to ten looks, 120
  // ms apart, then it shows what there is.
  property var awaited: null

  function awaitTrack(label, icon, player, before) {
    awaited = { label: label, icon: icon, player: player, key: Media.playerKey(player), before: before, looks: 0 }
    look.restart()
  }

  Timer {
    id: look
    interval: 120
    onTriggered: {
      var wait = root.awaited
      if (!wait) return
      var player = root.playerForKey(wait.key) || wait.player
      if (Media.trackSignature(player) !== String(wait.before || "") || wait.looks >= 10) {
        root.awaited = null
        root.showOsd(wait.label, wait.icon, player)
        return
      }
      wait.looks++
      look.restart()
    }
  }

  // ----- nova-shell media -----

  IpcHandler {
    target: "media"

    function playPause(): string { return root.runAction("playPause") ? "ok" : "unhandled" }
    function next(): string { return root.runAction("next") ? "ok" : "unhandled" }
    function previous(): string { return root.runAction("previous") ? "ok" : "unhandled" }
    // The next or previous source, playback moving over: nova-audio-source-switch.
    function sourceSwitch(): string { return root.switchSource(1) ? "ok" : "unhandled" }
    function sourceSwitchPrevious(): string { return root.switchSource(-1) ? "ok" : "unhandled" }
  }
}
