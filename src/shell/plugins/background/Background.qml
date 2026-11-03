import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons

// The desktop's background, on every screen (Desktop.qml). A new one comes
// in over the last through a band that widens from the middle, and a
// theme's new colours as its background starts to come in. nova-theme says
// what changed through the background IPC target; at startup, and on
// refresh, the background is the file $XDG_STATE_HOME/nova/current/background
// links to.
Item {
  id: background

  readonly property string link: Commons.Color.stateHome + "/nova/current/background"

  // The background chosen last, by which choosing it again is told apart,
  // and the path it is shown by once it is in: the same file, by a path a
  // theme's next render leaves in place.
  property string chosen: ""
  property string chosenFinal: ""

  // What the screens draw: `shown`, and while a new one comes in,
  // `outgoing` under the band and `incoming` through it. Once it is in,
  // `shown` is the new one, and the band's two images are let go when every
  // screen has drawn it (`settling` until then).
  property string shown: ""
  // The shown image's source, new at each change, as a theme's background
  // can be a new file by the path of the last one, to be read again.
  property url shownSource: ""
  property string outgoing: ""
  property string incoming: ""
  property bool settling: false
  property real progress: 1

  // Each change has a number, and comes in once, started by the first
  // screen to have the new image ready.
  property int serial: 0
  property int revealed: -1

  // A theme's colours and shell settings, held until its background starts
  // to come in.
  property bool themeWaiting: false
  property string waitingColors: ""
  property string waitingShell: ""

  function readLink() {
    if (!linkReader.running) linkReader.running = true
  }

  // <path> brought in over <from>, or over what is shown, then shown by
  // <final>. Choosing again what was chosen last does nothing, unless
  // <force>. With <instant>, or with nothing shown yet, it is shown at once.
  function bring(from, path, final, instant, force) {
    path = String(path || "").trim()
    final = String(final || path).trim()
    from = String(from || "").trim()
    if (!path || (!force && path === chosen)) return
    chosen = path
    chosenFinal = final
    serial++
    revealed = -1
    reveal.stop()
    settling = false

    if (instant || !shown) {
      outgoing = ""
      incoming = ""
      show(final)
      progress = 1
      return
    }
    outgoing = from || shown
    incoming = path
    progress = 0
  }

  function show(path) {
    shown = path
    shownSource = path ? Util.fileUrl(path) + "?v=" + serial : ""
  }

  // The band's images go once every screen has drawn the new one under
  // them, so that none is bare while it loads.
  function settle() {
    if (!settling) return
    for (var i = 0; i < screens.instances.length; i++) {
      if (!screens.instances[i].showing) return
    }
    incoming = ""
    outgoing = ""
    settling = false
  }

  // A background that cannot be read does not come in: what is shown
  // stays, and choosing it again tries again.
  function giveUp() {
    if (!incoming || settling) return
    reveal.stop()
    chosen = ""
    incoming = ""
    outgoing = ""
    progress = 1
    takeTheme()
  }

  function bringWithTheme(from, path, final, colorsB64, shellB64) {
    bring(from, path, final, false, true)
    waitingColors = Util.decodeBase64(colorsB64)
    waitingShell = Util.decodeBase64(shellB64)
    themeWaiting = true
    themeFallback.restart()
    if (!incoming || progress >= 1) takeTheme()
  }

  // Commons.Color.loadShell brings Style along: the type scale changes with
  // the colours.
  function takeTheme() {
    if (!themeWaiting) return
    themeFallback.stop()
    Commons.Color.loadColors(waitingColors)
    Commons.Color.loadShell(waitingShell)
    Style.scheduleRefresh()
    themeWaiting = false
    waitingColors = ""
    waitingShell = ""
  }

  // From the screen that has the new image ready first.
  function startReveal(desktop) {
    if (!incoming) return
    desktop.maskReady = true
    if (revealed === serial) return
    revealed = serial
    takeTheme()
    reveal.restart()
  }

  // A double-click on the desktop: the theme picker for the right button,
  // the background picker for the left. Either may change the link.
  function pick(theme) {
    var picker = theme ? themePicker : backgroundPicker
    if (!picker.running) picker.running = true
  }

  Process {
    id: backgroundPicker
    command: ["nova-theme", "bg", "pick"]
    onExited: background.readLink()
  }

  Process {
    id: themePicker
    command: ["nova-theme", "pick"]
    onExited: background.readLink()
  }

  Process {
    id: linkReader
    command: ["readlink", "-f", background.link]
    stdout: StdioCollector {
      onStreamFinished: background.bring("", text.trim(), "", false, false)
    }
  }

  IpcHandler {
    target: "background"

    function refresh(): void {
      background.readLink()
    }

    function set(path: string): void {
      background.bring("", path, path, false, false)
    }

    function setInstant(path: string): void {
      background.bring("", path, path, true, false)
    }

    function transition(fromPath: string, path: string): void {
      background.bring(fromPath, path, path, false, false)
    }

    function themeTransition(fromPath: string, path: string, finalPath: string, colorsB64: string, shellB64: string): void {
      background.bringWithTheme(fromPath, path, finalPath, colorsB64, shellB64)
    }
  }

  // The theme's colours come in even if no screen gets to start the reveal.
  Timer {
    id: themeFallback
    interval: 300
    onTriggered: background.takeTheme()
  }

  NumberAnimation {
    id: reveal
    target: background
    property: "progress"
    from: 0
    to: 1
    duration: 420
    easing.type: Easing.InOutCubic
    onFinished: {
      background.progress = 1
      if (!background.incoming) return
      background.show(background.chosenFinal || background.incoming)
      background.settling = true
      background.settle()
    }
  }

  Component.onCompleted: readLink()

  Variants {
    id: screens
    model: Quickshell.screens

    Desktop {
      plugin: background
    }
  }
}
