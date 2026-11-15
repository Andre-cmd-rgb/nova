import QtQuick
import Quickshell
import "plugins/services/media/MediaModel.js" as Model

// The media service's rules: which stream is a player's, a player's track,
// label and words, and what an action does to it. The answers are those of
// the rules as they were before their rewrite.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // JSON leaves out what is undefined, and so does the test's answer.
  function same(one, other) {
    return JSON.stringify(one === undefined ? null : one) === JSON.stringify(other)
  }

  function player(says) {
    const calls = []
    const made = Object.assign({ calls }, says)
    for (const method of ["pause", "play", "togglePlaying", "next", "previous"]) made[method] = () => calls.push(method)
    return made
  }
  function acted(says, action) {
    const one = says === null ? null : player(says)
    return [Model.apply(one, action), one ? one.calls : null]
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    check(same([[{ desktopEntry: "spotify" }, ["spotify"]], [{ identity: "Mozilla Firefox" }, ["firefox"]], [{ identity: "Mozilla Firefox" }, ["mozillafirefoxnightly"]], [{ dbusName: "org.mpris.MediaPlayer2.mpv.instance123" }, ["mpv"]], [{ dbusName: "org.mpris.MediaPlayer2.chromium.instance9" }, ["chromiumbrowser", ""]], [{ desktopEntry: "" }, ["x"]], [{}, ["x"]], [null, ["x"]], [{ desktopEntry: "vlc" }, [null, "", "vlcmediaplayer"]], [{ desktopEntry: "PipeWire ALSA [Spotify]" }, ["spotify"]], [{ desktopEntry: "a" }, []]].map(([p, s]) => Model.heardIn(p, s)), [true,true,true,true,true,false,false,false,true,true,false]), "which stream is a player's")
    check(same([[{ isPlaying: true, canPause: true, canPlay: true, canTogglePlaying: true }, "playPause"], [{ isPlaying: false, canPause: true, canPlay: true }, "playPause"], [{ isPlaying: true, canPause: false, canTogglePlaying: true }, "playPause"], [{ isPlaying: false, canPlay: false, canTogglePlaying: true }, "playPause"], [{ isPlaying: true }, "playPause"], [{ canGoNext: true }, "next"], [{ canGoNext: false }, "next"], [{ canGoPrevious: true }, "previous"], [{}, "previous"], [null, "next"], [null, "playPause"], [{ canGoNext: true }, "stop"]].map(([s, a]) => acted(s, a)), [[true,["pause"]],[true,["play"]],[true,["togglePlaying"]],[true,["togglePlaying"]],[false,[]],[true,["next"]],[false,[]],[true,["previous"]],[false,[]],[false,null],[false,null],[false,[]]]), "what an action does")
    check(same([Model.trackOf(player({ trackTitle: "T", trackArtist: "A" })), Model.trackOf(player({})), Model.trackOf(null), Model.trackOf(player({ trackTitle: "T", trackAlbum: "B", trackArtUrl: "file:///a" }))], ["[\"T\",\"A\",\"\",\"\"]","[\"\",\"\",\"\",\"\"]","","[\"T\",\"\",\"B\",\"file:///a\"]"]), "a player's track")
    check(same([Model.label(player({ trackTitle: "Song", identity: "Spotify" })), Model.label(player({ identity: "Spotify" })), Model.label(player({ desktopEntry: "mpv" })), Model.label(null), Model.osdMessage(player({ trackTitle: "Song", trackArtist: "Band" }), "Play"), Model.osdMessage(player({ trackTitle: "Song" }), "Play"), Model.osdMessage(player({}), "Pause"), Model.osdMessage(null, "Next")], ["Song","Spotify","mpv","","Song - Band","Song","Pause","Next"]), "its label and words")
    check(same([["playPause", true], ["playPause", false], ["next", true], ["previous", false]].map(([a, w]) => Model.feedback(a, w)), [{"words":"Pause","icon":"media-pause"},{"words":"Play","icon":"media-play"},{"words":"Next","icon":"media-next"},{"words":"Previous","icon":"media-previous"}]), "what the display says")
    check(same([Model.can(player({ canGoNext: true }), "next"), Model.can(player({ canPlay: true }), "playPause"), Model.can(player({}), "previous"), Model.can(null, "next"), Model.can(player({ canGoNext: true }), "stop"), Model.playerKey(player({ dbusName: "org.mpris.MediaPlayer2.mpv" })), Model.playerKey(player({ identity: "X" })), Model.playerKey(null)], [true,true,false,false,false,"org.mpris.MediaPlayer2.mpv","X",""]), "what it can do")

    console.log("DONE")
    Qt.quit()
  }
}
