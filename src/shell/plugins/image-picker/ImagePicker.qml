import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons
import qs.Commons as Commons
import "ImagePickerModel.js" as Model

// The image picker: the images side by side as slanted slices, the chosen one
// open in the middle, for nova-theme's backgrounds and themes or any folder of
// pictures. A request comes through the shell's image-selector IPC target or
// a summon: the images as rows (a path and its thumbnail's) or the folders to
// list, the image to start on, and two files. The choice goes into the
// selection file, then the done file is made, which is what the one asking
// waits for; a request dismissed or replaced gets its done file alone.
Item {
  id: root

  property string novaPath: Quickshell.env("NOVA_PATH")

  // The request: where its images come from, which to start on, where the
  // answer goes. A request with no done file has no one waiting on it.
  property string imageDirs: Quickshell.env("NOVA_IMAGE_SELECTOR_DIRS") || Quickshell.env("NOVA_IMAGE_SELECTOR_DIR")
    || Quickshell.env("NOVA_STOCK_BACKGROUNDS_DIR")
    || (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/nova/current/theme/backgrounds"
  property string selectedImage: Quickshell.env("NOVA_IMAGE_SELECTOR_SELECTED")
  property string selectionFile: Quickshell.env("NOVA_IMAGE_SELECTOR_SELECTION_FILE") || Quickshell.env("NOVA_BACKGROUND_SELECTION_FILE")
  property string doneFile: ""
  property bool waiting: false
  property bool showLabels: false
  property bool filterable: false
  // One more for every request, preload and close: what arrives for an older
  // one (a folder's listing, rows parsed a turn later, a choice written) is
  // let go.
  property int serial: 0

  // The images, the rows they were parsed from, the one chosen, the filter.
  property var images: []
  property string loadedRows: ""
  property bool loaded: false
  property int selectedIndex: 0
  property string filterText: ""
  readonly property var positions: Model.positions(images, filterText)
  readonly property int selectedPosition: positions[selectedIndex] >= 0 ? positions[selectedIndex] : 0

  // Open, and laid out: the slices show once the images are in and placed.
  property bool opened: false
  property bool settled: false
  onOpenedChanged: if (!opened) settled = false

  // The picker stays loaded, so it opens at once, and with it every slice's
  // decoded thumbnail and texture: some 30 screen-sized images, a lot to hold
  // for a picker that is shut, on a 4 GB Raspberry Pi most of all. Shut for
  // two minutes, it lets them go; the next open decodes the slices near the
  // chosen one again.
  property bool thumbnailsReleased: false
  Timer {
    interval: 120000
    running: !root.opened && !root.thumbnailsReleased
    onTriggered: root.thumbnailsReleased = true
  }

  // Colours from the [image-picker] section of the theme's shell.toml. The
  // slices not chosen, and the outline of the words, are dimmed with the
  // theme's background itself, not a surface's.
  property color dimColor: Commons.Color.background
  property color foreground: Commons.Color.imagePicker.text
  property color scrim: Commons.Color.imagePicker.scrim
  property color selectedBorder: Commons.Color.imagePicker.selectedBorder
  property color unselectedBorder: Commons.Color.imagePicker.unselectedBorder

  // The carousel at full size suits a screen some 770 px tall or more. On a
  // smaller one (a Raspberry Pi's 1024x600 panel) it shrinks, to about 60% of
  // the screen's height; the names and the filter under it keep their size.
  readonly property real fit: {
    if (!(panel.width > 0 && panel.height > 0)) return 1
    var room = Math.min(panel.height * 0.62, panel.height - Style.space(40) - Style.space(30) - bottomChromeHeight)
    return Math.max(0.5, Math.min(1, room / 475, (panel.width - 80) / 768))
  }
  property int expandedWidth: Math.round(768 * fit)
  property int expandedHeight: Math.round(475 * fit)
  property int sliceWidth: Math.round(108 * fit)
  property int sliceHeight: Math.round(432 * fit)
  property int sliceSpacing: Math.round(-30 * fit)
  property int skewOffset: Math.round(28 * fit)
  property int bottomChromeHeight: showLabels ? (filterable ? 104 : 74) : (filterable ? 60 : 30)

  // The shell's summon and hide; open() takes the request as JSON.
  function open(payload) {
    var request = {}
    try {
      request = JSON.parse(payload || "{}") || {}
    } catch (e) {
      request = {}
    }
    begin(String(request.imageDirs || imageDirs), String(request.imageRows || ""), String(request.selectedImage || selectedImage),
      String(request.selectionFile || ""), String(request.doneFile || ""), isTrue(request.showLabels), isTrue(request.filterable))
  }

  function close() {
    cancel()
  }

  // From the image-selector target: rows a theme or background change has
  // just made, parsed now so the next open is at once. While a request is
  // open they would reset it, so they wait for the next.
  function preloadRows(rows, startOn, labels, filter) {
    if (opened || waiting) return
    serial++
    thumbnailsReleased = false
    selectedImage = startOn
    showLabels = isTrue(labels)
    filterable = isTrue(filter)
    filterText = ""
    settled = false
    if (rows && rows === loadedRows && images.length > 0) {
      selectedIndex = Model.indexOf(images, selectedImage)
      loaded = true
    } else if (rows) {
      load(rows, false)
    }
  }

  // From the image-selector target: the one asking gave up, or the shell is
  // closing the picker. Its done file, and the open request's, are made.
  function closeSelector(otherDoneFile) {
    serial++
    if (waiting) release(doneFile)
    if (otherDoneFile && otherDoneFile !== doneFile) release(otherDoneFile)
    forget()
    filterText = ""
    opened = false
  }

  function isTrue(value) {
    return value === true || value === "true"
  }

  // A new request, over whatever was open: one still waiting gets its done
  // file. Rows already parsed show at once; new rows a turn later, the window
  // up meanwhile; folders when they are listed.
  function begin(dirs, rows, startOn, selection, done, labels, filter) {
    if (waiting && doneFile && doneFile !== done) release(doneFile)
    serial++
    thumbnailsReleased = false
    imageDirs = dirs
    selectedImage = startOn
    selectionFile = selection
    doneFile = done
    waiting = !!done
    showLabels = labels
    filterable = filter
    filterText = ""
    settled = false

    if (rows && rows === loadedRows && images.length > 0) {
      selectedIndex = Model.indexOf(images, selectedImage)
      loaded = true
      opened = true
      settle(serial)
    } else if (rows) {
      var forSerial = serial
      images = []
      selectedIndex = 0
      loaded = true
      opened = true
      Qt.callLater(function () {
        if (forSerial === root.serial) root.load(rows, true)
      })
    } else {
      images = []
      selectedIndex = 0
      loaded = false
      opened = false
      list(serial, dirs)
    }
  }

  function load(rows, reveal) {
    var parsed = Model.parse(rows)
    loadedRows = rows
    selectedIndex = Model.indexOf(parsed, selectedImage)
    images = parsed
    loaded = true
    if (reveal) {
      opened = true
      settle(serial)
    }
  }

  // The slices show, and take the keys, a turn after the images are in, once
  // laid out, if the request is still the same.
  function settle(forSerial) {
    Qt.callLater(function () {
      if (forSerial === root.serial && root.opened && root.loaded && root.images.length > 0) {
        root.settled = true
        root.takeKeys()
      }
    })
  }

  function takeKeys() {
    if (opened && loaded && settled) carousel.forceActiveFocus()
  }

  // The chosen image, or "" when the filter hides it.
  function chosenPath() {
    if (images.length === 0 || !keeps(selectedIndex)) return ""
    return images[selectedIndex].path
  }

  function caption() {
    var path = chosenPath()
    if (!path) return filterText ? "No matches" : ""
    return Model.captionOf(path)
  }

  function keeps(index) {
    return index >= 0 && index < images.length && Model.keeps(images[index], filterText)
  }

  function choose(index) {
    if (images.length === 0) return
    index = Math.max(0, Math.min(images.length - 1, index))
    if (keeps(index)) selectedIndex = index
  }

  // The next image the filter keeps, one way or the other, round the end.
  function step(direction) {
    var count = images.length
    var index = selectedIndex
    for (var i = 0; i < count; i++) {
      index = (index + direction + count) % count
      if (keeps(index)) {
        choose(index)
        return
      }
    }
  }

  // A new filter; if it hides the chosen image, the first it keeps is chosen.
  function setFilter(text) {
    filterText = text
    if (keeps(selectedIndex)) return
    var first = Model.firstKept(images, filterText)
    if (first >= 0) selectedIndex = first
  }

  // The chosen image is the answer: written, then the done file made, and the
  // picker shut once both are, unless another request came meanwhile.
  function accept() {
    var path = chosenPath()
    if (!path || !selectionFile) {
      cancel()
      return
    }
    answer.forSerial = serial
    answer.command = ["bash", "-c", "printf '%s\\n' \"$1\" >\"$2\"; : >\"$3\"", "answer", path, selectionFile, doneFile]
    waiting = false
    selectionFile = ""
    doneFile = ""
    answer.running = true
  }

  function cancel() {
    if (waiting) release(doneFile)
    forget()
    opened = false
  }

  function forget() {
    waiting = false
    selectionFile = ""
    doneFile = ""
  }

  // Makes a done file, for a request that ends without a choice.
  function release(path) {
    if (path) Quickshell.execDetached(["bash", "-c", ": >\"$1\"", "release", path])
  }

  // The folders' images, listed by list.sh. A listing asked for while one
  // runs waits for it, and only the latest waits.
  function list(forSerial, dirs) {
    if (listing.running) {
      listing.nextSerial = forSerial
      listing.nextDirs = dirs
      return
    }
    listing.forSerial = forSerial
    listing.nextSerial = 0
    listing.nextDirs = ""
    listing.command = [novaPath + "/shell/plugins/image-picker/list.sh", dirs]
    listing.running = true
  }

  Process {
    id: listing
    property int forSerial: 0
    property int nextSerial: 0
    property string nextDirs: ""
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (listing.forSerial === root.serial) root.load(String(text || ""), true)
      }
    }
    onExited: {
      var queued = nextSerial
      var dirs = nextDirs
      forSerial = 0
      nextSerial = 0
      nextDirs = ""
      if (queued > 0 && queued === root.serial) root.list(queued, dirs)
    }
  }

  Process {
    id: answer
    property int forSerial: 0
    onExited: {
      if (forSerial === root.serial) root.opened = false
    }
  }

  PanelWindow {
    id: panel

    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "nova-image-selector"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened && root.loaded ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      visible: root.opened && root.loaded
      color: root.scrim
    }

    // A click outside the carousel dismisses it.
    MouseArea {
      anchors.fill: parent
      enabled: root.opened && root.loaded
      onClicked: root.cancel()
    }

    Item {
      id: card
      visible: root.opened && root.loaded && root.settled && root.images.length > 0
      width: Math.min(parent.width - 80, root.expandedWidth + 13 * (root.sliceWidth + root.sliceSpacing) + 40)
      height: root.expandedHeight + Style.space(30) + root.bottomChromeHeight
      anchors.centerIn: parent

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: carousel
        anchors.top: parent.top
        anchors.topMargin: Style.space(30)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.bottomChromeHeight
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.expandedWidth + 13 * (root.sliceWidth + root.sliceSpacing)
        focus: true
        Component.onCompleted: forceActiveFocus()

        // Where the open slice starts, and from one slice to the next.
        readonly property real openX: (width - root.expandedWidth) / 2
        readonly property real pitch: root.sliceWidth + root.sliceSpacing

        // Escape clears the filter, then closes; Return takes the image; the
        // arrows and Tab go round the images. With a filter, typing is the
        // filter, edited as everywhere in the shell.
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          var key = event.key
          var typed = event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
            && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)
          if (key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.cancel()
          } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
            root.accept()
          } else if (root.filterable && Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
          } else if (key === Qt.Key_Left || key === Qt.Key_Backtab || (key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
            root.step(-1)
          } else if (key === Qt.Key_Right || key === Qt.Key_Tab) {
            root.step(1)
          } else if (root.filterable && typed) {
            root.setFilter(root.filterText + event.text)
          } else {
            return
          }
          event.accepted = true
        }

        Repeater {
          model: root.images.length

          delegate: Item {
            id: slice
            required property int index

            readonly property var image: root.images[index]
            readonly property string thumbnail: image ? image.thumbnail : ""
            readonly property bool kept: root.positions[index] >= 0
            readonly property bool chosen: kept && index === root.selectedIndex
            // Where it is from the chosen one, among the images the filter
            // keeps: slices more than 16 away are not drawn.
            readonly property int offset: root.positions[index] - root.selectedPosition
            readonly property bool nearby: kept && Math.abs(offset) <= 16

            // A slice loads its thumbnail once it is near the chosen one, and
            // then keeps it, so moving through the carousel does not make Qt
            // drop and decode textures again, until the picker lets them go.
            property bool sourceActivated: nearby
            onNearbyChanged: if (nearby) sourceActivated = true
            Connections {
              target: root
              function onThumbnailsReleasedChanged() {
                if (root.thumbnailsReleased) slice.sourceActivated = slice.nearby
              }
            }

            visible: nearby
            x: chosen ? carousel.openX
              : offset < 0 ? carousel.openX + offset * carousel.pitch
              : carousel.openX + root.expandedWidth + root.sliceSpacing + (offset - 1) * carousel.pitch
            width: chosen ? root.expandedWidth : root.sliceWidth
            height: chosen ? root.expandedHeight : root.sliceHeight
            y: chosen ? 0 : (root.expandedHeight - root.sliceHeight) / 2
            z: chosen ? 100 : 50 - Math.min(Math.abs(offset), 40)

            // The slice's corners: a parallelogram leaning by skewOffset.
            readonly property real lean: Math.abs(root.skewOffset)
            readonly property real topLeft: root.skewOffset >= 0 ? lean : 0
            readonly property real topRight: root.skewOffset >= 0 ? width : width - lean
            readonly property real bottomRight: root.skewOffset >= 0 ? width - lean : width
            readonly property real bottomLeft: root.skewOffset >= 0 ? 0 : lean

            Item {
              id: outline
              anchors.fill: parent
              visible: false
              layer.enabled: true

              Shape {
                anchors.fill: parent
                antialiasing: true
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                  fillColor: "white"
                  strokeColor: "transparent"
                  startX: slice.topLeft; startY: 0
                  PathLine { x: slice.topRight; y: 0 }
                  PathLine { x: slice.bottomRight; y: slice.height }
                  PathLine { x: slice.bottomLeft; y: slice.height }
                  PathLine { x: slice.topLeft; y: 0 }
                }
              }
            }

            Item {
              anchors.fill: parent
              layer.enabled: true
              layer.smooth: true
              layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: outline
                maskThresholdMin: 0.3
                maskSpreadAtMin: 0.3
              }

              Image {
                anchors.fill: parent
                source: !root.thumbnailsReleased && slice.sourceActivated && slice.thumbnail ? Util.fileUrl(slice.thumbnail) : ""
                // Decoded at the open slice's size, the largest any slice is
                // shown, so moving the selection reloads none: the 1536x864
                // thumbnails are made for a 2x screen, and a picture with no
                // thumbnail is the original, which may be a 50-megapixel
                // photo.
                sourceSize: Qt.size(root.expandedWidth, root.expandedHeight)
                fillMode: Image.PreserveAspectCrop
                asynchronous: false
                cache: true
                smooth: true
              }

              Rectangle {
                anchors.fill: parent
                color: Util.alpha(root.dimColor, slice.chosen ? 0 : 0.42)
              }
            }

            Shape {
              anchors.fill: parent
              antialiasing: true
              preferredRendererType: Shape.CurveRenderer
              ShapePath {
                fillColor: "transparent"
                strokeColor: slice.chosen ? root.selectedBorder : root.unselectedBorder
                strokeWidth: slice.chosen ? 3 : 1
                startX: slice.topLeft; startY: 0
                PathLine { x: slice.topRight; y: 0 }
                PathLine { x: slice.bottomRight; y: slice.height }
                PathLine { x: slice.bottomLeft; y: slice.height }
                PathLine { x: slice.topLeft; y: 0 }
              }
            }

            // A click opens a slice; on the open one, takes it.
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: slice.chosen ? root.accept() : root.choose(slice.index)
            }
          }
        }
      }

      Text {
        id: captionText
        textFormat: Text.PlainText
        visible: root.showLabels
        anchors.top: carousel.bottom
        anchors.topMargin: Style.space(16)
        anchors.horizontalCenter: carousel.horizontalCenter
        width: root.expandedWidth
        text: root.caption()
        color: root.foreground
        style: Text.Outline
        styleColor: Util.alpha(root.dimColor, 0.7)
        font.pixelSize: Style.font.display
        font.weight: Font.DemiBold
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        visible: root.filterable && root.filterText
        anchors.top: captionText.bottom
        anchors.topMargin: Style.space(8)
        anchors.horizontalCenter: carousel.horizontalCenter
        width: root.expandedWidth
        text: root.filterText
        color: root.foreground
        opacity: 0.85
        style: Text.Outline
        styleColor: Util.alpha(root.dimColor, 0.7)
        font.pixelSize: Style.font.title
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
      }
    }
  }
}
