import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Settings: one window over the commands Nova already has. It owns no
// settings of its own. `nova-settings state` fills it, every change runs the
// same command the CLI offers (nova-theme set, nova battery limit, nova bar
// put, ...), and the window reads the state back afterwards, so what it shows
// is what is set. Wi-Fi, Bluetooth, Mobile Data and Sound have the bar's quick
// menus too; here they have a page each, and Screen Time and Battery Life live
// on theirs rather than in windows of their own.
//
// Summoned by the shell, from the menu or the CLI; `range` is Screen Time's
// and Battery Life's, "today" or "week":
//   nova-shell shell summon nova.settings '{"page":"battery","range":"week"}'
Item {
  id: root

  // Injected by nova-shell.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "nova.settings"

  property bool closingFromHost: false
  // `info`, not `data`: `data` is QQuickItem's default property.
  property var info: ({})
  property bool loaded: false
  property string page: "appearance"
  property string range: "today"
  property bool reloadWanted: false
  property var queue: []
  property string failure: ""
  property string updateStatus: ""
  property bool confirmRecovery: false

  readonly property var appearance: info.appearance || ({})
  readonly property var battery: info.battery || ({})
  readonly property var bar: info.bar || ({})
  readonly property var lock: info.lock || ({})
  readonly property var apps: info.apps || ({})
  readonly property var about: info.about || ({})
  readonly property var updates: info.updates || ({})
  readonly property var limit: battery.limit || ({})
  readonly property var undervolt: battery.undervolt || ({})

  // `group` starts a new group in the sidebar; `radio` is the rfkill type a
  // page needs the hardware for.
  readonly property var allPages: [
    { id: "wifi", label: "Wi-Fi", icon: "󰖩", radio: "wlan" },
    { id: "bluetooth", label: "Bluetooth", icon: "󰂯", radio: "bluetooth" },
    { id: "mobile-data", label: "Mobile Data", icon: "󰞃", radio: "wwan" },
    { id: "sound", label: "Sound", icon: "󰕾", group: true },
    { id: "battery", label: "Battery", icon: "󰁹" },
    { id: "screentime", label: "Screen Time", icon: "󰥔" },
    { id: "appearance", label: "Appearance", icon: "󰸌", group: true },
    { id: "bar", label: "Menu Bar", icon: "󰍜" },
    { id: "lock", label: "Lock Screen", icon: "󰌾" },
    { id: "apps", label: "Default Apps", icon: "󰀻" },
    { id: "updates", label: "Updates", icon: "󰚰", group: true },
    { id: "about", label: "About", icon: "󰋼" }
  ]
  // Until the state is read, every page is offered; then only the ones this
  // computer has the hardware for.
  readonly property var pages: allPages.filter(function (p) {
    if (!root.loaded) return true
    if (p.id === "battery") return root.battery.present === true
    if (p.radio) return (root.info.radios || []).indexOf(p.radio) >= 0
    return true
  })

  readonly property var names: ({
    "power-saver": "Power Saver", "balanced": "Balanced", "performance": "Performance",
    "chrome": "Chrome", "chromium": "Chromium", "firefox": "Firefox", "brave": "Brave",
    "edge": "Edge", "zen": "Zen",
    "code": "VS Code", "cursor": "Cursor", "zed": "Zed", "zeditor": "Zed",
    "sublime_text": "Sublime Text", "helix": "Helix", "nvim": "Neovim", "vim": "Vim", "emacs": "Emacs",
    "foot": "Foot", "alacritty": "Alacritty", "ghostty": "Ghostty", "kitty": "Kitty",
    "top": "Top", "bottom": "Bottom", "left": "Left", "right": "Right"
  })

  function nameOf(value) {
    return names[value] || String(value)
  }

  // ---- lifecycle ----------------------------------------------------------

  function open(payloadJson) {
    closingFromHost = false
    if (payloadJson) {
      try {
        var payload = JSON.parse(String(payloadJson))
        if (payload && allPages.some(function (p) { return p.id === payload.page })) page = payload.page
        if (payload) range = payload.range === "week" ? "week" : "today"
      } catch (e) {
        // An unparseable payload opens the page that was open last.
      }
    }
    confirmRecovery = false
    window.visible = true
    load()
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

  function load() {
    if (stateProc.running) reloadWanted = true
    else stateProc.running = true
  }

  // Changes run one at a time, in order, and the window reloads once the
  // last one is done.
  function run(argv) {
    failure = ""
    var next = queue.slice()
    next.push(argv)
    queue = next
    pump()
  }

  function pump() {
    if (actionProc.running || queue.length === 0) return
    var next = queue.slice()
    actionProc.command = next.shift()
    queue = next
    actionProc.running = true
  }

  // "google-chrome visual-studio-code-bin" -> "Google Chrome and VS Code"
  function appNames(packages) {
    var names = { "google-chrome": "Google Chrome", "visual-studio-code-bin": "VS Code" }
    var out = packages.split(" ").filter(function (p) { return p.length > 0 })
      .map(function (p) { return names[p] || p })
    return out.length > 1 ? out.slice(0, -1).join(", ") + " and " + out[out.length - 1] : out.join("")
  }

  function terminal(command) {
    run(["nova-launch-floating-terminal-with-presentation", command])
  }

  function step(delta) {
    for (var i = 0; i < pages.length; i++) {
      if (pages[i].id === page) {
        page = pages[(i + delta + pages.length) % pages.length].id
        return
      }
    }
    page = pages[0].id
  }

  // ---- formatting ---------------------------------------------------------

  // Memory as the box says: 31.0 GiB usable on a 32 GB machine reads 32 GB.
  function memoryText(bytes) {
    var gib = Number(bytes || 0) / 1073741824
    if (gib <= 0) return "—"
    var power = Math.pow(2, Math.round(Math.log(gib) / Math.LN2))
    return (Math.abs(gib - power) / power < 0.1 ? power : Math.round(gib)) + " GB"
  }

  // Disks the way their makers count, in powers of ten.
  function diskText(bytes) {
    var gb = Number(bytes || 0) / 1e9
    if (gb >= 1000) return (gb / 1000).toFixed(1) + " TB"
    return Math.round(gb) + " GB"
  }

  function options(values, current) {
    var list = (values || []).slice()
    if (current && list.indexOf(current) < 0) list.unshift(current)
    return list.map(function (v) { return { value: v, label: root.nameOf(v) } })
  }

  // ---- processes ----------------------------------------------------------

  Process {
    id: stateProc
    command: ["nova-settings", "state"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text))
          if (parsed && typeof parsed === "object") {
            root.info = parsed
            root.loaded = true
          }
        } catch (e) {
          // A truncated read keeps what is on screen.
        }
      }
    }
    onExited: {
      if (root.reloadWanted) {
        root.reloadWanted = false
        running = true
      }
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector {
      id: actionErrors
      waitForEnd: true
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) {
        var message = String(actionErrors.text || "").trim().split("\n").pop()
        root.failure = message.length > 0 ? message : "That did not work (exit " + exitCode + ")."
      }
      if (root.queue.length > 0) root.pump()
      else root.load()
    }
  }

  Process {
    id: checkProc
    command: ["nova-update-check"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var line = String(text || "").trim()
        if (line.indexOf("available ") === 0) root.updateStatus = "Nova " + line.slice(10) + " is available."
        else if (line.indexOf("apps ") === 0) root.updateStatus = "Nova is up to date. Updates for " + root.appNames(line.slice(5)) + " are available."
        else if (line === "current") root.updateStatus = "Nova and its apps are up to date."
        else root.updateStatus = "Could not check for updates."
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) root.updateStatus = "Could not check for updates."
    }
  }

  // ---- Bluetooth's scan ------------------------------------------------------

  // Bluetooth's page scans for devices while it is open. BlueZ confirms a scan
  // some time after it is asked for, the page can be gone by then, and a write
  // that matches the state BlueZ last reported is not passed on: a stop from
  // the page as it goes misses a scan confirmed after it. So the stop lives
  // here, where it outlasts the page, bound to the confirmed state, as the
  // bar's Bluetooth menu does. Three tries, so a scan some other program keeps
  // starting is not fought forever.
  property bool owesDiscoveryStop: false
  readonly property var bluetoothAdapter: Bluetooth.defaultAdapter

  Timer {
    interval: 1000
    repeat: true
    property int attempts: 0
    running: root.owesDiscoveryStop && !(window.visible && root.page === "bluetooth")
      && !!root.bluetoothAdapter && root.bluetoothAdapter.discovering
    onRunningChanged: if (running) attempts = 0
    onTriggered: {
      attempts += 1
      if (attempts > 3) root.owesDiscoveryStop = false
      else root.bluetoothAdapter.discovering = false
    }
  }

  // Settled the moment BlueZ reports the scan down, however it ended.
  Connections {
    target: root.bluetoothAdapter
    function onDiscoveringChanged() {
      if (!root.bluetoothAdapter.discovering) root.owesDiscoveryStop = false
    }
  }

  // ---- pieces ---------------------------------------------------------------

  component Heading: Text {
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.heading
    font.bold: true
    textFormat: Text.PlainText
  }

  // ---- window -------------------------------------------------------------

  FloatingWindow {
    id: window
    title: "Settings"
    color: Commons.Color.background
    implicitWidth: Style.space(820)
    implicitHeight: Style.space(600)
    minimumSize: Qt.size(Style.space(680), Style.space(480))

    onVisibleChanged: {
      if (!visible && !root.closingFromHost && root.shell && typeof root.shell.hide === "function")
        root.shell.hide(root.pluginId)
    }

    FocusScope {
      id: keys
      anchors.fill: parent
      focus: true

      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) {
          root.requestClose()
          event.accepted = true
        } else if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_Tab || event.key === Qt.Key_PageDown)) {
          root.step(1)
          event.accepted = true
        } else if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_Backtab || event.key === Qt.Key_PageUp)) {
          root.step(-1)
          event.accepted = true
        }
      }

      // ---- sidebar ------------------------------------------------------
      Rectangle {
        id: sidebar
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: Style.space(200)
        color: Qt.alpha(Commons.Color.foreground, 0.03)

        Flickable {
          anchors.fill: parent
          anchors.margins: Style.space(12)
          anchors.topMargin: Style.space(18)
          contentHeight: entries.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          clip: true

          Column {
            id: entries
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.pages

              delegate: Item {
                id: entry
                required property var modelData
                required property int index
                readonly property bool selected: root.page === modelData.id
                readonly property real gap: modelData.group && index > 0 ? Style.space(14) : 0
                width: parent.width
                height: gap + Style.space(32)

                Rectangle {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.bottom: parent.bottom
                  height: Style.space(32)
                  radius: Style.cornerRadius
                  color: entry.selected ? Style.selectedFill : (hover.hovered ? Style.hoverFill : "transparent")

                  HoverHandler { id: hover }
                  TapHandler { onTapped: root.page = entry.modelData.id }

                  Row {
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(10)
                    Text {
                      width: Style.space(18)
                      text: entry.modelData.icon
                      color: entry.selected ? Commons.Color.accent : Commons.Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.icon
                      horizontalAlignment: Text.AlignHCenter
                    }
                    Text {
                      text: entry.modelData.label
                      color: Commons.Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                      font.bold: entry.selected
                    }
                  }
                }
              }
            }
          }
        }
      }

      Rectangle {
        anchors.left: sidebar.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 1
        color: Qt.alpha(Commons.Color.foreground, 0.08)
      }

      // ---- page ---------------------------------------------------------
      ScrollView {
        id: scroll
        anchors.left: sidebar.right
        anchors.leftMargin: 1
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: failureBar.visible ? failureBar.top : parent.bottom
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        // Made only while the window is open: a page reads what it shows as
        // it is made, and stops following it once the window closes.
        Loader {
          id: pageLoader
          width: scroll.availableWidth
          active: window.visible
          sourceComponent: {
            switch (root.page) {
            case "wifi": return wifiPage
            case "bluetooth": return bluetoothPage
            case "mobile-data": return mobileDataPage
            case "sound": return soundPage
            case "bar": return barPage
            case "battery": return batteryPage
            case "screentime": return screenTimePage
            case "lock": return lockPage
            case "apps": return appsPage
            case "updates": return updatesPage
            case "about": return aboutPage
            default: return appearancePage
            }
          }
        }
      }

      Rectangle {
        id: failureBar
        anchors.left: sidebar.right
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        visible: root.failure.length > 0
        height: visible ? failureText.implicitHeight + Style.space(16) : 0
        color: Qt.alpha(Commons.Color.urgent, 0.15)

        Text {
          id: failureText
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.margins: Style.space(16)
          text: root.failure
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
        }
        TapHandler { onTapped: root.failure = "" }
      }
    }
  }

  // ---- pages --------------------------------------------------------------

  // Every page is a column with the same margins and title.
  component Page: Column {
    property alias title: pageTitle.text
    padding: Style.space(28)
    spacing: Style.space(22)
    readonly property real inner: width - leftPadding - rightPadding
    Heading {
      id: pageTitle
      font.pixelSize: Style.font.display
    }
  }

  Component {
    id: wifiPage
    Page {
      id: p
      title: "Wi-Fi"
      WifiView { width: p.inner }
    }
  }

  Component {
    id: bluetoothPage
    Page {
      id: p
      title: "Bluetooth"
      BluetoothView {
        width: p.inner
        onDiscoveryStarted: root.owesDiscoveryStop = true
      }
    }
  }

  Component {
    id: mobileDataPage
    Page {
      id: p
      title: "Mobile Data"
      MobileDataView { width: p.inner }
    }
  }

  Component {
    id: soundPage
    Page {
      id: p
      title: "Sound"
      SoundView { width: p.inner }
    }
  }

  Component {
    id: appearancePage
    Page {
      id: p
      title: "Appearance"

      Section {
        width: p.inner
        title: "THEME"
        Flow {
          width: parent.width
          spacing: Style.space(10)
          Repeater {
            model: root.appearance.themes || []
            delegate: Rectangle {
              id: swatch
              required property var modelData
              readonly property bool current: root.appearance.theme === modelData.name
              width: Style.space(118)
              height: Style.space(70)
              radius: Math.max(4, Style.cornerRadius)
              color: modelData.background || Commons.Color.background
              border.width: current ? 2 : 1
              border.color: current ? Commons.Color.accent : Qt.alpha(Commons.Color.foreground, 0.15)

              Rectangle {
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.margins: Style.space(10)
                width: Style.space(26)
                height: Style.space(6)
                radius: height / 2
                color: swatch.modelData.accent || Commons.Color.accent
              }
              Text {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: Style.space(10)
                text: swatch.modelData.name.replace(/-/g, " ")
                color: swatch.modelData.foreground || Commons.Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                // Two words that do not fit on one line ("catppuccin latte")
                // take two, which the tile has room for.
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
                textFormat: Text.PlainText
              }
              TapHandler { onTapped: if (!swatch.current) root.run(["nova-theme", "set", swatch.modelData.name]) }
            }
          }
        }
      }

      Section {
        width: p.inner
        title: "BACKGROUND"
        Line {
          label: "Background"
          detail: "Each theme has its own; your photos in ~/.config/nova/backgrounds are offered with every theme."
          Row {
            spacing: Style.space(8)
            Button { text: "Next"; bordered: true; onClicked: root.run(["nova-theme", "bg", "next"]) }
            Button { text: "Choose…"; bordered: true; onClicked: root.run(["nova-theme", "bg", "pick"]) }
          }
        }
      }

      Section {
        width: p.inner
        title: "TEXT"
        Line {
          label: "Font"
          detail: "Used by the bar, the menu, terminals and code."
          Dropdown {
            width: Style.spacing.dropdownWidth
            showLabel: false
            options: root.options(root.appearance.fonts, root.appearance.font)
            value: root.appearance.font || ""
            onChanged: function (value) { root.run(["nova-font-set", value]) }
          }
        }
        Line {
          label: "Text size"
          detail: textSize.liveValue + " px, in the shell, apps and terminals"
          PanelSlider {
            id: textSize
            width: Style.space(220)
            minimum: 9
            maximum: 20
            step: 1
            integer: true
            tickCount: 12
            value: Number(root.appearance.textSize || 12)
            onReleased: function (value) { root.run(["nova-display-text-size", String(Math.round(value))]) }
          }
        }
      }
    }
  }

  Component {
    id: barPage
    Page {
      id: p
      title: "Menu Bar"

      Section {
        width: p.inner
        Line {
          label: "Position"
          ButtonGroup {
            options: ["top", "bottom", "left", "right"].map(function (v) { return { value: v, label: root.nameOf(v) } })
            value: root.bar.position || "top"
            onChanged: function (value) { root.run(["nova", "bar", "position", value]) }
          }
        }
        Toggle {
          width: parent.width
          label: "Transparent"
          description: "Let the background show through the bar."
          checked: root.bar.transparent === true
          onClicked: root.run(["nova", "bar", "transparent", checked ? "false" : "true"])
        }
      }

      Section {
        width: p.inner
        title: "IN THE BAR"
        Repeater {
          model: root.bar.widgets || []
          delegate: Toggle {
            required property var modelData
            width: parent.width
            label: modelData.name
            description: modelData.description
            checked: (root.bar.shown || []).indexOf(modelData.id) >= 0
            onClicked: root.run(["nova", "bar", checked ? "remove" : "put", modelData.id])
          }
        }
      }
    }
  }

  Component {
    id: batteryPage
    Page {
      id: p
      title: "Battery"

      BatteryLifeView {
        width: p.inner
        shell: root.shell
        range: root.range
        onRangePicked: function (range) { root.range = range }
      }

      Section {
        width: p.inner
        title: "HEALTH"
        Line {
          label: "Battery health"
          detail: root.battery.health !== null && root.battery.health !== undefined
            ? root.battery.health + "% of its original capacity, after " + (root.battery.cycles || 0) + " charge cycles"
            : "This battery does not report its health."
        }
      }

      Section {
        width: p.inner
        title: "POWER MODE"
        visible: (root.battery.profiles || []).length > 0
        ButtonGroup {
          readonly property var active: (root.battery.profiles || []).filter(function (x) { return x.active })
          options: (root.battery.profiles || []).map(function (x) { return { value: x.name, label: root.nameOf(x.name) } })
          value: active.length > 0 ? active[0].name : ""
          onChanged: function (value) { root.run(["nova-power-profile", "set", value]) }
        }
        Caption {
          width: parent.width
          text: "Remembered separately on battery and plugged in."
        }
      }

      PowerReadout {
        width: p.inner
      }

      Section {
        width: p.inner
        title: "CHARGE LIMIT"
        Toggle {
          width: parent.width
          visible: root.limit.kind === "threshold" || root.limit.kind === "switch"
          label: "Limit charging"
          description: root.limit.kind === "switch"
            ? "Stops charging below full, at a level set by the battery's firmware. Keeps the battery healthy when the computer stays plugged in."
            : "Stops charging at the level below, and starts again 5% under it. Keeps the battery healthy when the computer stays plugged in."
          checked: root.limit.on === true
          onClicked: root.run(["nova-battery-limit", checked ? "off" : (root.limit.kind === "switch" ? "on" : "80")])
        }
        Line {
          visible: root.limit.kind === "threshold" && root.limit.on === true
          label: "Stop charging at"
          detail: limitSlider.liveValue + "%"
          PanelSlider {
            id: limitSlider
            width: Style.space(220)
            minimum: 50
            maximum: 100
            step: 5
            integer: true
            tickCount: 11
            value: Number(root.limit.limit || 80)
            onReleased: function (value) { root.run(["nova-battery-limit", String(Math.round(value))]) }
          }
        }
        Caption {
          width: parent.width
          visible: root.limit.kind !== "threshold" && root.limit.kind !== "switch"
          text: "This battery has no charge limit Nova can set."
        }
      }

      Section {
        width: p.inner
        title: "DISCRETE GPU"
        visible: root.battery.gpu === "auto" || root.battery.gpu === "off"
        ButtonGroup {
          options: [{ value: "auto", label: "On When Plugged In" }, { value: "off", label: "Always Off" }]
          value: root.battery.gpu || ""
          onChanged: function (value) { root.run(["nova-power-gpu", "mode", value]) }
        }
        Caption {
          width: parent.width
          text: root.battery.gpu === "off"
            ? "Off plugged in too, for a cooler, quieter computer. For a game, turn it on from the menu: Toggle, Discrete GPU."
            : "Off the moment you unplug: on battery it would draw several watts doing nothing."
        }
      }

      // Shown once an offset is set (nova power undervolt set): the depth is
      // each CPU's own, found with a stress test, so it is not offered here.
      Section {
        width: p.inner
        title: "UNDERVOLT"
        visible: root.undervolt.state === "applied" || root.undervolt.state === "held" || root.undervolt.state === "pending"
        Line {
          label: String(root.undervolt.offset).replace("-", "\u2212") + " mV on the CPU"
          detail: root.undervolt.state === "applied" ? "On: cooler, and less power for the same work."
            : root.undervolt.state === "held" ? "Held: " + (root.undervolt.reason || "") + "."
            : "Set, but not on the CPU in this boot: systemctl status nova-undervolt says why."
          Row {
            spacing: Style.space(8)
            Button {
              visible: root.undervolt.state !== "applied"
              text: "Apply Again"
              bordered: true
              onClicked: root.run(["nova-power-undervolt", "on"])
            }
            Button { text: "Turn Off"; bordered: true; onClicked: root.run(["nova-power-undervolt", "off"]) }
          }
        }
        Caption {
          width: parent.width
          text: "Taken off by itself after a machine-check error, and at the next start after the computer stopped without shutting down. nova power undervolt set changes it."
        }
      }

      Section {
        width: p.inner
        title: "LID AND POWER BUTTON"
        Line {
          label: "Closing the lid, plugged in"
          visible: root.battery.lid === "sleep" || root.battery.lid === "lock"
          ButtonGroup {
            options: [{ value: "sleep", label: "Sleep" }, { value: "lock", label: "Lock, Keep Running" }]
            value: root.battery.lid || ""
            onChanged: function (value) { root.run(["nova-power-lid", value]) }
          }
        }
        Line {
          label: "Power button"
          ButtonGroup {
            options: [{ value: "menu", label: "Menu" }, { value: "sleep", label: "Sleep" }, { value: "off", label: "Shut Down" }]
            value: root.battery.powerButton || "menu"
            onChanged: function (value) { root.run(["nova-power-button", value]) }
          }
        }
        Line {
          label: "Asleep on battery, hibernate after"
          visible: (root.battery.hibernate || "") !== ""
          ButtonGroup {
            options: [{ value: "1h", label: "1 Hour" }, { value: "2h", label: "2 Hours" }, { value: "4h", label: "4 Hours" }, { value: "never", label: "Never" }]
            value: root.battery.hibernate || ""
            onChanged: function (value) { root.run(["nova-power-hibernate", value]) }
          }
        }
        Caption {
          width: parent.width
          text: "On battery a closed lid always sleeps. Hibernating saves what is open to disk and turns the computer off, so a weekend in a bag does not drain it; the power button brings it all back. Plugged in it never hibernates."
        }
      }
    }
  }

  Component {
    id: screenTimePage
    Page {
      id: p
      title: "Screen Time"

      Section {
        width: p.inner
        Toggle {
          width: parent.width
          label: "Screen Time"
          description: "Counts how long each app is in front of you, per hour and per day. It stays on this computer, and records nothing while it is off."
          checked: root.info.screenTime === true
          onClicked: root.run(["nova-screentime", checked ? "off" : "on"])
        }
      }

      ScreenTimeView {
        width: p.inner
        visible: root.info.screenTime === true
        shell: root.shell
        range: root.range
        onRangePicked: function (range) { root.range = range }
      }

      Caption {
        width: p.inner
        text: "To delete what it recorded: nova screentime forget"
      }
    }
  }

  Component {
    id: lockPage
    Page {
      id: p
      title: "Lock Screen"

      Section {
        width: p.inner
        title: "SCREENSAVER AFTER"
        ButtonGroup {
          readonly property int seconds: Number(root.lock.screensaver === undefined ? 180 : root.lock.screensaver)
          options: [
            { value: "1", label: "1 min" }, { value: "2", label: "2 min" }, { value: "3", label: "3 min" },
            { value: "5", label: "5 min" }, { value: "10", label: "10 min" }, { value: "never", label: "Never" }
          ]
          value: seconds <= 0 ? "never" : String(Math.ceil(seconds / 60))
          onChanged: function (value) { root.run(["nova-idle-screensaver", value]) }
        }
        Caption {
          width: parent.width
          text: "Any key or the mouse ends it. To see it now: nova screensaver"
        }
      }

      Section {
        width: p.inner
        title: "LOCK WHEN UNUSED FOR"
        ButtonGroup {
          readonly property int seconds: Number(root.lock.seconds === undefined ? 300 : root.lock.seconds)
          options: [
            { value: "1", label: "1 min" }, { value: "2", label: "2 min" }, { value: "5", label: "5 min" },
            { value: "10", label: "10 min" }, { value: "15", label: "15 min" }, { value: "30", label: "30 min" },
            { value: "never", label: "Never" }
          ]
          value: seconds <= 0 ? "never" : String(Math.ceil(seconds / 60))
          onChanged: function (value) { root.run(["nova-idle-lock", value]) }
        }
        Caption {
          width: parent.width
          text: "Caffeine, in the bar's indicators (or Super+Ctrl+I), pauses both for as long as it is on."
        }
      }

      Section {
        width: p.inner
        title: "FINGERPRINT"
        visible: root.lock.fingerprint === true
        Line {
          label: "Unlock with your fingerprint"
          detail: "After the first unlock with your password, which also opens your keyring."
          Button { text: "Set Up…"; bordered: true; onClicked: root.terminal("fprintd-enroll") }
        }
      }
    }
  }

  Component {
    id: appsPage
    Page {
      id: p
      title: "Default Apps"

      Section {
        width: p.inner
        Line {
          label: "Web browser"
          detail: "Opens links."
          Dropdown {
            width: Style.spacing.dropdownWidth
            showLabel: false
            options: root.options(root.apps.browsers, root.apps.browser)
            value: root.apps.browser || ""
            onChanged: function (value) { root.run(["nova-default-browser", value]) }
          }
        }
        Line {
          label: "Code editor"
          detail: "Opens files and projects from Nova."
          Dropdown {
            width: Style.spacing.dropdownWidth
            showLabel: false
            options: root.options(root.apps.editors, root.apps.editor === "zeditor" ? "zed" : root.apps.editor)
            value: root.apps.editor === "zeditor" ? "zed" : (root.apps.editor || "")
            onChanged: function (value) { root.run(["nova-default-editor", value]) }
          }
        }
        Line {
          label: "Terminal"
          Dropdown {
            width: Style.spacing.dropdownWidth
            showLabel: false
            options: root.options(root.apps.terminals, root.apps.terminal)
            value: root.apps.terminal || ""
            onChanged: function (value) { root.run(["nova-default-terminal", value]) }
          }
        }
      }
    }
  }

  Component {
    id: updatesPage
    Page {
      id: p
      title: "Updates"

      Section {
        width: p.inner
        Line {
          label: root.about.version ? "Nova " + root.about.version : "Nova"
          detail: root.updateStatus.length > 0 ? root.updateStatus
            : (root.about.archDate ? "Arch Linux as of " + root.about.archDate + ", as tested for this release." : "")
          Row {
            spacing: Style.space(8)
            Button {
              text: checkProc.running ? "Checking…" : "Check"
              bordered: true
              onClicked: if (!checkProc.running) { root.updateStatus = ""; checkProc.running = true }
            }
            Button { text: "Update…"; bordered: true; onClicked: root.terminal("nova update") }
          }
        }
        Caption {
          width: parent.width
          text: "Each release moves the whole system to a tested snapshot of Arch Linux. Before every update, a snapshot of the system is taken. Chrome and VS Code come from Google and Microsoft, and update with it."
        }
      }

      Section {
        width: p.inner
        Toggle {
          width: parent.width
          label: "Test Release Candidates"
          description: "A release comes every other week, first as a candidate for testing. Get each candidate as it comes, two weeks before everyone else."
          checked: root.updates.candidates === true
          onClicked: root.run(["nova-update", "--candidates", checked ? "off" : "on"])
        }
      }

      Section {
        width: p.inner
        title: "RECOVERY"
        Line {
          label: "Check for Problems"
          detail: "Looks the system over and says how to fix what it finds."
          Button { text: "Check…"; bordered: true; onClicked: root.terminal("nova doctor") }
        }
        Line {
          label: "Restart to Recovery"
          detail: root.confirmRecovery
            ? "Restarts now, into the boot menu."
            : "The boot menu: start from a snapshot taken before an update, or with the fallback kernel."
          Button {
            text: root.confirmRecovery ? "Restart Now" : "Restart…"
            bordered: true
            onClicked: {
              if (root.confirmRecovery) root.run(["nova-recovery"])
              else root.confirmRecovery = true
            }
          }
        }
      }
    }
  }

  Component {
    id: aboutPage
    Page {
      id: p
      title: "About"

      Column {
        width: p.inner
        spacing: Style.space(4)
        Text {
          text: "nova"
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.displayLarge * 1.6
          font.bold: true
        }
        Caption {
          width: parent.width
          text: (root.about.version ? "Version " + root.about.version : "")
            + (root.about.release ? "  ·  " + root.about.release : "")
        }
      }

      Section {
        width: p.inner
        Repeater {
          model: [
            { label: "Computer", value: [root.about.vendor === "LENOVO" ? "Lenovo" : (root.about.vendor || ""), root.about.model || ""].join(" ").trim() },
            { label: "Processor", value: root.about.cpu || "" },
            { label: "Memory", value: root.memoryText(root.about.memory) },
            { label: "Storage", value: root.about.disk ? root.diskText(root.about.disk.size) + ", " + root.diskText(root.about.disk.free) + " free" : "" },
            { label: "Name", value: root.about.hostname || "" },
            { label: "Kernel", value: root.about.kernel || "" }
          ]
          delegate: Line {
            required property var modelData
            visible: modelData.value.length > 0
            label: modelData.label
            Text {
              text: modelData.value
              color: Commons.Color.foreground
              opacity: 0.75
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              textFormat: Text.PlainText
            }
          }
        }
      }
    }
  }
}
