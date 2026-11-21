import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "StoreModel.js" as Model

// An app's page: its icon, name and summary; Get, or Open and Remove, and
// how far an install is; where it comes from, and the choice of another
// place where it comes from more than one; its pictures, what it says of
// itself, and its facts. The pictures and an Arch package's size (with what
// its recipe installs with it) come from helpers (nova-apps-shots,
// nova-apps-size): the shell reads files and never the network.
//
// The app it is given is the list's, which has what the header and Get need.
// The rest (pictures, description, facts, the sources' versions) is in the
// app's page file, read here, so that the window does not hold it for every
// app. Until it is read, or when it cannot be, the page goes on with the list's.
Column {
  id: page

  property var app: null
  property var store: null
  // The app's page file, as read, or null.
  property var full: null

  // The source picked on the page, "" for the store's first.
  property string picked: ""
  property bool confirming: false
  property var shotFiles: ({})
  property var archSize: null

  // The whole entry once its page is read, else the list's. Both have the
  // same sources in the same order, so what Get installs does not change.
  readonly property var entry: full || app
  readonly property var st: store && app ? store.statusOf(app) : ({ action: "get", progress: -1, text: "", error: "", kept: "" })
  readonly property var from: store && app ? Model.installedFrom(app, store.installed) : null
  readonly property var source: Model.offered(entry, from ? from.kind : picked)
  readonly property var choices: Model.choices(entry)
  readonly property var size: {
    if (!source) return null
    if (source.kind === "flathub")
      return Model.flathubSize(source, full ? full.runtimes : null, store ? store.installed : null)
    return source.kind === "arch" ? archSize : null
  }
  readonly property var facts: entry ? Model.facts(entry, from, source, size) : []
  readonly property real inner: width - leftPadding - rightPadding

  padding: Style.space(28)
  topPadding: Style.space(16)
  spacing: Style.space(22)

  Component.onCompleted: fetchSize()
  onAppChanged: {
    // The list is read again when it is made anew, and gives the same app as another object.
    if (full && (!app || app.id !== full.id)) full = null
  }

  // The pictures are fetched once the page says which they are.
  function fetchShots() {
    var urls = ((full && full.shots) || []).map(function (s) { return s.url })
    if (urls.length > 0) {
      shotsProc.command = ["nova-apps-shots"].concat(urls)
      shotsProc.running = true
    }
  }

  function fetchSize() {
    var arch = Model.offered(app, "arch")
    if (arch && arch.kind === "arch") {
      sizeProc.command = ["nova-apps-size", arch.package].concat(Array.isArray(arch.with) ? arch.with : [])
      sizeProc.running = true
    }
  }

  FileView {
    id: pageFile
    path: page.app && page.app.page && page.store && page.store.catalog && page.store.catalog.pages
      ? page.store.catalog.pages + "/" + page.app.page : ""
    printErrors: false
    onLoaded: {
      // A page that cannot be read is no page: the list's entry stays.
      var read = Model.readPage(text(), page.app)
      if (read) {
        page.full = read
        page.fetchShots()
      }
    }
  }

  Process {
    id: shotsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var files = {}
        String(text).split("\n").forEach(function (line) {
          var tab = line.indexOf("\t")
          if (tab > 0) files[line.slice(0, tab)] = line.slice(tab + 1)
        })
        page.shotFiles = files
      }
    }
  }

  Process {
    id: sizeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parts = String(text).trim().split(" ")
        var download = Number(parts[0]), installed = Number(parts[1])
        if (installed > 0) page.archSize = { download: download, installed: installed }
      }
    }
  }

  component Heading: Text {
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.heading
    font.bold: true
    textFormat: Text.PlainText
  }

  Button {
    iconText: "󰁍"
    text: page.store ? page.store.backLabel : "Back"
    onClicked: page.store.back()
  }

  // ---- the app, and what can be done with it ----------------------------
  Item {
    width: page.inner
    height: Math.max(icon.height, about.implicitHeight)

    AppIcon {
      id: icon
      app: page.app
      size: Style.space(96)
    }

    Column {
      id: about
      anchors.left: icon.right
      anchors.leftMargin: Style.space(20)
      anchors.right: parent.right
      spacing: Style.space(6)

      Text {
        width: parent.width
        text: page.app ? page.app.name : ""
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.display
        font.bold: true
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }

      Text {
        width: parent.width
        visible: text.length > 0
        text: page.app ? page.app.summary || "" : ""
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.subtitle
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }

      Caption {
        width: parent.width
        visible: text.length > 0
        text: page.entry ? page.entry.developer || "" : ""
      }

      Item {
        width: 1
        height: Style.space(4)
      }

      Row {
        spacing: Style.space(8)
        visible: page.st.action !== "busy"

        Button {
          visible: page.st.action === "get"
          width: Math.max(implicitWidth, Style.space(88))
          text: "Get"
          bordered: true
          onClicked: page.store.install(page.app, page.source ? page.source.kind : "")
        }
        Button {
          visible: page.st.action === "open" && page.store.canOpen(page.app)
          width: Math.max(implicitWidth, Style.space(88))
          text: "Open"
          bordered: true
          onClicked: page.store.launch(page.app)
        }
        Button {
          visible: page.st.action === "open" && page.st.removable && !page.confirming
          text: "Remove…"
          bordered: true
          onClicked: page.confirming = true
        }
        Caption {
          anchors.verticalCenter: parent.verticalCenter
          visible: page.st.action === "open" && page.confirming
          text: page.st.removeNote
        }
        Button {
          visible: page.st.action === "open" && page.confirming
          text: "Remove Now"
          bordered: true
          foreground: Commons.Color.urgent
          onClicked: {
            page.confirming = false
            page.store.remove(page.app)
          }
        }
        Button {
          visible: page.st.action === "open" && page.confirming
          text: "Cancel"
          bordered: true
          onClicked: page.confirming = false
        }
      }

      Column {
        visible: page.st.action === "busy"
        width: Math.min(parent.width, Style.space(320))
        spacing: Style.space(6)
        topPadding: Style.space(6)

        ProgressLine {
          width: parent.width
          fraction: page.st.progress
        }
        Caption {
          width: parent.width
          text: page.st.text
        }
      }

      Caption {
        width: parent.width
        visible: text.length > 0
        text: page.st.error || ""
        color: Commons.Color.urgent
        opacity: 1
      }

      Caption {
        width: parent.width
        visible: text.length > 0 && page.st.action === "open"
        text: page.st.kept || ""
      }
    }
  }

  // ---- where from, where there is a choice -----------------------------------
  Row {
    visible: page.choices.length > 0 && page.st.action === "get"
    spacing: Style.space(12)

    Text {
      anchors.verticalCenter: parent.verticalCenter
      text: "From"
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.body
      textFormat: Text.PlainText
    }
    ButtonGroup {
      anchors.verticalCenter: parent.verticalCenter
      options: page.choices
      value: page.source ? page.source.kind : ""
      onChanged: function (value) { page.picked = value }
    }
  }

  // ---- its pictures -----------------------------------------------------------
  ListView {
    id: shots
    visible: count > 0
    width: page.inner
    height: Style.space(260)
    orientation: ListView.Horizontal
    spacing: Style.space(12)
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    model: (page.entry && page.entry.shots) || []

    // A swipe across moves the pictures as the page's moves the page; one up
    // or down over them moves the page.
    TouchpadScroll {
      flickable: shots
      across: true
    }

    delegate: Item {
      id: shot
      required property var modelData
      readonly property string file: page.shotFiles[modelData.url] || ""
      readonly property bool ready: picture.status === Image.Ready && picture.implicitHeight > 0
      height: shots.height
      width: ready ? Math.min(shots.width, Math.round(height * picture.implicitWidth / picture.implicitHeight)) : Math.round(height * 16 / 9)

      Rectangle {
        anchors.fill: parent
        visible: !shot.ready
        radius: Style.cornerRadius
        color: Qt.alpha(Commons.Color.foreground, 0.05)
      }

      Image {
        id: picture
        anchors.fill: parent
        source: shot.file ? Util.fileUrl(shot.file) : ""
        sourceSize.height: Math.ceil(shots.height * 2)
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        smooth: true
        mipmap: true
      }
    }
  }

  // ---- what it says of itself --------------------------------------------------
  Column {
    visible: page.entry && (page.entry.description || []).length > 0
    width: page.inner
    spacing: Style.space(10)

    Repeater {
      model: (page.entry && page.entry.description) || []
      delegate: Text {
        required property var modelData
        width: page.inner
        text: modelData
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        lineHeight: 1.15
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
      }
    }
  }

  // ---- its facts -----------------------------------------------------------------
  Column {
    width: page.inner
    spacing: Style.space(12)

    Heading {
      text: "Information"
    }

    Grid {
      columns: 2
      columnSpacing: Style.space(28)
      rowSpacing: Style.space(8)

      Repeater {
        model: page.facts.reduce(function (all, f) { return all.concat([f.label, f.value]) }, [])
        delegate: Text {
          required property var modelData
          required property int index
          text: modelData
          color: Commons.Color.foreground
          opacity: index % 2 === 0 ? 0.6 : 1
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          textFormat: Text.PlainText
        }
      }
    }

    Button {
      visible: !!(page.entry && page.entry.homepage)
      iconText: "󰖟"
      text: "Website"
      bordered: true
      onClicked: Util.execArgv(["nova-launch-browser", page.entry.homepage])
    }
  }
}
