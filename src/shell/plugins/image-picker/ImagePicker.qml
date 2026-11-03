import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Commons as Commons
import "ImagePickerModel.js" as Model

// The image picker: the images side by side as slanted slices (Slice.qml),
// the chosen one open in the middle, for nova-theme's backgrounds and
// themes or any folder of pictures. A request comes through the shell's
// image-selector IPC target or a summon: the images as rows (a path and its
// thumbnail's) or the folders to list, the image to start on, and two
// files. The choice is written to the answer file, then the done file is
// made, which is what the one asking waits for; a request dismissed or
// replaced gets its done file alone.
Item {
  id: selector

  // ---------------------------------------------------------------- the request

  // Where its images come from, which to start on, where the answer goes.
  // A request with no done file has no one waiting on it.
  property string dirs: Quickshell.env("NOVA_IMAGE_SELECTOR_DIRS") || Quickshell.env("NOVA_IMAGE_SELECTOR_DIR")
    || Quickshell.env("NOVA_STOCK_BACKGROUNDS_DIR")
    || Commons.Color.stateHome + "/nova/current/theme/backgrounds"
  property string startOn: Quickshell.env("NOVA_IMAGE_SELECTOR_SELECTED")
  property string answerFile: Quickshell.env("NOVA_IMAGE_SELECTOR_SELECTION_FILE") || Quickshell.env("NOVA_BACKGROUND_SELECTION_FILE")
  property string doneFile: ""
  property bool waiting: false
  property bool showLabels: false
  property bool filterable: false
  // One more at every request: what arrives for an older one (a folder's
  // listing, rows parsed a turn later, an answer written) is let go.
  property int serial: 0

  // The images, the rows they were parsed from, the one chosen, the filter.
  property var images: []
  property string parsedRows: ""
  property bool loaded: false
  property int chosen: 0
  property string query: ""
  readonly property var positions: Model.positions(images, query)
  readonly property int chosenPosition: positions[chosen] >= 0 ? positions[chosen] : 0

  // Open, and laid out: the slices show once the images are in and placed.
  property bool opened: false
  property bool settled: false
  onOpenedChanged: if (!opened) settled = false

  // The picker stays loaded, so that it opens at once, and with it every
  // slice's decoded thumbnail and texture: some 30 screen-sized images, a
  // lot to hold for a picker that is shut, on a 4 GB Raspberry Pi most of
  // all. Shut for two minutes, it lets them go; the next open decodes the
  // slices near the chosen one again.
  property bool thumbnailsReleased: false
  Timer {
    interval: 120000
    running: !selector.opened && !selector.thumbnailsReleased
    onTriggered: selector.thumbnailsReleased = true
  }

  // The shell's summon and hide; open() takes the request as JSON.
  function open(payload) {
    var request = {}
    try {
      request = JSON.parse(payload || "{}") || {}
    } catch (e) {
      request = {}
    }
    start(String(request.imageDirs || dirs), String(request.imageRows || ""), String(request.selectedImage || startOn),
      String(request.selectionFile || ""), String(request.doneFile || ""), isTrue(request.showLabels), isTrue(request.filterable))
  }

  function close() {
    cancel()
  }

  function isTrue(value) {
    return value === true || value === "true"
  }

  // A new request, over whatever was open: one still waiting gets its done
  // file. Rows already parsed show at once; new rows a turn later, the
  // window up meanwhile; folders once they are listed.
  function start(fromDirs, rows, startOnImage, answer, done, labels, filter) {
    if (waiting && doneFile && doneFile !== done) markDone(doneFile)
    serial++
    thumbnailsReleased = false
    dirs = fromDirs
    startOn = startOnImage
    answerFile = answer
    doneFile = done
    waiting = !!done
    showLabels = labels
    filterable = filter
    query = ""
    settled = false

    if (rows && rows === parsedRows && images.length > 0) {
      chosen = Model.indexOf(images, startOn)
      loaded = true
      opened = true
      settleFor(serial)
    } else if (rows) {
      var forSerial = serial
      images = []
      chosen = 0
      loaded = true
      opened = true
      Qt.callLater(function () {
        if (forSerial === selector.serial) selector.useRows(rows)
      })
    } else {
      images = []
      chosen = 0
      loaded = false
      opened = false
      listDirs(serial, fromDirs)
    }
  }

  function useRows(rows) {
    var parsed = Model.parse(rows)
    parsedRows = rows
    chosen = Model.indexOf(parsed, startOn)
    images = parsed
    loaded = true
    opened = true
    settleFor(serial)
  }

  // The slices show, and take the keys, a turn after the images are in,
  // once laid out, if the request is still the same.
  function settleFor(forSerial) {
    Qt.callLater(function () {
      if (forSerial === selector.serial && selector.opened && selector.loaded && selector.images.length > 0) {
        selector.settled = true
        selector.takeKeys()
      }
    })
  }

  function takeKeys() {
    if (opened && loaded && settled) carousel.forceActiveFocus()
  }

  // ---------------------------------------------------------------- the choice

  // The chosen image's path, or "" when the filter hides it.
  function choice() {
    if (images.length === 0 || !keeps(chosen)) return ""
    return images[chosen].path
  }

  function caption() {
    var path = choice()
    if (!path) return query ? "No matches" : ""
    return Model.captionOf(path)
  }

  function keeps(index) {
    return index >= 0 && index < images.length && Model.keeps(images[index], query)
  }

  function choose(index) {
    if (images.length === 0) return
    index = Math.max(0, Math.min(images.length - 1, index))
    if (keeps(index)) chosen = index
  }

  // The next image the filter keeps, one way or the other, round the end.
  function step(direction) {
    var count = images.length
    var index = chosen
    for (var i = 0; i < count; i++) {
      index = (index + direction + count) % count
      if (keeps(index)) {
        choose(index)
        return
      }
    }
  }

  // A new filter; if it hides the chosen image, the first it keeps is
  // chosen.
  function search(text) {
    query = text
    if (keeps(chosen)) return
    var first = Model.firstKept(images, query)
    if (first >= 0) chosen = first
  }

  // The chosen image is the answer: written, then the done file made, and
  // the picker shut once both are, unless another request came meanwhile.
  function accept() {
    var path = choice()
    if (!path || !answerFile) {
      cancel()
      return
    }
    answering.forSerial = serial
    answering.command = ["bash", "-c", "printf '%s\\n' \"$1\" >\"$2\"; : >\"$3\"", "answer", path, answerFile, doneFile]
    waiting = false
    answerFile = ""
    doneFile = ""
    answering.running = true
  }

  function cancel() {
    if (waiting) markDone(doneFile)
    dropRequest()
    opened = false
  }

  function dropRequest() {
    waiting = false
    answerFile = ""
    doneFile = ""
  }

  // A done file, for a request that ends with no answer.
  function markDone(path) {
    if (path) Quickshell.execDetached(["bash", "-c", ": >\"$1\"", "release", path])
  }

  // ---------------------------------------------------------------- the folders

  // The folders' images, listed by list.sh. A listing asked for while one
  // runs waits for it, and only the latest waits.
  function listDirs(forSerial, fromDirs) {
    if (listing.running) {
      listing.nextSerial = forSerial
      listing.nextDirs = fromDirs
      return
    }
    listing.forSerial = forSerial
    listing.nextSerial = 0
    listing.nextDirs = ""
    listing.command = [Quickshell.env("NOVA_PATH") + "/shell/plugins/image-picker/list.sh", fromDirs]
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
        if (listing.forSerial === selector.serial) selector.useRows(String(text || ""))
      }
    }
    onExited: {
      var queued = nextSerial
      var queuedDirs = nextDirs
      forSerial = 0
      nextSerial = 0
      nextDirs = ""
      if (queued > 0 && queued === selector.serial) selector.listDirs(queued, queuedDirs)
    }
  }

  Process {
    id: answering
    property int forSerial: 0
    onExited: {
      if (forSerial === selector.serial) selector.opened = false
    }
  }

  // ---------------------------------------------------------------- sizes

  // Colours from the [image-picker] section of the theme's shell.toml. The
  // slices not chosen, and the outline of the words, are dimmed with the
  // theme's background itself, not a surface's.
  readonly property color dimColor: Commons.Color.background
  readonly property color ink: Commons.Color.imagePicker.text
  readonly property color selectedBorder: Commons.Color.imagePicker.selectedBorder
  readonly property color unselectedBorder: Commons.Color.imagePicker.unselectedBorder

  // The carousel at full size suits a screen some 770 px tall or more. On
  // a smaller one (a Raspberry Pi's 1024x600 panel) it shrinks, to about
  // 60% of the screen's height; the names and the filter under it keep
  // their size.
  readonly property real fit: {
    if (!(surface.width > 0 && surface.height > 0)) return 1
    var room = Math.min(surface.height * 0.62, surface.height - Style.space(40) - Style.space(30) - wordsHeight)
    return Math.max(0.5, Math.min(1, room / 475, (surface.width - 80) / 768))
  }
  readonly property int expandedWidth: Math.round(768 * fit)
  readonly property int expandedHeight: Math.round(475 * fit)
  readonly property int sliceWidth: Math.round(108 * fit)
  readonly property int sliceHeight: Math.round(432 * fit)
  readonly property int sliceSpacing: Math.round(-30 * fit)
  readonly property int skewOffset: Math.round(28 * fit)
  // From one slice to the next, and the carousel: the open one and six
  // and a half slices each side.
  readonly property real pitch: sliceWidth + sliceSpacing
  readonly property int railWidth: expandedWidth + 13 * pitch
  readonly property real openX: (railWidth - expandedWidth) / 2
  // Under the carousel: the name, the filter, both or neither.
  readonly property int wordsHeight: showLabels ? (filterable ? 104 : 74) : (filterable ? 60 : 30)

  // ---------------------------------------------------------------- the window

  PanelWindow {
    id: surface

    visible: selector.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "nova-image-selector"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: selector.opened && selector.loaded ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      visible: selector.opened && selector.loaded
      color: Commons.Color.imagePicker.scrim
    }

    // A click beside the carousel dismisses it.
    MouseArea {
      anchors.fill: parent
      enabled: selector.opened && selector.loaded
      onClicked: selector.cancel()
    }

    Item {
      anchors.centerIn: parent
      visible: selector.opened && selector.loaded && selector.settled && selector.images.length > 0
      width: Math.min(parent.width - 80, selector.railWidth + 40)
      height: selector.expandedHeight + Style.space(30) + selector.wordsHeight

      MouseArea {
        anchors.fill: parent
        onClicked: {}
      }

      Item {
        id: carousel
        anchors.top: parent.top
        anchors.topMargin: Style.space(30)
        anchors.bottom: parent.bottom
        anchors.bottomMargin: selector.wordsHeight
        anchors.horizontalCenter: parent.horizontalCenter
        width: selector.railWidth
        focus: true
        Component.onCompleted: forceActiveFocus()

        // Escape clears the filter, then closes; Return takes the image;
        // the arrows and Tab go round the images. With a filter, typing is
        // the filter, edited as everywhere in the shell.
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function (event) {
          var key = event.key
          var typed = event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127
            && (event.modifiers === Qt.NoModifier || event.modifiers === Qt.ShiftModifier)
          if (key === Qt.Key_Escape) {
            if (selector.query) selector.search("")
            else selector.cancel()
          } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
            selector.accept()
          } else if (selector.filterable && Util.editsFilter(event, selector.query)) {
            selector.search(Util.editedFilter(event, selector.query))
          } else if (key === Qt.Key_Left || key === Qt.Key_Backtab || (key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
            selector.step(-1)
          } else if (key === Qt.Key_Right || key === Qt.Key_Tab) {
            selector.step(1)
          } else if (selector.filterable && typed) {
            selector.search(selector.query + event.text)
          } else {
            return
          }
          event.accepted = true
        }

        Repeater {
          model: selector.images.length
          delegate: Slice {
            picker: selector
          }
        }
      }

      // The chosen image's name, and under it the filter, outlined in the
      // theme's background so that they read over any picture.
      Text {
        id: name
        anchors.top: carousel.bottom
        anchors.topMargin: Style.space(16)
        anchors.horizontalCenter: carousel.horizontalCenter
        width: selector.expandedWidth
        visible: selector.showLabels
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: selector.caption()
        color: selector.ink
        style: Text.Outline
        styleColor: Util.alpha(selector.dimColor, 0.7)
        font.pixelSize: Style.font.display
        font.weight: Font.DemiBold
        elide: Text.ElideRight
      }

      Text {
        anchors.top: name.bottom
        anchors.topMargin: Style.space(8)
        anchors.horizontalCenter: carousel.horizontalCenter
        width: selector.expandedWidth
        visible: selector.filterable && selector.query
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: selector.query
        color: selector.ink
        opacity: 0.85
        style: Text.Outline
        styleColor: Util.alpha(selector.dimColor, 0.7)
        font.pixelSize: Style.font.title
        elide: Text.ElideRight
      }
    }
  }
}
