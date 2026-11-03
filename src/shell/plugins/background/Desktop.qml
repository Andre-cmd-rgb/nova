import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// One screen's background: the image shown and, while a new one comes in,
// the last one under it and the new one over it, seen through a band that
// leans a little and widens from the middle. Double-click for the
// background picker, right double-click for the theme picker.
PanelWindow {
  id: desktop

  required property var modelData
  // Background.qml, whose images these are.
  required property var plugin

  // Whether this screen's band is drawn for the reveal under way.
  property bool maskReady: false
  // Whether this screen has the shown image as it is now.
  readonly property bool showing: shownImage.status === Image.Ready && String(shownImage.source) === String(plugin.shownSource)
  onShowingChanged: if (showing) plugin.settle()

  // The new image is loaded here, and the band not yet drawn for it.
  function ready() {
    return plugin.incoming !== "" && plugin.progress === 0 && !maskReady && incomingImage.status === Image.Ready
  }

  // The reveal starts a turn after the new image is ready here, once it is
  // drawn.
  function revealWhenReady() {
    if (!ready()) return
    Qt.callLater(function () {
      if (desktop.ready()) desktop.plugin.startReveal(desktop)
    })
  }

  screen: modelData
  visible: !remap.remapping
  anchors { top: true; bottom: true; left: true; right: true }
  color: "transparent"
  // Always on: a background layer parked with updates off was seen to lose
  // its buffer, a black desktop until the shell restarted.
  updatesEnabled: true
  WlrLayershell.namespace: "nova-background"
  WlrLayershell.layer: WlrLayer.Background
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore

  ScreenMoveRemap {
    id: remap
    window: desktop
  }

  // An image as the screen draws it: over all of it, cropped to fill it,
  // and decoded at its size, off the main thread. A large photo then costs
  // a screen's worth of memory, and an SVG is drawn sharp.
  component ScreenImage: Image {
    anchors.fill: parent
    sourceSize: Qt.size(width, height)
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
  }

  // The two images of a change: kept out of the cache, as they are let go
  // once it is over, and smoothed.
  component ChangeImage: ScreenImage {
    cache: false
    smooth: true
    mipmap: true
  }

  ScreenImage {
    id: shownImage
    source: desktop.plugin.shownSource
    cache: true
  }

  // The last image, under the band.
  ChangeImage {
    visible: desktop.plugin.outgoing !== "" && desktop.plugin.progress < 1
    source: Util.fileUrl(desktop.plugin.outgoing)
    onStatusChanged: desktop.revealWhenReady()
  }

  // The new image, seen through the band while it widens.
  Item {
    anchors.fill: parent
    visible: desktop.plugin.incoming !== "" && incomingImage.status === Image.Ready
      && (desktop.plugin.progress >= 1 || desktop.maskReady)
    layer.enabled: desktop.plugin.incoming !== "" && desktop.plugin.progress < 1
    layer.smooth: true
    layer.effect: MultiEffect {
      maskEnabled: true
      maskSource: band
      maskThresholdMin: 0.5
      maskSpreadAtMin: 0.02
    }

    ChangeImage {
      id: incomingImage
      source: Util.fileUrl(desktop.plugin.incoming)
      onStatusChanged: {
        if (status === Image.Error) desktop.plugin.giveUp()
        else desktop.revealWhenReady()
      }
    }
  }

  // The band: its middle leans by `slant` of the height, its half width
  // grows with the progress, and at the end it is past both edges.
  Item {
    id: band
    anchors.fill: parent
    visible: false
    layer.enabled: true

    readonly property real slant: -0.18
    readonly property real topMiddle: width / 2 - slant * height / 2
    readonly property real bottomMiddle: width / 2 + slant * height / 2
    readonly property real halfWidth: (width / 2 + Math.abs(slant) * height / 2 + 4) * desktop.plugin.progress

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
    target: desktop.plugin
    function onIncomingChanged() {
      desktop.maskReady = false
      desktop.revealWhenReady()
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    onDoubleClicked: function (mouse) {
      desktop.plugin.pick(mouse.button === Qt.RightButton)
      mouse.accepted = true
    }
  }
}
