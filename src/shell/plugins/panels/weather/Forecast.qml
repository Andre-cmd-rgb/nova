import QtQuick
import Quickshell.Io
import qs.Commons as Commons
import "Model.js" as Model

// The weather the bar widget (BarWidget.qml) shows the glyph of and its
// panel (Panel.qml) the rest of: for the place set, else for the town
// wttr.in places the address in.
//
// The place is weather.json, which nova-weather-location writes, watched so
// that an edit by hand counts. wttr.in gives the weather now, the place's
// area and the days ahead; Open-Meteo answers sooner, about coordinates
// (the place's, else its area's), and knows night from day. Both are asked
// every <minutes>, and the last answers stay on show until new ones come.
// The rules are in Model.js.
Item {
  id: forecast

  property int minutes: 15

  // ------------------------------------------------------------- the place

  property var place: Model.readPlace("")
  readonly property bool pinned: Model.hasCoordinates(place)
  readonly property string query: Model.wttrQuery(place)
  // The town wttr.in places the address in, asked while no place is set.
  property string town: ""

  // A new place is asked about at once, from scratch.
  onQueryChanged: {
    if (waiting) asked = true
    restart()
  }

  FileView {
    id: placeFile
    path: Commons.Color.stateHome + "/nova/settings/weather.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: forecast.place = Model.readPlace(text())
    onLoadFailed: forecast.place = Model.readPlace("")
  }

  // The first read can come too early in the shell's start and miss the
  // file; a second, a moment later, changes nothing when the first was right.
  Timer {
    interval: 1500
    running: true
    onTriggered: placeFile.reload()
  }

  function reread() {
    placeFile.reload()
  }

  // ----------------------------------------------------------- the answers

  // The services' last answers, and what wttr.in's was asked about: its
  // area is the place's only while that is still the place asked about.
  property var wttr: null
  property var meteo: null
  property string wttrFrom: ""
  // The weather now's glyph, the widget's too: Open-Meteo's, and until it
  // comes, for a place without coordinates, wttr.in's first.
  property string glyph: ""

  readonly property var area: Model.areaOf(wttr)
  readonly property string country: Model.named(area ? area.country : null)
  readonly property string name: place.name || town || Model.named(area ? area.areaName : null)
  // With a place's coordinates, Open-Meteo's weather now; else wttr.in's,
  // and Open-Meteo's until wttr.in, the slower, answers.
  readonly property var meteoNow: Model.meteoNow(meteo)
  readonly property var now: (pinned && meteoNow) || Model.wttrNow(wttr) || meteoNow
  readonly property var days: Model.forecastDays(wttr, meteo, Qt.formatDate(new Date(), "yyyy-MM-dd"))

  // A null answer from wttr.in is kept, but for a place without coordinates
  // it is a miss, as one that is not JSON is. For such a place wttr.in's
  // first answer gives the glyph, and its area is what Open-Meteo is asked
  // about, now that it is known.
  function readWttr(reading) {
    wttr = reading
    wttrFrom = wttrFetch.asked
    if (!pinned && reading === null) {
      wttrFetch.missed()
      return
    }
    if (!pinned && !glyph) glyph = Model.nowGlyph(Model.wttrNow(reading), "")
    wttrFetch.took()
    if (!pinned) meteoFetch.ask()
  }

  function readMeteo(reading) {
    meteo = reading
    glyph = Model.nowGlyph(Model.meteoNow(reading), glyph)
    meteoFetch.took()
  }

  // ------------------------------------------------------------ the asking

  // Each refresh gives both services their tries back, so that a round that
  // spent them (waking with the network still down) leaves the next its
  // own. With the place's coordinates Open-Meteo is asked at once, not after
  // wttr.in.
  function refresh() {
    wttrFetch.tries = 0
    meteoFetch.tries = 0
    wttrFetch.ask()
    if (query === "") townFetch.ask()
    meteoFetch.ask()
  }

  // Retries left from before go, as the refresh asks anew.
  function restart() {
    wttrFetch.stop()
    meteoFetch.stop()
    Qt.callLater(refresh)
  }

  // wttr.in can be slow, above all about a place it has not been asked
  // about before. A place without coordinates waits for it.
  Fetch {
    id: wttrFetch
    url: Model.wttrUrl(forecast.query)
    seconds: 10
    awaited: !forecast.pinned
    onAnswered: reading => forecast.readWttr(reading)
  }

  // With the place's coordinates, Open-Meteo alone sets the glyph, so an
  // answer lost (waking before the network) is asked for again rather than
  // leave an old glyph until the next refresh; such a place waits for it.
  Fetch {
    id: meteoFetch
    url: Model.meteoUrl(Model.meteoPoint(forecast.place, forecast.wttrFrom === wttrFetch.url ? forecast.area : null))
    seconds: 5
    awaited: forecast.pinned
    onAnswered: reading => forecast.readMeteo(reading)
  }

  Fetch {
    id: townFetch
    url: Model.TOWN_URL
    seconds: 4
    json: false
    onAnswered: text => {
      const town = Model.detectedTown(text)
      if (town !== null) forecast.town = town
    }
  }

  Timer {
    interval: forecast.minutes * 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: forecast.refresh()
  }

  // ------------------------------------------------------ a place being set

  // A place chosen waits, from choose() until the weather it waits on comes
  // or that service's tries are spent: Open-Meteo's for a place with
  // coordinates, else wttr.in's. <asked> once a fetch for it has started;
  // settled() as the wait ends.
  property bool waiting: false
  property bool asked: false

  signal settled()

  // Set at once, and kept by nova-weather-location.
  function choose(chosen) {
    waiting = true
    asked = false
    place = { name: chosen.name, latitude: chosen.latitude, longitude: chosen.longitude }
    keep(chosen.name, chosen.latitude, chosen.longitude)
  }

  // Back to the address's town.
  function forget() {
    keep("", null, null)
    town = ""
  }

  function abandon() {
    waiting = false
    asked = false
  }

  function settle() {
    if (!waiting || !asked) return
    abandon()
    settled()
  }

  function keep(name, latitude, longitude) {
    keeper.command = ["nova-weather-location"].concat(Model.keepArguments(name, latitude, longitude))
    keeper.running = true
  }

  // The file's watch picks the place up. One set again, the same as before,
  // changes no query, so it is asked about here too, or the wait would not
  // end; so too when keeping it failed, with nothing new in the file.
  Process {
    id: keeper
    onExited: code => {
      if (!forecast.waiting) return
      if (code === 0) placeFile.reload()
      if (forecast.asked) return
      forecast.asked = true
      forecast.restart()
    }
  }

  // One service, asked with curl, one request at a time: about <url> ("" is
  // nothing to ask), for <seconds> at most. An answer that is not JSON
  // (when <json>) is a miss, asked again 2.5 s on, three times at most; an
  // answer taken gives the tries back. A place waiting on the service
  // (<awaited>) is settled by an answer taken, or by the tries spent.
  component Fetch: Item {
    id: fetch

    property string url
    property int seconds
    property bool json: true
    property bool awaited: false
    property int tries: 0
    // What the request last made asked about.
    property string asked: ""
    // A request stopped runs on until its process ends, and no other can
    // start meanwhile: as it ends, it is no miss, and the fetch asks again
    // at once, about what is to be asked now.
    property bool stopped: false

    signal answered(var reading)

    function ask() {
      if (call.running || url === "") return
      asked = url
      call.command = ["curl", "-fsS", "--max-time", String(seconds), url]
      call.running = true
    }

    function took() {
      tries = 0
      if (awaited) forecast.settle()
    }

    function missed() {
      if (tries < 3) {
        tries++
        again.restart()
      } else if (awaited) {
        forecast.settle()
      }
    }

    function stop() {
      tries = 0
      stopped = call.running
      call.running = false
      again.stop()
    }

    Process {
      id: call
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          if (fetch.stopped) {
            fetch.stopped = false
            Qt.callLater(() => fetch.ask())
            return
          }
          const reading = fetch.json ? Model.parsed(text) : text
          if (reading === undefined) fetch.missed()
          else fetch.answered(reading)
        }
      }
    }

    Timer {
      id: again
      interval: 2500
      onTriggered: fetch.ask()
    }
  }
}
