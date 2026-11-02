import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The desktop background, on every screen. A new one is revealed over the
// last in a slanted band widening from the middle; a theme's new colours
// come in as its background's reveal starts. Double-click the desktop for
// the background picker, right double-click for the theme picker.
//
// nova-theme says what changed through the background IPC target; at
// startup the background is the one ~/.local/state/nova/current/background
// links to.
Item {
  id: root

  readonly property string link: Quickshell.env("HOME") + "/.local/state/nova/current/background"

  // The background chosen last, as the path it was given by.
  property string current: ""
  // What the screens show: `shown` under the reveal, `outgoing` revealed
  // over, `incoming` coming in. When the reveal ends `shown` is the new one,
  // `settling` until its image has loaded and the reveal's are let go.
  property string shown: ""
  property string outgoing: ""
  property string incoming: ""
  property bool settling: false
  property real revealProgress: 1
  // Each change of background has a number, and is revealed once, by the
  // first screen to have its image ready.
  property int serial: 0
  property int revealedSerial: -1
  // A theme's colours and shell settings, held until its reveal starts.
  property bool themePending: false
  property string pendingColors: ""
  property string pendingShell: ""

  function refresh() {
    if (!readLink.running) readLink.running = true
  }

  // Reveals <path> over <from> (or over what is shown), and keeps <final>,
  // the same file by another path, as the one chosen. Choosing the one
  // already chosen does nothing, unless <force>. With <instant>, or with
  // nothing shown yet, it is shown at once.
  function change(from, path, final, instant, force) {
    path = String(path || "").trim()
    final = String(final || path).trim()
    from = String(from || "").trim()
    if (!path || (!force && final === current)) return
    current = final
    serial++
    revealedSerial = -1
    reveal.stop()
    settling = false

    if (instant || !shown) {
      outgoing = ""
      incoming = ""
      shown = path
      revealProgress = 1
      return
    }
    outgoing = from || shown
    incoming = path
    revealProgress = 0
  }

  function changeWithTheme(from, path, final, colorsB64, shellB64) {
    change(from, path, final, false, true)
    pendingColors = Util.decodeBase64(colorsB64)
    pendingShell = Util.decodeBase64(shellB64)
    themePending = true
    themeFallback.restart()
    if (!incoming || revealProgress >= 1) applyTheme()
  }

  // Commons.Color.loadShell brings Style along, so the type scale changes
  // with the colours.
  function applyTheme() {
    if (!themePending) return
    themeFallback.stop()
    Commons.Color.loadColors(pendingColors)
    Commons.Color.loadShell(pendingShell)
    Style.scheduleRefresh()
    themePending = false
    pendingColors = ""
    pendingShell = ""
  }

  function startReveal(surface) {
    if (!incoming) return
    surface.maskReady = true
    if (revealedSerial === serial) return
    revealedSerial = serial
    applyTheme()
    reveal.restart()
  }

  Process {
    id: backgroundPicker
    command: ["nova-theme", "bg", "pick"]
    onExited: root.refresh()
  }

  Process {
    id: themePicker
    command: ["nova-theme", "pick"]
    onExited: root.refresh()
  }

  Process {
    id: readLink
    command: ["readlink", "-f", root.link]
    stdout: StdioCollector {
      onStreamFinished: root.change("", text.trim(), "", false, false)
    }
  }

  IpcHandler {
    target: "background"

    function refresh(): void {
      root.refresh()
    }

    function set(path: string): void {
      root.change("", path, path, false, false)
    }

    function setInstant(path: string): void {
      root.change("", path, path, true, false)
    }

    function transition(fromPath: string, path: string): void {
      root.change(fromPath, path, path, false, false)
    }

    function themeTransition(fromPath: string, path: string, finalPath: string, colorsB64: string, shellB64: string): void {
      root.changeWithTheme(fromPath, path, finalPath, colorsB64, shellB64)
    }
  }

  // The theme's colours come in even if no screen gets to reveal.
  Timer {
    id: themeFallback
    interval: 300
    onTriggered: root.applyTheme()
  }

  NumberAnimation {
    id: reveal
    target: root
    property: "revealProgress"
    from: 0
    to: 1
    duration: 420
    easing.type: Easing.InOutCubic
    onFinished: {
      if (root.incoming) {
        root.shown = root.current || root.incoming
        root.settling = true
      }
      root.revealProgress = 1
    }
  }

  Component.onCompleted: refresh()

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: surface
      required property var modelData

      // Whether this screen's mask is drawn for the reveal under way.
      property bool maskReady: false

      // Starts the reveal once the incoming image is loaded here, a turn
      // later, when it is drawn.
      function revealWhenReady() {
        if (!ready()) return
        Qt.callLater(function () {
          if (surface.ready()) root.startReveal(surface)
        })
      }

      function ready() {
        return root.incoming !== "" && root.revealProgress === 0 && !maskReady && incomingImage.status === Image.Ready
      }

      screen: modelData
      visible: !remap.remapping
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      // Always on: a background layer parked with updates off was seen to
      // lose its buffer, a black desktop until the shell restarted.
      updatesEnabled: true
      WlrLayershell.namespace: "nova-background"
      WlrLayershell.layer: WlrLayer.Background
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore

      ScreenMoveRemap {
        id: remap
        window: surface
      }

      // Every image is decoded at the screen's size: a large photo then
      // costs a screen's worth of memory, and an SVG is drawn sharp.
      Image {
        anchors.fill: parent
        source: Util.fileUrl(root.shown)
        sourceSize: Qt.size(width, height)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: true
        onStatusChanged: {
          if (status === Image.Ready && root.settling) {
            root.incoming = ""
            root.outgoing = ""
            root.settling = false
          }
        }
      }

      Image {
        anchors.fill: parent
        visible: root.outgoing !== "" && root.revealProgress < 1
        source: Util.fileUrl(root.outgoing)
        sourceSize: Qt.size(width, height)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        cache: false
        smooth: true
        mipmap: true
        onStatusChanged: surface.revealWhenReady()
      }

      Item {
        anchors.fill: parent
        visible: root.incoming !== "" && incomingImage.status === Image.Ready && (root.revealProgress >= 1 || surface.maskReady)
        layer.enabled: root.incoming !== "" && root.revealProgress < 1
        layer.smooth: true
        layer.effect: MultiEffect {
          maskEnabled: true
          maskSource: band
          maskThresholdMin: 0.5
          maskSpreadAtMin: 0.02
        }

        Image {
          id: incomingImage
          anchors.fill: parent
          source: Util.fileUrl(root.incoming)
          sourceSize: Qt.size(width, height)
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          cache: false
          smooth: true
          mipmap: true
          onStatusChanged: surface.revealWhenReady()
        }
      }

      // The band the new background shows through: leaning a little, as wide
      // as revealProgress makes it, and past both edges at the end.
      Item {
        id: band
        anchors.fill: parent
        visible: false
        layer.enabled: true

        readonly property real slant: -0.18
        readonly property real topMiddle: width / 2 - slant * height / 2
        readonly property real bottomMiddle: width / 2 + slant * height / 2
        readonly property real halfWidth: (width / 2 + Math.abs(slant) * height / 2 + 4) * root.revealProgress

        Shape {
          anchors.fill: parent
          antialiasing: true
          preferredRendererType: Shape.CurveRenderer
          ShapePath {
            fillColor: "white"
            strokeColor: "transparent"
            startX: band.topMiddle - band.halfWidth; startY: 0
            PathLine { x: band.topMiddle + band.halfWidth; y: 0 }
            PathLine { x: band.bottomMiddle + band.halfWidth; y: band.height }
            PathLine { x: band.bottomMiddle - band.halfWidth; y: band.height }
            PathLine { x: band.topMiddle - band.halfWidth; y: 0 }
          }
        }
      }

      Connections {
        target: root
        function onIncomingChanged() {
          surface.maskReady = false
          surface.revealWhenReady()
        }
      }

      MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onDoubleClicked: function (mouse) {
          if (mouse.button === Qt.RightButton) {
            if (!themePicker.running) themePicker.running = true
          } else if (!backgroundPicker.running) {
            backgroundPicker.running = true
          }
          mouse.accepted = true
        }
      }
    }
  }
}
