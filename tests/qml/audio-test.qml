import QtQuick
import Quickshell
import "plugins/panels/audio/Model.js" as Model

// The audio panel's rules: which nodes are outputs, inputs and streams,
// what each is called and shown as, which player a stream is, the volume in
// words, and the keys' cursor. The answers are those of the rules as they
// were before their rewrite.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // JSON leaves out what is undefined, and so does the test's answer.
  function same(one, other) {
    return JSON.stringify(one === undefined ? null : one) === JSON.stringify(other)
  }

  function nodes() {
    return [
      { id: 1, name: "alsa_output.pci", description: "Built-in Audio Analog Stereo Output", isSink: true, isStream: false, audio: {}, ready: true, properties: { "device.icon-name": "audio-card" } },
      { id: 2, name: "bluez_output.buds", description: "Galaxy Buds", nickname: "", isSink: true, isStream: false, audio: {}, ready: true, properties: { "device.icon-name": "audio-headphones-bluetooth", "node.nick": "Buds" } },
      { id: 3, name: "hdmi", description: "HDMI Display Output", isSink: true, isStream: false, audio: {}, ready: false, properties: { "device.icon-name": "video-display" } },
      { id: 4, name: "alsa_input.pci", description: "sof-soundwire Digital Microphones Input", isSink: false, isStream: false, audio: {}, ready: true, properties: {} },
      { id: 5, name: "quickshell", description: "Quickshell", isSink: false, isStream: false, audio: {}, ready: true, properties: {} },
      { id: 6, name: "webcam", description: "C920 Webcam", isSink: false, isStream: false, audio: null, type: "AudioSource", ready: true, properties: { "device.icon-name": "camera-web" } },
      { id: 7, name: "firefox", description: "Firefox", isSink: true, isStream: true, audio: {}, ready: true, properties: { "application.name": "Firefox" } },
      { id: 8, name: "spotify", description: "", isSink: false, isStream: true, type: "PwNodeType.AudioOutStream", audio: {}, ready: true, properties: { "application.name": "audio-src" } },
      { id: 9, name: "nova_speaker_tuning.out", description: "Tuning", isSink: true, isStream: true, audio: {}, ready: true, properties: {} },
      { id: 10, name: "rec", description: "Recorder", isSink: false, isStream: true, type: "AudioInStream", audio: {}, ready: true, properties: {} },
      { id: 11, name: "silent", description: "No audio", isSink: true, isStream: true, audio: null, ready: true, properties: {} },
      null,
      { id: 12, name: "headset_in", description: "USB Headset Input", isSink: false, isStream: false, audio: {}, ready: true, properties: { "device.icon-name": "audio-headset" } },
      { id: 13, name: "bt_in", description: "BT", isSink: false, isStream: false, audio: {}, ready: true, properties: { "device.icon-name": "bluetooth" } }
    ]
  }
  function ids(list) {
    return list.map(n => n.id)
  }
  function players() {
    return [
      { identity: "Spotify", desktopEntry: "spotify", dbusName: "org.mpris.MediaPlayer2.spotify", isPlaying: true, canPlay: true },
      { identity: "Mozilla Firefox", desktopEntry: "firefox", dbusName: "org.mpris.MediaPlayer2.firefox", isPlaying: false, canPlay: true },
      { identity: "playerctld", desktopEntry: "", dbusName: "org.mpris.MediaPlayer2.playerctld", isPlaying: true, canPlay: true }
    ]
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    check(same(ids(Model.sinks(nodes())), [1,2,3]), "the outputs")
    check(same(ids(Model.sources(nodes())), [4,6,12,13]), "the inputs, not the shell's")
    check(same(ids(Model.streams(nodes())), [7,8]), "the streams: playing, with audio, not the tuning")
    check(same(ids(Model.withDefault(Model.sinks(nodes()).slice(1), nodes()[0])).concat(ids(Model.withDefault(Model.sinks(nodes()), nodes()[1])), ids(Model.withDefault([], null))), [1,2,3,2,1,2,3]), "the default first")
    check(same([Model.isPlayback({ isSink: true }), Model.isPlayback({ type: "PwNodeType.AudioOutStream" }), Model.isPlayback({ type: "Output" }), Model.isPlayback({ type: "AudioInStream" }), Model.isPlayback({})], [true,true,true,false,false]), "what a playback stream is")
    check(same([Model.isSource({ audio: {} }), Model.isSource({ type: "AudioSource" }), Model.isSource({ type: "Sink" }), Model.isSource({})], [true,true,false,false]), "what a source is")
    check(same(nodes().filter(n => n).map(n => Model.deviceName(n)), ["Analog Stereo","Buds","HDMI Display","Digital Microphone","Quickshell","C920 Webcam","Firefox","spotify","Tuning","Recorder","No audio","USB Headset","BT"]), "a device's name")
    check(same([Model.deviceName(null), Model.deviceName({ name: "" }), Model.deviceName({ name: "x", nick: " Nick Output " })], ["Unknown","Unknown","Nick"]), "and none")
    check(same(nodes().slice(0, 3).map(n => Model.sinkIcon(n)).concat([Model.sinkIcon(null), Model.sinkIcon({ name: "AirPods Pro" })]), ["󰓃","󰋋","󰍹","󰓃","󰋋"]), "the outputs' glyphs")
    check(same([3, 5, 12, 13].map(i => Model.sourceIcon(nodes()[i])).concat([Model.sourceIcon(null)]), ["󰍬","󰄀","󰋋","󰂯","󰍬"]), "the inputs' glyphs")
    check(same([1, 0.67, 0.5, 0.34, 0.2, 0.01, 0].map(v => Model.speakerIcon(nodes()[0], false, v)).concat([Model.speakerIcon(nodes()[0], true, 1), Model.speakerIcon(nodes()[1], false, 1), Model.speakerIcon(null, false, 1), Model.speakerIcon({ audio: null }, false, 1)]), ["","","","","","","","","󰋋","",""]), "the speaker's glyph by the volume")
    check(same([1, 0.9, 0.85, 0.7, 0.5, 0.49, 0.3, 0.15, 0.14, 0.004, 0, 1.5].map(v => Model.mood(v, false)).concat([Model.mood(0.5, true), Model.mood(0, true)]), ["Concert hall","Party mode","Party mode","Cranked up","Steady groove","Easy listening","Easy listening","Murmur","Whisper","Silenced","Silenced","Concert hall","Muted","Muted"]), "the volume in words")
    check(same([Model.appName(" spotify "), Model.appName("Firefox"), Model.appName(""), Model.appName(null), Model.appName("constructor"), Model.appName("__proto__")], ["Spotify","Firefox","","","constructor","__proto__"]), "applications' names")
    check(same(Model.streams(nodes()).map(n => Model.streamName(n, players(), Model.streams(nodes()))), ["Mozilla Firefox","Spotify"]), "the streams' names")
    check(same(Model.streams(nodes()).map(n => Model.streamName(n, [], Model.streams(nodes()))), ["Firefox","audio-src"]), "with no players")
    check(same(Model.streamName(nodes()[7], [players()[1], players()[2]], Model.streams(nodes())), "playerctld"), "with only the proxy playing")
    check(same(Model.streamName(null, players(), []), "Stream"), "no stream")
    check(same([Model.playsFor(nodes()[7], players()[0], players(), Model.streams(nodes())), Model.playsFor(nodes()[6], players()[1], players(), Model.streams(nodes())), Model.playsFor(nodes()[6], players()[0], players(), Model.streams(nodes())), Model.playsFor(null, players()[0], [], []), Model.playsFor(nodes()[6], null, [], []), Model.playsFor(nodes()[6], { identity: "" }, [], [])], [true,true,false,false,false,false]), "which stream is a player's")
    check(same([Model.move(Model.at("header", 2), 1, { sinks: 2, sources: 1, streams: 1, hasSource: true }), Model.move(Model.at("output", -1), 1, { sinks: 2, sources: 1, streams: 1, hasSource: true }), Model.move(Model.at("output", 1), 1, { sinks: 2, sources: 1, streams: 1, hasSource: true }), Model.move(Model.at("input", 0), 1, { sinks: 2, sources: 1, streams: 1, hasSource: true }), Model.move(Model.at("streams", 0), 1, { sinks: 2, sources: 1, streams: 1, hasSource: true })], [{"section":"output","index":-1},{"section":"output","index":0},{"section":"input","index":-1},{"section":"streams","index":0},{"section":"streams","index":0}]), "the cursor down")
    check(same([Model.move(Model.at("streams", 0), -1, { sinks: 2, sources: 1, streams: 1, hasSource: true }), Model.move(Model.at("streams", 0), -1, { sinks: 2, sources: 0, streams: 1, hasSource: true }), Model.move(Model.at("input", -1), -1, { sinks: 0, sources: 1, streams: 0, hasSource: true }), Model.move(Model.at("output", -1), -1, { sinks: 1, sources: 0, streams: 0 }), Model.move(Model.at("header", 0), -1, { sinks: 1 }), Model.move(Model.at("gone", 3), 1, { sinks: 1 })], [{"section":"input","index":0},{"section":"input","index":-1},{"section":"output","index":-1},{"section":"header","index":-1},{"section":"header","index":0},{"section":"output","index":-1}]), "the cursor up")
    check(same([Model.clamp(Model.at("header", 4), { sinks: 1 }), Model.clamp(Model.at("streams", 3), { sinks: 1, streams: 0 }), Model.clamp(Model.at("output", 5), { sinks: 2 }), Model.clamp(Model.at("input", 0), { sinks: 1, sources: 0, hasSource: true }), Model.clamp(Model.at("output", -1), { sinks: 0 }), Model.clamp(Model.at("streams", 1), { sinks: 1, streams: 3 })], [{"section":"header","index":4},{"section":"output","index":-1},{"section":"output","index":1},{"section":"input","index":-1},{"section":"output","index":-1},{"section":"streams","index":1}]), "the cursor kept")

    console.log("DONE")
    Qt.quit()
  }
}
