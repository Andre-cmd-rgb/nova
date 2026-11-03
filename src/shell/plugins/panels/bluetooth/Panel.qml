import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// Bluetooth on the bar: off, on, or on with a device connected, as its
// icon. A right click (or b in the panel, or `nova-shell nova.bluetooth
// toggle`) turns it on or off. A click opens the panel: a switch, the
// devices connected, those paired, and, while the panel is open and scans,
// those around. A click on a device connects or disconnects it; a right
// click disconnects or forgets it. The pointer and the keys share one
// cursor through it all.
Panel {
  id: root
  moduleName: "nova.bluetooth"
  ipcTarget: "nova.bluetooth"

  // ---------------------------------------------------------------- adapter

  readonly property var adapter: Bluetooth.defaultAdapter
  // The Bluetooth radio switches, index: blocked, as `rfkill event` reports
  // them. Turning Bluetooth off sets its switch, and on a ThinkPad the switch
  // cuts the controller's power: it leaves USB, and BlueZ, altogether. With
  // Bluetooth off there may be no adapter, only the switch, and the widget
  // stays for its sake, or Bluetooth could not be turned back on.
  property var radioSwitches: ({})
  readonly property bool available: !!adapter || Object.keys(radioSwitches).length > 0
  readonly property bool powered: !!adapter && adapter.enabled

  visible: available
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // nova-bluetooth-power moves the radio's rfkill soft block, which
  // systemd-rfkill keeps across reboots; adapter.enabled writes BlueZ's
  // Powered, which nothing keeps, so Bluetooth came back on at the next
  // boot. Powered follows the block, so the switch and the icon read it.
  // It is asked for on or off rather than a toggle: the switch moves only
  // once BlueZ catches up, and a second click before then would read the
  // old state and undo the first.
  function toggleBluetooth() {
    if (!available) return
    Quickshell.execDetached(["nova-bluetooth-power", powered ? "off" : "on"])
  }

  Process {
    running: true
    command: ["rfkill", "event"]
    stdout: SplitParser {
      onRead: function(line) {
        var next = Model.radio(root.radioSwitches, line)
        if (next) root.radioSwitches = next
      }
    }
  }

  // ---------------------------------------------------------------- devices

  readonly property var devices: Bluetooth.devices ? Bluetooth.devices.values : []
  readonly property var deviceGroups: Model.lists(devices)
  readonly property var connectedDevices: deviceGroups.connected || []
  readonly property var knownDevices: deviceGroups.known || []
  readonly property var discoveredDevices: deviceGroups.discovered || []

  readonly property string icon: !available ? "" : !powered ? "󰂲" : connectedDevices.length > 0 ? "󰂱" : "󰂯"

  // Address: "connecting", "disconnecting" or "forgetting". nova-bluetooth-device
  // does the work; this keeps the rows saying so until BlueZ catches up.
  property var pendingActions: ({})

  // The live device behind a row, by its address.
  function deviceFor(row) {
    if (!row) return null
    var address = row.address || ""
    var list = devices || []
    for (var i = 0; i < list.length; i++) {
      if ((list[i].address || "") === address) return list[i]
    }
    return null
  }

  function deviceAt(section, index) {
    var list = Model.devicesIn(deviceGroups, section)
    return index >= 0 && index < list.length ? list[index] : null
  }

  function setPendingAction(address, action) {
    if (!address) return
    pendingActions = Model.withAction(pendingActions, address, action)
    if (action) pendingTimeout.restart()
  }

  function runDeviceAction(device, action, pending) {
    if (!device || !device.address) return
    setPendingAction(device.address, pending)
    Quickshell.execDetached(["nova-bluetooth-device", action, device.address])
  }

  // A paired device is connected; any other is paired first.
  function connectDevice(device) {
    if (!device || device.connected) return
    runDeviceAction(device, device.paired || device.bonded || device.trusted ? "connect" : "pair", "connecting")
  }

  function disconnectDevice(device) {
    if (!device || !device.address || !device.connected) return
    setPendingAction(device.address, "disconnecting")
    if (device.disconnect) device.disconnect()
    Quickshell.execDetached(["nova-bluetooth-device", "disconnect", device.address])
  }

  function forgetDevice(device) {
    if (!device || !device.address) return
    runDeviceAction(device, "forget", "forgetting")
  }

  // A device that has just connected gets the audio, once its sink shows.
  function settleActions() {
    var done = Model.settle(pendingActions, devices)
    done.connected.forEach(scheduleAudioOutputSwitch)
    if (done.changed) pendingActions = done.actions
  }

  // An action BlueZ never answers is let go of after 20 s.
  Timer { id: pendingTimeout; interval: 20000; onTriggered: root.pendingActions = ({}) }

  // ---------------------------------------------------------------- audio

  // The device whose sink is waited for, copied out of it, and the looks
  // taken so far: one each half second, eight at most.
  property var pendingAudioOutputDevice: null
  property int pendingAudioOutputAttempts: 0

  function scheduleAudioOutputSwitch(device) {
    pendingAudioOutputDevice = {
      address: device && device.address ? device.address : "",
      name: device && device.name ? device.name : "",
      deviceName: device && device.deviceName ? device.deviceName : ""
    }
    pendingAudioOutputAttempts = 0
    audioSwitchTimer.restart()
  }

  function switchPendingAudioOutput() {
    if (!pendingAudioOutputDevice) return
    var sink = Model.sinkFor(Pipewire.nodes ? Pipewire.nodes.values : [], pendingAudioOutputDevice)
    if (sink) {
      Pipewire.preferredDefaultAudioSink = sink
      if (sink.id !== undefined && sink.name)
        Quickshell.execDetached(["nova-audio-output-set-default", String(sink.id), String(sink.name)])
      pendingAudioOutputDevice = null
      audioSwitchTimer.stop()
      return
    }
    pendingAudioOutputAttempts += 1
    if (pendingAudioOutputAttempts >= 8) {
      pendingAudioOutputDevice = null
      return
    }
    audioSwitchTimer.restart()
  }

  Timer { id: audioSwitchTimer; interval: 500; onTriggered: root.switchPendingAudioOutput() }

  // ---------------------------------------------------------------- scan

  // Set while this widget owes BlueZ a StopDiscovery: from when it starts a
  // scan (or opens onto one running) until the scan is seen down after it
  // closes. It is a debt, not a state: BlueZ's Discovering also shows scans
  // other programs hold, which are not this panel's to stop.
  property bool owesDiscoveryStop: false

  // Another screen's widget whose panel is open, if any. Every screen's
  // widget shares the adapter, and moving the panel to another screen closes
  // one as it opens the other: the one closing leaves the scan to it.
  function openSibling() {
    if (!bar || typeof bar.moduleWidgets !== "function") return null
    var items = bar.moduleWidgets(moduleName)
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i] !== root && items[i].opened === true) return items[i]
    }
    return null
  }

  // While the panel is open, the scan is started and started again: BlueZ
  // turns StartDiscovery away while the adapter powers up, and a scan can
  // end by itself.
  Timer {
    interval: 1000
    repeat: true
    triggeredOnStart: true
    running: root.opened && root.adapter !== null && root.adapter.enabled && !root.adapter.discovering
    onTriggered: {
      root.owesDiscoveryStop = true
      root.adapter.discovering = true
    }
  }

  // And stopped once it closes. The scan is held by Quickshell's D-Bus
  // connection, and nothing ends it at close: one look at the panel left the
  // radio scanning until the shell restarted, and A2DP audio on the same
  // controller stuttered. This follows the state BlueZ confirms rather than
  // writing once at close, as Quickshell drops a write equal to the last
  // state BlueZ reported: a stop sent while a start awaits confirmation would
  // be lost and the scan with it. A confirmation landing any time after
  // close starts this again, and opening again within a second keeps the
  // scan going. Three tries at most, so that a scan another program keeps up
  // is not asked to stop for ever.
  Timer {
    interval: 1000
    repeat: true
    property int attempts: 0
    running: !root.opened && root.owesDiscoveryStop && root.adapter !== null && root.adapter.discovering === true
    onRunningChanged: if (running) attempts = 0
    onTriggered: {
      // The scan now serves a panel open on another screen, so the debt goes
      // with it: that panel may have opened before BlueZ confirmed this
      // one's start, and found no scan to take on.
      var sibling = root.openSibling()
      if (sibling) {
        sibling.owesDiscoveryStop = true
        root.owesDiscoveryStop = false
        return
      }
      attempts += 1
      if (attempts > 3) {
        root.owesDiscoveryStop = false
        return
      }
      root.adapter.discovering = false
    }
  }

  // The debt is paid once BlueZ reports the scan down, however it ended, so
  // a scan another program starts later is left alone.
  Connections {
    target: root.adapter
    function onDiscoveringChanged() {
      if (!root.adapter.discovering) root.owesDiscoveryStop = false
    }
  }

  // A widget going away cannot wait for BlueZ: it hands its debt to another
  // screen's, whose timer above catches even a start confirmed later, and
  // stops the scan itself only when it is the last.
  Component.onDestruction: {
    if (!owesDiscoveryStop) return
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i] !== root) {
        items[i].owesDiscoveryStop = true
        return
      }
    }
    if (adapter !== null && adapter.discovering) adapter.discovering = false
  }

  // ---------------------------------------------------------------- cursor

  // Shown once the pointer or a key has moved it. focusSection is
  // "connected", "known", "discovered" or "header", the switch.
  property bool cursorActive: false
  property string focusSection: "connected"
  property int selectedIndex: 0
  // On the row's forget button rather than the row.
  property bool actionFocused: false
  // The device under the cursor, by address: devices move between lists as
  // they connect, disconnect, pair or are forgotten, and the cursor goes
  // with the device rather than staying on its old row.
  property string focusedDeviceAddress: ""

  // The lists shown. The cursor reads them, and the rows, from deviceGroups
  // itself: it is moved from handlers that run as deviceGroups changes,
  // before connectedDevices, the other lists and visibleSections may have
  // caught up with it.
  function shownSections() {
    return Model.sections(deviceGroups, adapter && adapter.discovering)
  }
  // Watched below: a scan starting or ending shows or hides a list too.
  readonly property var visibleSections: shownSections()

  // The list that scrolls: the paired devices, then the scan's.
  readonly property var scrollRows: Model.scrollRows(knownDevices,
    shownSections().indexOf("discovered") >= 0 ? discoveredDevices : [])
  // The connected devices, above it.
  readonly property var connectedRows: connectedDevices.map(Model.rowOf)
  // The cursor's place in the scrolling list; -1 when it is above it.
  readonly property int scrollRowIndex: Model.rowIndex(scrollRows, focusSection, selectedIndex)

  // Section, then index, then the forget button, as every change of the
  // cursor goes.
  function go(next) {
    focusSection = next.section
    selectedIndex = next.index
    actionFocused = next.onForget
  }

  function here() {
    return Model.cursor(focusSection, selectedIndex, actionFocused)
  }

  function point(section, index, onForget) {
    cursorActive = true
    go(Model.cursor(section, index, onForget))
  }

  function setHeaderCursor() {
    cursorActive = true
    go(Model.cursor("header", selectedIndex, false))
  }

  function moveCursor(delta) {
    go(Model.move(here(), delta, shownSections(), deviceGroups))
  }

  // l onto the row's forget button, h back off it.
  function moveCursorH(delta) {
    if (focusSection !== "known" && focusSection !== "connected") return
    var dev = deviceAt(focusSection, selectedIndex)
    if (!dev || !dev.address) return
    if (delta > 0) actionFocused = true
    else if (delta < 0) actionFocused = false
  }

  function clampCursor() {
    go(Model.clamp(here(), shownSections(), deviceGroups))
  }

  // Back onto the focused device wherever it went, else kept in bounds.
  // Both handlers below run it, so that whichever runs first finds the
  // device before anything moves the cursor off it.
  function reselectFocusedDevice() {
    var found = focusedDeviceAddress === "" ? null
      : Model.find(focusedDeviceAddress, shownSections(), deviceGroups, actionFocused)
    if (found) go(found)
    clampCursor()
  }

  // Return: the switch, the forget button, or the row: a connected device
  // disconnects, any other connects.
  function activateCursor() {
    if (focusSection === "header") {
      toggleBluetooth()
      return
    }
    if (actionFocused) {
      deleteSelected()
      return
    }
    var dev = deviceAt(focusSection, selectedIndex)
    if (!dev) return
    if (focusSection === "discovered" || !dev.connected) connectDevice(dev)
    else disconnectDevice(dev)
  }

  // x forgets the device under the cursor, disconnecting it first.
  function deleteSelected() {
    if (focusSection !== "known" && focusSection !== "connected") return
    var dev = deviceAt(focusSection, selectedIndex)
    if (dev) forgetDevice(dev)
  }

  onSelectedIndexChanged: {
    var d = deviceAt(focusSection, selectedIndex)
    focusedDeviceAddress = d ? (d.address || "") : ""
  }
  onFocusSectionChanged: {
    var d = deviceAt(focusSection, selectedIndex)
    focusedDeviceAddress = d ? (d.address || "") : ""
  }
  onDeviceGroupsChanged: {
    reselectFocusedDevice()
    settleActions()
  }
  onVisibleSectionsChanged: reselectFocusedDevice()

  onOpenedChanged: {
    if (!opened) return
    // A scan already running is taken on, whether a panel on another screen
    // handed it over or a widget could not stop its own, so that closing
    // this one ends it.
    if (adapter !== null && adapter.discovering) owesDiscoveryStop = true
    if (connectedDevices.length > 0) go(Model.cursor("connected", 0, false))
    else if (knownDevices.length > 0) go(Model.cursor("known", 0, false))
    else if (discoveredDevices.length > 0) go(Model.cursor("discovered", 0, false))
    else go(Model.cursor("header", selectedIndex, false))
    cursorActive = false
  }

  // ---------------------------------------------------------------- phrases

  // A word for the radio turns every few seconds while the panel is open
  // and Bluetooth is on, each change faded out and in.
  readonly property var phrases: ["Untangling wires", "Streaming vikings", "Pairing mysteries", "Herding headsets",
    "Taming radios", "Summoning speakers", "Wrangling codecs", "Polishing packets"]
  property int phraseAt: 0
  readonly property string status: !available ? "No adapter" : !powered ? "Turned Off" : phrases[phraseAt % phrases.length]

  // Off halfway through a fade, the line is shown whole at once.
  onPoweredChanged: {
    if (powered) return
    fade.stop()
    hero.metaOpacity = 1.0
  }

  Timer {
    interval: 2800
    running: root.opened && root.powered
    repeat: true
    onTriggered: fade.restart()
  }

  SequentialAnimation {
    id: fade
    PropertyAnimation { target: hero; property: "metaOpacity"; to: 0.0; duration: 180; easing.type: Easing.OutQuad }
    ScriptAction { script: root.phraseAt = (root.phraseAt + 1) % root.phrases.length }
    PropertyAnimation { target: hero; property: "metaOpacity"; to: 1.0; duration: 260; easing.type: Easing.InQuad }
  }

  // ---------------------------------------------------------------- bar

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.icon
    onPressed: function(which) {
      if (which === Qt.RightButton) root.toggleBluetooth()
      else root.toggle()
    }
  }

  // ---------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    // j and k walk the switch and the rows, l and h onto and off a row's
    // forget button, Return acts, x forgets, b turns Bluetooth on or off.
    // The first key only shows the cursor.
    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) root.cursorActive = true
        else if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.moveCursorH(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onDeleteRequested: if (root.cursorActive) root.deleteSelected()
      onTextKey: function(t) {
        if (t === "b" || t === "B") root.toggleBluetooth()
      }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(14)

        // The icon shows the state; the switch alone turns Bluetooth on or
        // off, and is the cursor's stop above the lists.
        PanelHero {
          id: hero
          title: "Bluetooth"
          meta: root.status
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          iconOpacity: root.powered ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: root.icon
              color: root.bar.foreground
              font { family: root.bar.fontFamily; pixelSize: Style.font.display }
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              id: powerSwitch
              visible: root.available
              checked: root.powered
              hasCursor: root.cursorActive && root.focusSection === "header"
              foreground: root.bar.foreground
              onHovered: function(on) { if (on) root.setHeaderCursor() }
              onToggled: root.toggleBluetooth()

              PanelToolTip {
                visible: powerSwitch.containsMouse
                text: root.powered ? "Turn Bluetooth off" : "Turn Bluetooth on"
                fontFamily: root.bar.fontFamily
              }
            }
          }
        }

        PanelSeparator { foreground: root.bar.foreground }

        Column {
          id: connectedList
          visible: root.connectedDevices.length > 0
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "CONNECTED"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
          }

          Repeater {
            model: root.connectedRows
            DeviceRow {
              required property var modelData
              required property int index
              width: connectedList.width
              dev: modelData
              rowIndex: index
              sectionName: "connected"
            }
          }
        }

        PanelSeparator {
          visible: root.connectedDevices.length > 0 && root.scrollRows.length > 0
          foreground: root.bar.foreground
        }

        // The paired devices and the scan's, in a list capped in height so
        // that a crowded room does not push the card off the screen. A
        // ListView keeps the cursor's row in view, moving only when the row
        // is cut off, so it never lurches under a still pointer.
        ListView {
          id: deviceList
          width: parent.width
          height: Math.min(contentHeight, Style.space(400))
          spacing: Style.space(10)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height

          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: root.scrollRows
          currentIndex: root.scrollRowIndex
          // A turn later: the model is made anew each time the scan reports,
          // which resets the view under a call made at once, and the row is
          // not brought into view.
          onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(showCurrent)
          function showCurrent() {
            if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
          }

          delegate: Item {
            required property var modelData
            required property int index
            readonly property string title: Model.titleAt(root.scrollRows, index)

            width: ListView.view.width
            height: entry.implicitHeight

            Column {
              id: entry
              width: parent.width
              spacing: Style.space(10)

              // A Column leaves out what is hidden; a height bound to
              // `visible` as well loops when the list hides a delegate.
              PanelSeparator {
                visible: index > 0 && title !== ""
                foreground: root.bar.foreground
              }

              PanelSectionHeader {
                visible: title !== ""
                text: title
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              DeviceRow {
                width: parent.width
                dev: modelData.dev
                rowIndex: modelData.indexInSection
                sectionName: modelData.section
              }
            }
          }

          TouchpadScroll { flickable: deviceList }
        }

        Text {
          visible: root.connectedDevices.length === 0 && root.scrollRows.length === 0
          width: parent.width
          textFormat: Text.PlainText
          text: !root.available ? "No Bluetooth adapter" : !root.powered ? "Turn Bluetooth on to scan" : "Scanning for devices…"
          color: Qt.darker(root.bar.foreground, 1.5)
          font { family: root.bar.fontFamily; pixelSize: Style.font.bodySmall }
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  // A device: its name over what is happening to it, and, on a paired or
  // connected one under the pointer or the cursor, a button to forget it.
  // What is under way is the panel's, so it stays as the row moves between
  // lists.
  component DeviceRow: CursorSurface {
    id: row
    required property var dev
    required property int rowIndex
    required property string sectionName

    readonly property bool discovered: sectionName === "discovered"
    readonly property string action: Model.actionFor(root.pendingActions, dev ? dev.address : "")
    readonly property bool selected: root.cursorActive && root.focusSection === sectionName && root.selectedIndex === rowIndex
    readonly property color tone: Model.lively(dev, action) ? root.bar.foreground : Qt.darker(root.bar.foreground, 1.5)

    hasCursor: selected && !root.actionFocused
    current: !!(dev && dev.connected)
    foreground: root.bar.foreground
    implicitHeight: body.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: pointer
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: row.dev ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) root.point(row.sectionName, row.rowIndex, false)
      // A click connects or disconnects; a right click disconnects, or
      // forgets a paired device.
      onClicked: function(mouse) {
        var dev = root.deviceFor(row.dev)
        if (!dev) return
        if (row.current) root.disconnectDevice(dev)
        else if (mouse.button !== Qt.RightButton) root.connectDevice(dev)
        else if (!row.discovered) root.forgetDevice(dev)
      }
    }

    PanelToolTip {
      visible: text !== "" && pointer.containsMouse && !root.actionFocused
      text: Model.clickHint(row.dev, row.discovered)
      fontFamily: root.bar.fontFamily
    }

    Item {
      id: body
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.space(10); rightMargin: Style.space(10) }
      implicitHeight: Math.max(glyph.implicitHeight, lines.implicitHeight, forget.implicitHeight)

      Text {
        id: glyph
        anchors { left: parent.left; verticalCenter: parent.verticalCenter }
        textFormat: Text.PlainText
        text: row.current ? "󰂱" : "󰂯"
        color: row.tone
        font { family: root.bar.fontFamily; pixelSize: Style.font.heading }
      }

      Column {
        id: lines
        anchors {
          left: glyph.right; leftMargin: Style.space(10)
          right: forget.visible ? forget.left : parent.right; rightMargin: forget.visible ? Style.space(8) : 0
          verticalCenter: parent.verticalCenter
        }
        spacing: Style.space(1)

        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: Model.label(row.dev) || "Device"
          color: root.bar.foreground
          font { family: root.bar.fontFamily; pixelSize: Style.font.body }
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: text !== ""
          textFormat: Text.PlainText
          text: Model.status(row.dev, row.action, row.sectionName)
          color: row.tone
          font { family: root.bar.fontFamily; pixelSize: Style.font.caption }
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        id: forget
        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
        visible: !row.discovered && (pointer.containsMouse || row.selected)
        iconText: "󰅙"
        tooltipText: "Forget"
        foreground: root.bar.foreground
        fontFamily: root.bar.fontFamily
        hasCursor: row.selected && root.actionFocused
        onHovered: function(on) {
          if (on) root.point(row.sectionName, row.rowIndex, true)
          else if (pointer.containsMouse) root.actionFocused = false
        }
        onClicked: {
          var dev = root.deviceFor(row.dev)
          if (dev) root.forgetDevice(dev)
        }
      }
    }
  }
}
