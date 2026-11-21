import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Networking
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "WelcomeModel.js" as Model
import "UpdatesModel.js" as Updates
import "Asked.js" as Asked

// The welcome: what an install cannot set, since it runs before there is a
// desktop, a page each. A new account's first unlock opens it (nova welcome
// first), and closing it, on any page, is the account done with it (nova
// welcome done). A page comes only where it matters (WelcomeModel.js): the
// Wi-Fi where there is no network to be on, the theme, the night light,
// VS Code where the install could not build it (it had no internet), and
// the keys. Continue passes any of them by. The pages are Settings' own
// parts, and what they change Settings' commands, run as Settings runs them
// (SettingsState).
//
//   nova-shell shell summon nova.welcome '{"page":"look"}'
Item {
  id: root

  // Injected by the shell.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "nova.welcome"

  property bool closingFromHost: false
  // The window is closed only to come back on this workspace: no one has
  // finished with the welcome.
  property bool moving: false
  property string page: "welcome"
  // The pages gone through, for Back.
  property var history: []
  // Continue, pressed before the state was read, goes on once it is.
  property bool forwardWanted: false
  // Whether the apps page started the run that installs them: an earlier
  // run's end is not the page's to tell.
  property bool installStarted: false

  SettingsState { id: settingsState }
  UpdateRun { id: appsRun }

  readonly property var info: settingsState.info
  readonly property bool onWifi: {
    var devices = Networking.devices ? Networking.devices.values : []
    for (var i = 0; i < devices.length; i++)
      if (devices[i] && devices[i].type === DeviceType.Wifi && devices[i].connected) return true
    return false
  }
  readonly property var facts: ({
    loaded: settingsState.loaded,
    wifi: (info.radios || []).indexOf("wlan") >= 0,
    onWifi: root.onWifi,
    laptop: !!info.battery && info.battery.present === true,
    online: Networking.connectivity === NetworkConnectivity.Full,
    portal: Networking.connectivity === NetworkConnectivity.Portal,
    nightlight: !!root.shell && !!root.shell.serviceFor("nova.nightlight"),
    missing: Model.missing(info.apps),
    installing: appsRun.running
  })
  // The pages that would come now, in order.
  readonly property var pages: Model.order.filter(function (id) { return Model.wanted(id, root.facts) })
    .map(function (id) { return { id: id } })
  readonly property bool last: Model.next(page, facts) === "" && settingsState.loaded

  // ---- lifecycle ----------------------------------------------------------

  // It opens on the page asked for, or else on the first.
  function open(payloadJson) {
    closingFromHost = false
    var payload = {}
    try {
      payload = JSON.parse(String(payloadJson || "{}")) || {}
    } catch (e) {
      // An unparseable payload asks for nothing.
    }
    page = Model.order.indexOf(payload.page) >= 0 ? payload.page : Model.order[0]
    history = []
    forwardWanted = false
    // Open already, on another workspace: it comes to this one, as Settings
    // does.
    if (window.visible && elsewhere()) {
      moving = true
      close()
      moving = false
    }
    if (!window.visible) measureRoom()
    window.visible = true
    settingsState.load()
    Qt.callLater(function () { keys.forceActiveFocus() })
  }

  // The room on the focused screen, as Settings takes it.
  property size room: Qt.size(Style.space(600), Style.space(620))

  function measureRoom() {
    // Hyprland's to answer, as in elsewhere().
    if (!Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")) return
    var name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === name) {
        room = Qt.size(screens[i].width - Style.space(48), screens[i].height - Style.space(80))
        return
      }
    }
  }

  function elsewhere() {
    // Hyprland's to answer, and asked only where there is one: without,
    // Quickshell warns that it has no Hyprland to connect to.
    if (!Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")) return false
    var focused = Hyprland.focusedWorkspace
    return focused !== null && Util.onAnotherWorkspace(Hyprland.toplevels.values, window.title, focused.id)
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

  // Continue: the next page wanted now, or, after the last, the desktop.
  function forward() {
    if (!settingsState.loaded) {
      forwardWanted = true
      return
    }
    forwardWanted = false
    var next = Model.next(page, facts)
    if (next === "") {
      requestClose()
      return
    }
    history = history.concat([page])
    page = next
  }

  function back() {
    if (history.length === 0) return
    page = history[history.length - 1]
    history = history.slice(0, -1)
  }

  Connections {
    target: settingsState
    function onLoadedChanged() { if (settingsState.loaded && root.forwardWanted) root.forward() }
  }

  // The apps installed, or not: Settings' state says which are there now.
  Connections {
    target: appsRun
    function onRunningChanged() { if (!appsRun.running) settingsState.load() }
  }

  // ---- pieces ---------------------------------------------------------------

  component Heading: Text {
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.heading
    font.bold: true
    textFormat: Text.PlainText
  }

  // Four of Appearance's theme tiles across (ThemeView), so that they fill
  // their rows; every page's parts are as wide, in the middle.
  readonly property real column: Style.space(118) * 4 + Style.space(10) * 3

  // ---- window -------------------------------------------------------------

  FloatingWindow {
    id: window
    title: "Welcome to Nova"
    visible: false
    color: Commons.Color.background
    implicitWidth: Math.min(Style.space(600), root.room.width)
    implicitHeight: Math.min(Style.space(620), root.room.height)
    minimumSize: Qt.size(Math.min(Style.space(560), root.room.width), Math.min(Style.space(460), root.room.height))

    onVisibleChanged: {
      if (visible || root.moving) return
      Quickshell.execDetached(["nova-welcome", "done"])
      if (!root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide(root.pluginId)
    }

    FocusScope {
      id: keys
      anchors.fill: parent
      focus: true

      // Return is Continue wherever nothing else takes it: a password field,
      // a focused button or switch.
      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) root.requestClose()
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.forward()
        else return
        event.accepted = true
      }

      ScrollView {
        id: scroll
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: footer.top
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        // Made only while the window is open, as Settings' pages are.
        Loader {
          id: pageLoader
          width: scroll.availableWidth
          active: window.visible

          TouchpadScroll {
            anchors.fill: parent
            z: -1
            flickable: scroll.contentItem
          }
          sourceComponent: {
            switch (root.page) {
            case "wifi": return wifiPage
            case "look": return lookPage
            case "nightlight": return nightLightPage
            case "apps": return appsPage
            case "keys": return keysPage
            default: return welcomePage
            }
          }
        }
      }

      // Back, what went wrong, and Continue, under every page.
      Item {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Math.max(next.implicitHeight, failureText.implicitHeight) + Style.space(40)

        Button {
          id: previous
          anchors.left: parent.left
          anchors.leftMargin: Math.max(Style.space(24), (parent.width - root.column) / 2)
          anchors.verticalCenter: parent.verticalCenter
          visible: root.history.length > 0
          text: "Back"
          bordered: true
          tabStop: true
          onClicked: root.back()
        }

        Caption {
          id: failureText
          anchors.left: previous.right
          anchors.right: next.left
          anchors.margins: Style.space(16)
          anchors.verticalCenter: parent.verticalCenter
          visible: text.length > 0
          text: settingsState.failure
          horizontalAlignment: Text.AlignHCenter
          color: Commons.Color.urgent
          opacity: 1
        }

        Button {
          id: next
          anchors.right: parent.right
          anchors.rightMargin: Math.max(Style.space(24), (parent.width - root.column) / 2)
          anchors.verticalCenter: parent.verticalCenter
          text: root.last ? "Done" : "Continue"
          bordered: true
          selected: true
          tabStop: true
          onClicked: root.forward()
        }
      }
    }
  }

  // ---- pages --------------------------------------------------------------

  // Every page: its sign and its name in the middle, and its parts below,
  // the column's width.
  component Page: Column {
    id: frame
    property string title: ""
    property string icon: ""
    readonly property real inner: Math.min(root.column, width - Style.space(48))
    topPadding: Style.space(40)
    bottomPadding: Style.space(24)
    leftPadding: (width - inner) / 2
    rightPadding: leftPadding
    spacing: Style.space(26)

    Column {
      width: frame.inner
      spacing: Style.space(10)
      Text {
        width: parent.width
        visible: text !== ""
        text: frame.icon
        color: Commons.Color.accent
        font.family: Style.font.family
        font.pixelSize: Style.font.displayLarge * 1.5
        horizontalAlignment: Text.AlignHCenter
      }
      Heading {
        width: parent.width
        visible: text !== ""
        text: frame.title
        font.pixelSize: Style.font.display
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
      }
    }
  }

  Component {
    id: welcomePage
    // The wordmark and the greeting, in the middle of the window.
    Item {
      implicitHeight: Math.max(greeting.implicitHeight + Style.space(80), scroll.availableHeight)
      Column {
        id: greeting
        anchors.centerIn: parent
        spacing: Style.space(32)
        Wordmark {
          anchors.horizontalCenter: parent.horizontalCenter
        }
        Heading {
          anchors.horizontalCenter: parent.horizontalCenter
          text: Model.pages.welcome.title
          font.pixelSize: Style.font.display
        }
      }
    }
  }

  Component {
    id: wifiPage
    Page {
      id: p
      title: Model.pages.wifi.title
      icon: Model.pages.wifi.icon
      WifiView {
        width: p.inner
        details: false
      }
    }
  }

  Component {
    id: lookPage
    Page {
      id: p
      title: Model.pages.look.title
      icon: Model.pages.look.icon
      ThemeView {
        width: p.inner
        appearance: root.info.appearance || ({})
        background: Number((root.info.appearance || {}).backgrounds) > 1
        onCommand: function (argv, changes) { settingsState.run(argv, Asked.under("appearance", changes)) }
      }
    }
  }

  Component {
    id: nightLightPage
    Page {
      id: p
      title: Model.pages.nightlight.title
      icon: Model.pages.nightlight.icon
      NightLightView {
        width: p.inner
        // The page's own name says it.
        title: ""
        shell: root.shell
        settings: root.info.nightlight || ({})
        onCommand: function (argv, changes) { settingsState.run(argv, Asked.under("nightlight", changes)) }
      }
    }
  }

  Component {
    id: appsPage
    Page {
      id: p
      title: Model.pages.apps.title
      icon: Model.pages.apps.icon

      // What the page offered as it opened, named as it was once they are in.
      property var offered: []
      Component.onCompleted: offered = ["visual-studio-code-bin"]
      readonly property var line: Model.apps(root.installStarted || appsRun.running ? appsRun.state : "", appsRun.status, root.facts.missing)

      Section {
        width: p.inner
        Line {
          label: Updates.appList(p.offered)
          detail: p.line.detail
          Button {
            visible: p.line.action !== ""
            text: p.line.action === "retry" ? "Try Again" : "Install"
            bordered: true
            tabStop: true
            onClicked: {
              root.installStarted = true
              appsRun.start(["--apps-only", "--apps-install", "--only", "visual-studio-code-bin"])
            }
          }
        }
        // How far it is; while that is not known (an app building, the
        // password asked for), the track alone.
        Item {
          visible: appsRun.running
          width: parent.width
          height: Style.space(6)
          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius > 0 ? height / 2 : 0
            color: Commons.Color.foreground
            opacity: 0.12
          }
          Rectangle {
            visible: appsRun.fraction > 0
            width: parent.width * appsRun.fraction
            height: parent.height
            radius: Style.cornerRadius > 0 ? height / 2 : 0
            color: Commons.Color.accent
          }
        }
      }
    }
  }

  Component {
    id: keysPage
    Page {
      id: p
      title: Model.pages.keys.title
      icon: Model.pages.keys.icon

      Section {
        width: p.inner
        Repeater {
          model: Model.keys
          delegate: Line {
            id: row
            required property var modelData
            label: modelData.does
            Row {
              spacing: Style.space(4)
              Repeater {
                model: row.modelData.keys
                delegate: Keycap {}
              }
            }
          }
        }
      }
    }
  }

  // The wordmark of the wordmark background, in its colours: the letters the
  // text's, 43% of the way to the background, the spark the accent. Its
  // pixels are read from the wordmark's text (WelcomeModel.wordmark).
  component Wordmark: Item {
    id: mark
    readonly property real pixel: Style.space(6)
    property var art: Model.wordmark("")
    width: art.columns * pixel
    height: art.rows * pixel

    FileView {
      path: (Quickshell.env("NOVA_PATH") || "/usr/share/nova") + "/wordmark/nova.txt"
      printErrors: false
      onLoaded: mark.art = Model.wordmark(text())
    }
    Repeater {
      model: mark.art.runs
      delegate: Rectangle {
        required property var modelData
        x: modelData.x * mark.pixel
        y: modelData.y * mark.pixel
        width: modelData.length * mark.pixel
        height: mark.pixel
        color: modelData.spark ? Commons.Color.accent : Qt.alpha(Commons.Color.foreground, 0.57)
      }
    }
  }

  // A key as it is printed on the keyboard.
  component Keycap: Rectangle {
    required property string modelData
    width: Math.max(height, name.implicitWidth + Style.space(16))
    height: name.implicitHeight + Style.space(10)
    radius: Math.max(4, Style.cornerRadius)
    color: Qt.alpha(Commons.Color.foreground, 0.06)
    border.width: 1
    border.color: Qt.alpha(Commons.Color.foreground, 0.2)
    Text {
      id: name
      anchors.centerIn: parent
      text: parent.modelData
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      textFormat: Text.PlainText
    }
  }
}
