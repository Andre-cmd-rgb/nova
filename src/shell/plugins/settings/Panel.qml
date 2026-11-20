import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Hyprland
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Asked.js" as Asked

// Settings: one window over the commands Nova already has. It owns no
// settings of its own. `nova-settings state` fills it, every change runs the
// same command the CLI offers (nova-theme set, nova battery limit, nova bar
// put, ...), and the window reads the state back afterwards, so what it shows
// is what is set. Wi-Fi, Bluetooth, Mobile Data and Sound have the bar's quick
// menus too; here they have a page each, and Screen Time and Battery Life live
// on theirs rather than in windows of their own. Displays is nova monitor's
// and nova nightlight's, Keyboard & Mouse nova input's, Notifications nova
// notification schedule's, Printers nova-printers' (CUPS's own tools).
//
// Summoned by the shell, from the menu or the CLI; `range` is Screen Time's
// and Battery Life's, "today" or "week", `apps` "install" has Updates
// offer Chrome and VS Code, and Printers opens at the `printer` named, and
// points at its `job`, as a printing notice's button asks:
//   nova-shell shell summon nova.settings '{"page":"battery","range":"week"}'
//   nova-shell shell summon nova.settings '{"page":"printers","printer":"Office"}'
Item {
  id: root

  // Injected by nova-shell.
  property var shell: null
  property var manifest: null

  readonly property string pluginId: "nova.settings"

  property bool closingFromHost: false
  property string page: "wifi"
  property string range: "today"
  property bool confirmRecovery: false
  // Updates offers Chrome and VS Code (opened so by nova-launch-browser).
  property bool offerApps: false
  // The printer Printers opens at, and the job a notice is about.
  property string printer: ""
  property string job: ""

  // What the window shows, and the changes it runs.
  SettingsState { id: settingsState }
  readonly property var info: settingsState.info
  readonly property bool loaded: settingsState.loaded
  readonly property string failure: settingsState.failure

  readonly property var appearance: info.appearance || ({})
  readonly property var battery: info.battery || ({})
  readonly property var bar: info.bar || ({})
  readonly property var lock: info.lock || ({})
  readonly property var apps: info.apps || ({})
  readonly property var about: info.about || ({})
  readonly property var updates: info.updates || ({})
  readonly property var limit: battery.limit || ({})
  readonly property var performance: info.performance || ({})
  readonly property var undervolt: performance.undervolt || ({})
  readonly property var profiles: performance.profiles || []
  readonly property bool gpuSwitch: performance.gpu === "auto" || performance.gpu === "off"

  // `group` starts a new group in the sidebar; `radio` is the rfkill type a
  // page needs the hardware for.
  readonly property var allPages: [
    { id: "wifi", label: "Wi-Fi", icon: "󰖩", radio: "wlan" },
    { id: "bluetooth", label: "Bluetooth", icon: "󰂯", radio: "bluetooth" },
    { id: "mobile-data", label: "Mobile Data", icon: "󰞃", radio: "wwan" },
    { id: "airdrop", label: "AirDrop", icon: "󰀃" },
    { id: "notifications", label: "Notifications", icon: "󰂚", group: true },
    { id: "sound", label: "Sound", icon: "󰕾" },
    { id: "displays", label: "Displays", icon: "󰍹" },
    { id: "keyboard", label: "Keyboard & Mouse", icon: "󰌌" },
    { id: "printers", label: "Printers", icon: "󰐪" },
    { id: "battery", label: "Battery", icon: "󰁹" },
    { id: "performance", label: "Performance", icon: "󰓅" },
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
    // A Wi-Fi card that can do it (nova airdrop available).
    if (p.id === "airdrop") return !!root.info.airdrop && root.info.airdrop.available === true
    // Power modes, a discrete GPU Nova switches, or an Intel CPU, which takes
    // an undervolt through its mailbox at all.
    if (p.id === "performance") return root.profiles.length > 0 || root.gpuSwitch || root.undervolt.intel === true
    // Nova's notifications, unless switched off for another server.
    if (p.id === "notifications") return !root.shell || !!root.shell.serviceFor("nova.notifications")
    if (p.radio) return (root.info.radios || []).indexOf(p.radio) >= 0
    return true
  })
  // A page the state shows this computer has not got (Wi-Fi on a desktop with
  // no card, Battery) gives way to the first one it has.
  onPagesChanged: if (!pages.some(function (p) { return p.id === root.page })) page = pages[0].id

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

  // Settings opens on the page asked for, or else on its first (Wi-Fi, on a
  // computer that has it), never on whichever was open when it last closed.
  function open(payloadJson) {
    closingFromHost = false
    var payload = {}
    try {
      payload = JSON.parse(String(payloadJson || "{}")) || {}
    } catch (e) {
      // An unparseable payload asks for nothing.
    }
    page = allPages.some(function (p) { return p.id === payload.page }) ? payload.page : pages[0].id
    range = payload.range === "week" ? "week" : "today"
    offerApps = payload.apps === "install"
    printer = ""
    printer = typeof payload.printer === "string" ? payload.printer : ""
    job = typeof payload.job === "string" ? payload.job : ""
    confirmRecovery = false
    // Open already, on another workspace: it comes to this one. A window is
    // shown on the workspace it is opened on, so it is closed and opened anew.
    if (window.visible && elsewhere()) close()
    if (!window.visible) measureRoom()
    window.visible = true
    load()
    Qt.callLater(function () {
      keys.forceActiveFocus()
      if (root.page === "lock" && payload.sheet === "password" && pageLoader.item)
        pageLoader.item.showPassword()
    })
  }

  // The room on the focused screen, where the window opens: its full size
  // wherever that fits, and no bigger than a small screen (a 1024x600 panel)
  // where it does not, with space for the bar and the gaps.
  // Taken as it opens, so focusing another screen does not resize it.
  property size room: Qt.size(Style.space(820), Style.space(600))

  // How much bigger than its usual size it opens: more on a bigger screen.
  property real growth: 1

  function measureRoom() {
    // Without Hyprland (a test, a smoke run) there is no screen in focus to
    // measure, and the window keeps its usual size.
    var hyprland = !!Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")
    var name = hyprland && Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === name) {
        room = Qt.size(screens[i].width - Style.space(48), screens[i].height - Style.space(80))
        growth = Util.windowGrowth(screens[i].width, screens[i].height, Style.spaceScale)
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

  function load() {
    settingsState.load()
  }

  // Changes run one at a time, in order, and the window reloads once the
  // last one is done. <changes>, what a change sets by its path in the state
  // ({ "bar.transparent": true }), shows at once (SettingsState).
  function run(argv, changes) {
    settingsState.run(argv, changes)
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

  // The window closed with the page open: Settings is unloaded then, and
  // the timer above with it, so the scan is stopped on the way out.
  Component.onDestruction: {
    if (owesDiscoveryStop && bluetoothAdapter && bluetoothAdapter.discovering) bluetoothAdapter.discovering = false
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
    visible: false
    color: Commons.Color.background
    implicitWidth: Math.min(Style.space(820 * root.growth), root.room.width)
    implicitHeight: Math.min(Style.space(600 * root.growth), root.room.height)
    minimumSize: Qt.size(Math.min(Style.space(680), root.room.width), Math.min(Style.space(480), root.room.height))

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

          // The touchpad scrolls the page as GTK does; under the page, so a
          // slider still takes the wheel it is under.
          TouchpadScroll {
            anchors.fill: parent
            z: -1
            flickable: scroll.contentItem
          }
          sourceComponent: {
            switch (root.page) {
            case "wifi": return wifiPage
            case "airdrop": return airdropPage
            case "bluetooth": return bluetoothPage
            case "mobile-data": return mobileDataPage
            case "notifications": return notificationsPage
            case "sound": return soundPage
            case "displays": return displaysPage
            case "keyboard": return keyboardPage
            case "printers": return printersPage
            case "bar": return barPage
            case "battery": return batteryPage
            case "performance": return performancePage
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
        TapHandler { onTapped: settingsState.failure = "" }
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
        le: root.info.bluetooth ? root.info.bluetooth.le === true : null
        iphone: !!root.info.iphone && root.info.iphone.on === true
        iphoneRunning: !!root.info.iphone && root.info.iphone.active === true
        onDiscoveryStarted: root.owesDiscoveryStop = true
        onCommand: function (argv, changes) { root.run(argv, changes) }
      }
    }
  }

  Component {
    id: airdropPage
    Page {
      id: p
      title: "AirDrop"
      AirDropView {
        width: p.inner
        bell: !!root.info.airdrop && root.info.airdrop.bell === true
        onCommand: function (argv, changes) { root.run(argv, changes) }
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
    id: notificationsPage
    Page {
      id: p
      title: "Notifications"
      NotificationsView {
        width: p.inner
        shell: root.shell
        settings: root.info.doNotDisturb || ({})
        onCommand: function (argv, changes) { root.run(argv, Asked.under("doNotDisturb", changes)) }
      }
    }
  }

  Component {
    id: soundPage
    Page {
      id: p
      title: "Sound"
      SoundView {
        width: p.inner
        shell: root.shell
      }
    }
  }

  Component {
    id: displaysPage
    Page {
      id: p
      title: "Displays"
      DisplaysView {
        width: p.inner
        listing: root.info.displays || ({})
        onCommand: function (argv, changes) { root.run(argv, Asked.under("displays", changes)) }
        onExpired: root.load()
      }
      NightLightView {
        width: p.inner
        shell: root.shell
        settings: root.info.nightlight || ({})
        onCommand: function (argv, changes) { root.run(argv, Asked.under("nightlight", changes)) }
      }
    }
  }

  Component {
    id: keyboardPage
    Page {
      id: p
      title: "Keyboard & Mouse"
      KeyboardView {
        width: p.inner
        input: root.info.input || ({})
        overlayParent: keys
        onCommand: function (argv, changes) { root.run(argv, Asked.under("input", changes)) }
      }
    }
  }

  Component {
    id: printersPage
    Page {
      id: p
      title: "Printers"
      PrintersView {
        width: p.inner
        overlayParent: keys
        focusPrinter: root.printer
        focusJob: root.job
      }
    }
  }

  Component {
    id: appearancePage
    Page {
      id: p
      title: "Appearance"

      ThemeView {
        width: p.inner
        appearance: root.appearance
        onCommand: function (argv, changes) { root.run(argv, Asked.under("appearance", changes)) }
      }

      Section {
        width: p.inner
        title: "TEXT"
        Line {
          label: "Font"
          Dropdown {
            options: root.options(root.appearance.fonts, root.appearance.font)
            value: root.appearance.font || ""
            onChanged: function (value) { root.run(["nova-font-set", value], { "appearance.font": value }) }
          }
        }
        Line {
          label: "Text size"
          detail: textSize.knobAt + " px"
          LevelSlider {
            id: textSize
            width: Style.space(220)
            from: 9
            to: 20
            wheelStep: 1
            whole: true
            notches: 12
            value: Number(root.appearance.textSize || 12)
            onLetGo: at => root.run(["nova-display-text-size", String(Math.round(at))], { "appearance.textSize": Math.round(at) })
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
        Toggle {
          width: parent.width
          label: "Transparent"
          checked: root.bar.transparent === true
          onClicked: root.run(["nova", "bar", "transparent", checked ? "false" : "true"], { "bar.transparent": !checked })
        }
      }

      Section {
        width: p.inner
        title: "IN THE BAR"
        visible: (root.bar.widgets || []).length > 0
        Repeater {
          model: root.bar.widgets || []
          delegate: Toggle {
            required property var modelData
            width: parent.width
            label: modelData.name
            checked: (root.bar.shown || []).indexOf(modelData.id) >= 0
            onClicked: {
              const shown = (root.bar.shown || []).filter(id => id !== modelData.id)
              root.run(["nova", "bar", checked ? "remove" : "put", modelData.id],
                { "bar.shown": checked ? shown : shown.concat([modelData.id]) })
            }
          }
        }
      }

      Section {
        width: p.inner
        title: "HIDDEN ICONS"
        visible: (root.bar.hiddenTray || []).length > 0
        Repeater {
          model: root.bar.hiddenTray || []
          delegate: Line {
            required property string modelData
            label: (root.bar.hiddenTrayNames || {})[modelData] || modelData
            Button {
              text: "Show"
              bordered: true
              onClicked: {
                const rest = (root.bar.hiddenTray || []).filter(id => id !== modelData)
                root.run(["nova", "bar", "set", "nova.tray", "hidden", JSON.stringify(rest), "--json"], { "bar.hiddenTray": rest })
              }
            }
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
            ? root.battery.health + "% of original capacity, " + (root.battery.cycles || 0) + " cycles"
            : "Not reported"
        }
      }

      Section {
        width: p.inner
        title: "CHARGE LIMIT"
        Toggle {
          width: parent.width
          visible: root.limit.kind === "threshold" || root.limit.kind === "switch"
          label: "Limit charging"
          checked: root.limit.on === true
          onClicked: root.run(["nova-battery-limit", checked ? "off" : (root.limit.kind === "switch" ? "on" : "80")],
            { "battery.limit.on": !checked })
        }
        Line {
          visible: root.limit.kind === "threshold" && root.limit.on === true
          label: "Stop charging at"
          detail: limitSlider.knobAt + "%"
          LevelSlider {
            id: limitSlider
            width: Style.space(220)
            from: 50
            to: 100
            wheelStep: 5
            whole: true
            notches: 11
            value: Number(root.limit.limit || 80)
            onLetGo: at => root.run(["nova-battery-limit", String(Math.round(at))], { "battery.limit.limit": Math.round(at) })
          }
        }
        Caption {
          width: parent.width
          visible: root.limit.kind !== "threshold" && root.limit.kind !== "switch"
          text: "Not supported by this battery"
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
            onChanged: function (value) { root.run(["nova-power-lid", value], { "battery.lid": value }) }
          }
        }
        Line {
          label: "Power button"
          ButtonGroup {
            options: [{ value: "menu", label: "Menu" }, { value: "sleep", label: "Sleep" }, { value: "off", label: "Shut Down" }]
            value: root.battery.powerButton || "menu"
            onChanged: function (value) { root.run(["nova-power-button", value], { "battery.powerButton": value }) }
          }
        }
        Line {
          label: "Asleep on battery, hibernate after"
          visible: (root.battery.hibernate || "") !== ""
          ButtonGroup {
            options: [{ value: "1h", label: "1 Hour" }, { value: "2h", label: "2 Hours" }, { value: "4h", label: "4 Hours" }, { value: "never", label: "Never" }]
            value: root.battery.hibernate || ""
            onChanged: function (value) { root.run(["nova-power-hibernate", value], { "battery.hibernate": value }) }
          }
        }
      }
    }
  }

  Component {
    id: performancePage
    Page {
      id: p
      title: "Performance"

      Section {
        width: p.inner
        title: "POWER MODE"
        visible: root.profiles.length > 0
        ButtonGroup {
          readonly property var active: root.profiles.filter(function (x) { return x.active })
          options: root.profiles.map(function (x) { return { value: x.name, label: root.nameOf(x.name) } })
          value: active.length > 0 ? active[0].name : ""
          onChanged: function (value) {
            root.run(["nova-power-profile", "set", value],
              { "performance.profiles": root.profiles.map(x => Object.assign({}, x, { active: x.name === value })) })
          }
        }
      }

      PowerReadout {
        width: p.inner
      }

      Section {
        width: p.inner
        title: "DISCRETE GPU"
        visible: root.gpuSwitch
        ButtonGroup {
          options: [{ value: "auto", label: "On When Plugged In" }, { value: "off", label: "Always Off" }]
          value: root.performance.gpu || ""
          onChanged: function (value) { root.run(["nova-power-gpu", "mode", value], { "performance.gpu": value }) }
        }
      }

      PerformanceView {
        width: p.inner
        visible: root.undervolt.intel === true
        undervolt: root.undervolt
        onCommand: function (argv, changes) { root.run(argv, Asked.under("performance.undervolt", changes)) }
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
          checked: root.info.screenTime === true
          onClicked: root.run(["nova-screentime", checked ? "off" : "on"], { "screenTime": !checked })
        }
      }

      ScreenTimeView {
        width: p.inner
        visible: root.info.screenTime === true
        shell: root.shell
        range: root.range
        onRangePicked: function (range) { root.range = range }
      }
    }
  }

  Component {
    id: lockPage
    Page {
      id: p
      title: "Lock Screen"

      function showPassword() { passwordSheet.open() }

      PasswordSheet {
        id: passwordSheet
        parent: keys
        anchors.fill: parent
        z: 100
        onChanged: passwordConfirmation.restart()
      }

      Timer { id: passwordConfirmation; interval: 3000 }

      Section {
        width: p.inner
        Line {
          label: "Password"
          Button { text: "Change…"; bordered: true; onClicked: p.showPassword() }
        }
        Caption { visible: passwordConfirmation.running; text: "Password changed." }
      }

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
          onChanged: function (value) { root.run(["nova-idle-screensaver", value], { "lock.screensaver": value === "never" ? 0 : Number(value) * 60 }) }
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
          onChanged: function (value) { root.run(["nova-idle-lock", value], { "lock.seconds": value === "never" ? 0 : Number(value) * 60 }) }
        }
      }

      FingerprintSettings {
        width: p.inner
        visible: root.lock.fingerprint === true
        overlayParent: keys
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
          Dropdown {
            options: root.options(root.apps.browsers, root.apps.browser)
            value: root.apps.browser || ""
            onChanged: function (value) { root.run(["nova-default-browser", value], { "apps.browser": value }) }
          }
        }
        Line {
          label: "Code editor"
          Dropdown {
            options: root.options(root.apps.editors, root.apps.editor === "zeditor" ? "zed" : root.apps.editor)
            value: root.apps.editor === "zeditor" ? "zed" : (root.apps.editor || "")
            onChanged: function (value) { root.run(["nova-default-editor", value], { "apps.editor": value }) }
          }
        }
        Line {
          label: "Terminal"
          Dropdown {
            options: root.options(root.apps.terminals, root.apps.terminal)
            value: root.apps.terminal || ""
            onChanged: function (value) { root.run(["nova-default-terminal", value], { "apps.terminal": value }) }
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
        UpdatesView {
          width: parent.width
          version: root.about.version || ""
          offerApps: root.offerApps
          onFinished: root.load()
          onChecking: firmwareView.check()
        }
        FirmwareView {
          id: firmwareView
          monitor: root.updates.firmware === true
          visible: monitor && shown
        }
      }

      Section {
        width: p.inner
        Toggle {
          width: parent.width
          label: "Test release candidates"
          checked: root.updates.candidates === true
          onClicked: root.run(["nova-update", "--candidates", checked ? "off" : "on"], { "updates.candidates": !checked })
        }
      }

      Section {
        width: p.inner
        title: "RECOVERY"
        DoctorView {}
        Line {
          label: "Restart to recovery"
          detail: root.confirmRecovery ? "Restarts now, into the boot menu." : ""
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
        // The installed version as its release is named (1.0.0rc.5 is
        // v1.0.0-rc.5), or the release the repository is on without one.
        Caption {
          readonly property string version: String(root.about.version || root.about.release || "")
            .replace(/^v/, "").replace(/(\d)([a-z])/, "$1-$2")
          width: parent.width
          visible: version !== ""
          text: "Version " + version
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
              color: Commons.Color.quieter(Commons.Color.foreground, Commons.Color.background, 0.75)
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
