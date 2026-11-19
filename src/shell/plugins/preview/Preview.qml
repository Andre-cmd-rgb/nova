import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "PreviewModel.js" as Model

// Quick Look: the preview Files opens with Space, one file in a floating
// window with nothing else on it but its name. nova-previewer (src/preview)
// takes the request from Files on D-Bus and summons this with the file
// described as one line of JSON; asked again, the window shows the next file
// in place. The window is as large as the file's picture allows on the
// screen; Hyprland rounds it and gives it its border, as for the shell's
// other windows (data/hypr/rules.lua).
//
//   Space, Esc    close
//   arrows        Files moves its selection that way, and asks for it
//   Return        open it in its default app, and close
//
// What Qt cannot show as it is (a PDF's page, a video's frame, a song's cover,
// an image format it does not read) is made a picture by bin/thumb. A text
// shows its first part, and the rest, an icon with the name, kind and size.
Item {
  id: root

  // Injected by nova-shell.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "nova.preview"

  // The file shown (PreviewModel.parse), and the picture made for it.
  property var info: null
  property string thumb: ""
  property bool thumbFailed: false
  // A file Qt could not read as an image, shown through bin/thumb instead.
  property bool converted: false
  property string head: ""
  property bool closingFromHost: false

  readonly property string kind: info ? info.kind : "other"
  // The picture shown: the file itself when Qt reads it, else the made one.
  readonly property string pictureSource: {
    if (!info) return ""
    if (info.kind === "image" && !converted && info.path !== "") return "file://" + info.path
    return thumb !== "" ? "file://" + thumb : ""
  }
  readonly property bool pictured: (kind === "image" || kind === "pdf" || kind === "video" || kind === "audio")
    && picture.status === Image.Ready
  readonly property bool texted: kind === "text" && head !== ""
  readonly property string iconSource: info ? Model.iconFor(info.icon, function (name) { return Quickshell.iconPath(name, true) }) : ""

  // The room on the focused screen, as the App Center takes it: what Hyprland
  // gives a window to fill, less a margin.
  property size room: Qt.size(Style.space(1100), Style.space(700))

  readonly property real headerHeight: Style.space(34)
  readonly property size stage: Model.stage(kind, pictured ? Qt.size(picture.implicitWidth, picture.implicitHeight) : Qt.size(0, 0),
    Qt.size(room.width, room.height - headerHeight), Style.spaceScale)

  // ---- what the shell and the window ask --------------------------------

  function open(payloadJson) {
    var next = Model.parse(payloadJson)
    if (!next) return
    closingFromHost = false
    var same = info && info.uri === next.uri
    info = next
    if (!same) {
      thumb = ""
      thumbFailed = false
      converted = false
      head = ""
      measureRoom()
      loadMore()
    }
    window.visible = true
    Qt.callLater(function () { keys.forceActiveFocus() })
  }

  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }

  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide(root.pluginId)
    else window.visible = false
  }

  // Files moves its selection the way a key points, as GTK numbers the
  // ways: up 2, down 3, left 4, right 5.
  function select(direction) {
    talk(["--method", "org.nova.Previewer.Select", String(direction)])
  }

  function openInApp() {
    if (!info) return
    Quickshell.execDetached(["gio", "open", info.uri])
    requestClose()
  }

  // A call to nova-previewer, which is on the bus while the window is open.
  function talk(words) {
    Quickshell.execDetached(["gdbus", "call", "--session", "--dest", "org.gnome.NautilusPreviewer",
      "--object-path", "/org/gnome/NautilusPreviewer"].concat(words))
  }

  function measureRoom() {
    // Without Hyprland (a test, a smoke run) there is no screen in focus to
    // measure, and the room stays as it was.
    var hyprland = !!Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")
    var name = hyprland && Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === name) {
        room = Qt.size(Math.round(screens[i].width * 0.86), Math.round(screens[i].height * 0.86))
        return
      }
    }
  }

  // What the file needs made or read, once, as it is asked for.
  function loadMore() {
    if (!info || info.path === "") return
    if (info.kind === "pdf" || info.kind === "video" || info.kind === "audio") makeThumb(info.kind)
    else if (info.kind === "text") readHead()
  }

  property var thumbWanted: null
  property string thumbFor: ""

  function makeThumb(kind) {
    thumbWanted = { kind: kind, path: info.path }
    if (thumbProc.running) thumbProc.signal(15)
    else beginThumb()
  }

  function beginThumb() {
    if (!thumbWanted) return
    thumbFor = thumbWanted.path
    thumbProc.command = [Quickshell.shellPath("plugins/preview/bin/thumb"), thumbWanted.kind, thumbWanted.path]
    thumbWanted = null
    thumbProc.running = true
  }

  function readHead() {
    if (headProc.running) headProc.signal(15)
    headProc.command = ["head", "-c", "65536", "--", info.path]
    headProc.running = true
  }

  Process {
    id: thumbProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = String(text).trim()
        if (root.info && root.thumbFor === root.info.path && path !== "") root.thumb = path
        else if (root.info && root.thumbFor === root.info.path) root.thumbFailed = true
      }
    }
    onExited: root.beginThumb()
  }

  Process {
    id: headProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var shown = Model.head(text, 200, 240)
        // A file with a NUL in it is not text: the plain page, as any other.
        if (shown === null) root.head = ""
        else root.head = shown
      }
    }
  }

  // ---- window ---------------------------------------------------------------

  FloatingWindow {
    id: window
    title: "Quick Look"
    visible: false
    color: Commons.Color.background
    implicitWidth: root.stage.width
    implicitHeight: root.stage.height + root.headerHeight
    // The size is the file's, not the user's to change: fixed, the compositor
    // also takes the new size when another file replaces this one, where an
    // implicit size alone it keeps to the first.
    minimumSize: Qt.size(implicitWidth, implicitHeight)
    maximumSize: Qt.size(implicitWidth, implicitHeight)

    onVisibleChanged: {
      if (visible) return
      // The window is gone, however it went: Files is told which file it was.
      if (root.info) root.talk(["--method", "org.nova.Previewer.Closed", String(root.info.seq)])
      if (!root.closingFromHost && root.shell && typeof root.shell.hide === "function") root.shell.hide(root.pluginId)
    }

    FocusScope {
      id: keys
      anchors.fill: parent
      focus: true

      Keys.onPressed: function (event) {
        var direction = event.key === Qt.Key_Up ? 2 : event.key === Qt.Key_Down ? 3
          : event.key === Qt.Key_Left ? 4 : event.key === Qt.Key_Right ? 5 : 0
        if (event.key === Qt.Key_Escape || event.key === Qt.Key_Space) root.requestClose()
        else if (direction > 0) root.select(direction)
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.openInApp()
        else return
        event.accepted = true
      }

      // The name, small, along the top.
      Text {
        id: title
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(16)
        anchors.rightMargin: Style.space(16)
        height: root.headerHeight
        verticalAlignment: Text.AlignVCenter
        horizontalAlignment: Text.AlignHCenter
        text: root.info ? root.info.name : ""
        color: Commons.Color.mutedText
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideMiddle
        textFormat: Text.PlainText
      }

      Item {
        id: content
        anchors.top: title.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        clip: true

        // A picture: an image, a page, a frame, a cover.
        AnimatedImage {
          id: picture
          anchors.fill: parent
          visible: root.kind === "image" || root.kind === "pdf" || root.kind === "video" || root.kind === "audio"
          source: root.pictureSource
          fillMode: Image.PreserveAspectFit
          asynchronous: true
          cache: false
          smooth: true
          // Qt cannot read this image: libvips makes one it can.
          onStatusChanged: {
            if (status === Image.Error && root.kind === "image" && !root.converted && root.info.path !== "") {
              root.converted = true
              root.makeThumb("image")
            }
          }
        }

        // A text's first part.
        Flickable {
          anchors.fill: parent
          visible: root.texted
          contentWidth: body.implicitWidth + Style.space(32)
          contentHeight: body.implicitHeight + Style.space(24)
          boundsBehavior: Flickable.StopAtBounds
          clip: true

          Text {
            id: body
            x: Style.space(16)
            y: Style.space(4)
            text: root.head
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            textFormat: Text.PlainText
            wrapMode: Text.NoWrap
          }
        }

        // Anything else, and a picture or a text that did not come: its icon,
        // and under it the name, the kind and the size.
        Column {
          anchors.centerIn: parent
          width: parent.width - Style.space(48)
          spacing: Style.space(8)
          visible: !root.pictured && !root.texted && !(root.kind === "image" && picture.status === Image.Loading)

          Image {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Style.space(96)
            height: Style.space(96)
            source: root.iconSource
            sourceSize: Qt.size(width * 2, height * 2)
            fillMode: Image.PreserveAspectFit
            smooth: true
            asynchronous: true
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.info ? root.info.name : ""
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            elide: Text.ElideMiddle
            textFormat: Text.PlainText
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.info ? Model.facts(root.info) : ""
            color: Commons.Color.mutedText
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            textFormat: Text.PlainText
          }
        }
      }
    }
  }
}
