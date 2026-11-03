import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import Quickshell.Services.Pipewire
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bluetooth on the bar: its icon says off, on, or on with a device
// connected, and a right click turns it on or off (as do b in the panel and
// `nova-shell nova.bluetooth toggleBluetooth`). A click opens the panel: a
// switch, the devices connected, those paired and, while the panel is open,
// those a scan finds. A click on a device connects or disconnects it; a
// right click disconnects it, or forgets it. The keys and the pointer move
// one cursor.
Panel {
  id: bluetooth
  moduleName: "nova.bluetooth"
  ipcTarget: "nova.bluetooth"

  visible: reachable
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property color ink: bar.foreground
  readonly property color faint: Qt.darker(ink, 1.5)
  readonly property string typeface: bar.fontFamily

  // ---- the radio ----------------------------------------------------------

  readonly property var radio: Bluetooth.defaultAdapter
  readonly property bool live: !!radio && radio.enabled
  readonly property bool scanning: !!radio && radio.discovering === true

  // The Bluetooth switches `rfkill event` reports, index: blocked. Off, the
  // switch is set, and on a ThinkPad it cuts the controller's power: it
  // leaves USB and BlueZ, and there is no adapter. The widget stays for the
  // switch, or nothing could turn Bluetooth back on.
  property var switches: ({})
  readonly property bool reachable: !!radio || Object.keys(switches).length > 0

  function heard(line) {
    var next = Model.radio(switches, line)
    if (next) switches = next
  }

  Process {
    command: ["rfkill", "event"]
    running: true
    stdout: SplitParser {
      onRead: function(line) { bluetooth.heard(line) }
    }
  }

  // nova-bluetooth-power sets the radio's rfkill block, which
  // systemd-rfkill keeps across a reboot; BlueZ's Powered, which
  // adapter.enabled would write, comes back on at every boot. Powered
  // follows the block, and the switch and the icon read it. On or off is
  // asked for by name: the switch moves once BlueZ catches up, and a second
  // click before then would undo the first.
  function toggleBluetooth() {
    if (!reachable) return
    Quickshell.execDetached(["nova-bluetooth-power", live ? "off" : "on"])
  }

  // ---- devices ------------------------------------------------------------

  readonly property var everyDevice: Bluetooth.devices ? Bluetooth.devices.values : []
  readonly property var groups: Model.lists(everyDevice)
  readonly property var listsShown: shownNow()
  // The connected devices sit above a list that scrolls: the paired ones,
  // then the scan's.
  readonly property var connectedList: Model.rowsOf(groups.connected, "connected")
  readonly property var scrollList: Model.scrollRows(groups, listsShown)
  readonly property int scrollAt: Model.rowIndex(scrollList, cursor.place.section, cursor.place.index)

  readonly property string glyph: !reachable ? "" : !live ? "󰂲" : connectedList.length > 0 ? "󰂱" : "󰂯"

  // The lists shown, worked out afresh: the cursor is moved from handlers
  // that run as the groups change, before listsShown has caught up.
  function shownNow() {
    return Model.sections(groups, radio && radio.discovering)
  }

  // The live device behind a row's copy of it, by its address.
  function liveDevice(copy) {
    return Model.listOf(everyDevice).filter(function(d) { return (d.address || "") === copy.address })[0] || null
  }

  onGroupsChanged: {
    cursor.follow()
    var done = Model.settle(underway, everyDevice)
    done.connected.forEach(function(device) { sinkWait.waitFor(device) })
    if (done.changed) underway = done.actions
  }
  onListsShownChanged: cursor.follow()

  // ---- what is under way --------------------------------------------------

  // Address: "connecting", "disconnecting" or "forgetting". The rows say so
  // until BlueZ shows it done, or for 20 s if it never does.
  property var underway: ({})

  Timer {
    id: patience
    interval: 20000
    onTriggered: bluetooth.underway = ({})
  }

  // nova-bluetooth-device connects, pairs, disconnects or forgets.
  function act(device, verb) {
    var ask = Model.request(device, verb)
    if (!ask) return
    underway = Model.withAction(underway, device.address, ask.word)
    patience.restart()
    // The link is dropped through Quickshell at once, and the command after.
    if (ask.verb === "disconnect" && device.disconnect) device.disconnect()
    Quickshell.execDetached(["nova-bluetooth-device", ask.verb, device.address])
  }

  // A click connects or disconnects; a right click disconnects as well, or
  // forgets a paired device.
  function rowClicked(item, right) {
    var device = liveDevice(item.device)
    if (!device) return
    if (item.current) act(device, "disconnect")
    else if (!right) act(device, "connect")
    else if (item.canForget) act(device, "forget")
  }

  // A device that has just connected takes the sound once PipeWire shows
  // its sink: a look each half second, eight at most.
  SinkWait {
    id: sinkWait
  }

  component SinkWait: Timer {
    // A copy of the device: it may be gone by the next look.
    property var wanted: null
    property int looks: 0

    interval: 500

    function waitFor(device) {
      wanted = Model.rowOf(device)
      looks = 0
      restart()
    }

    onTriggered: {
      var sink = Model.sinkFor(Pipewire.nodes ? Pipewire.nodes.values : [], wanted)
      if (sink) {
        Pipewire.preferredDefaultAudioSink = sink
        if (sink.id !== undefined && sink.name)
          Quickshell.execDetached(["nova-audio-output-set-default", String(sink.id), String(sink.name)])
        wanted = null
      } else if (++looks >= 8) {
        wanted = null
      } else {
        restart()
      }
    }
  }

  // ---- the scan -----------------------------------------------------------

  // The panel open, the radio scans, so that devices around show. The scan
  // is Quickshell's, held on its D-Bus connection, and nothing ends it when
  // the panel closes: one look left the radio scanning until the shell
  // restarted, and A2DP audio on the same controller stuttered. So the
  // widget that starts a scan, or opens onto one, owes BlueZ its stop.
  //
  // It is a debt, not a state: BlueZ's Discovering shows other programs'
  // scans too, and those are not this panel's to stop. It is paid once BlueZ
  // reports the scan down, however that came about.
  property bool stopOwed: false
  readonly property bool scanWanted: opened && live && !scanning
  readonly property bool stopDue: !opened && stopOwed && scanning

  // The other screens' copies of this widget, which share the radio.
  function siblings() {
    var all = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    return all.filter(function(item) { return item && item !== bluetooth })
  }

  // Asked for every second: BlueZ turns a start away while the adapter
  // powers up, and a scan can end by itself.
  Timer {
    interval: 1000
    repeat: true
    triggeredOnStart: true
    running: bluetooth.scanWanted
    onTriggered: {
      bluetooth.stopOwed = true
      bluetooth.radio.discovering = true
    }
  }

  // The stop follows what BlueZ confirms, rather than one write at close:
  // Quickshell drops a write equal to the state BlueZ last reported, so a
  // stop sent while a start awaits its answer would be lost. A start
  // confirmed after the close starts this again, and a panel opened again
  // within the second keeps the scan. Three tries, so that a scan another
  // program holds is not asked to stop for ever.
  Timer {
    property int tries: 0

    interval: 1000
    repeat: true
    running: bluetooth.stopDue
    onRunningChanged: if (running) tries = 0
    onTriggered: {
      // A panel open on another screen takes the scan over, and the stop with
      // it: it may have opened before BlueZ confirmed this one's start, and
      // found no scan to take on.
      var heir = bluetooth.siblings().filter(function(item) { return item.opened === true })[0]
      if (heir) {
        heir.stopOwed = true
        bluetooth.stopOwed = false
      } else if (++tries > 3) {
        bluetooth.stopOwed = false
      } else {
        bluetooth.radio.discovering = false
      }
    }
  }

  Connections {
    target: bluetooth.radio
    function onDiscoveringChanged() {
      if (bluetooth.radio.discovering !== true) bluetooth.stopOwed = false
    }
  }

  // A widget going away cannot wait for BlueZ. Another screen's takes the
  // stop over, and its timer catches even a start confirmed later; the last
  // one stops the scan itself.
  Component.onDestruction: {
    if (!stopOwed) return
    var heir = siblings()[0]
    if (heir) heir.stopOwed = true
    else if (radio && radio.discovering) radio.discovering = false
  }

  onOpenedChanged: {
    if (!opened) return
    // A scan already running is taken on, whether another screen's panel
    // left it or a widget could not stop its own, so that this one's close
    // ends it.
    if (scanning) stopOwed = true
    cursor.home()
  }

  // ---- the cursor ---------------------------------------------------------

  Cursor {
    id: cursor
  }

  // Shown once a key or the pointer has moved it. Its place is a list and a
  // row in it ("header" is the switch, and keeps the row's number), and
  // whether it is on that row's forget button. It keeps to its device: as
  // devices connect, pair or go, they move between the lists, and the
  // cursor goes with them rather than staying on the old row.
  component Cursor: QtObject {
    property bool shown: false
    property var place: Model.cursor("connected", 0, false)
    // The device the cursor was last put on.
    property string address: ""

    function deviceAt(at) {
      return Model.devicesIn(bluetooth.groups, at.section)[at.index] || null
    }

    function put(next) {
      if (next.section !== place.section || next.index !== place.index) {
        var device = deviceAt(next)
        address = device ? (device.address || "") : ""
      }
      place = next
    }

    function point(section, index, onForget) {
      shown = true
      put(Model.cursor(section, index, onForget))
    }

    // On the first device, from the connected down; on the switch with none.
    function home() {
      var g = bluetooth.groups
      var first = ["connected", "known", "discovered"].filter(function(s) { return g[s].length > 0 })[0]
      put(first ? Model.cursor(first, 0, false) : Model.cursor("header", place.index, false))
      shown = false
    }

    // Back onto its device wherever that went, else kept on a row there is.
    function follow() {
      var found = address === "" ? null : Model.find(address, bluetooth.shownNow(), bluetooth.groups, place.onForget)
      if (found) put(found)
      put(Model.clamp(place, bluetooth.shownNow(), bluetooth.groups))
    }

    // The first key only shows the cursor. Then j and k walk the switch and
    // the rows, and l and h step onto a row's forget button and off it.
    function nudge(dx, dy) {
      if (!shown) {
        shown = true
      } else if (dy !== 0) {
        put(Model.move(place, dy, bluetooth.shownNow(), bluetooth.groups))
      } else if (dx !== 0 && Model.forgettable(place.section)) {
        var device = deviceAt(place)
        if (device && device.address) put(Model.cursor(place.section, place.index, dx > 0))
      }
    }

    // Return: the switch, the forget button, or the row, which disconnects
    // a device connected and connects any other.
    function press() {
      var device = deviceAt(place)
      if (place.section === "header") bluetooth.toggleBluetooth()
      else if (place.onForget) forgetHere()
      else if (device) bluetooth.act(device, device.connected ? "disconnect" : "connect")
    }

    // x: forgets the device under the cursor, disconnecting it first.
    function forgetHere() {
      var device = Model.forgettable(place.section) ? deviceAt(place) : null
      if (device) bluetooth.act(device, "forget")
    }
  }

  // ---- the phrase ---------------------------------------------------------

  // Under the title, while the panel is open and Bluetooth is on, a word
  // for the radio that changes every few seconds, faded out and in.
  readonly property var phrases: ["Untangling wires", "Streaming vikings", "Pairing mysteries", "Herding headsets",
    "Taming radios", "Summoning speakers", "Wrangling codecs", "Polishing packets"]
  property int phraseAt: 0
  readonly property string heroLine: !reachable ? "No adapter" : !live ? "Turned Off" : phrases[phraseAt % phrases.length]

  // Turned off mid-fade, the line shows whole at once.
  onLiveChanged: {
    if (live) return
    fade.stop()
    head.metaOpacity = 1.0
  }

  Timer {
    interval: 2800
    repeat: true
    running: bluetooth.opened && bluetooth.live
    onTriggered: fade.restart()
  }

  SequentialAnimation {
    id: fade
    PropertyAnimation { target: head; property: "metaOpacity"; to: 0.0; duration: 180; easing.type: Easing.OutQuad }
    ScriptAction { script: bluetooth.phraseAt = (bluetooth.phraseAt + 1) % bluetooth.phrases.length }
    PropertyAnimation { target: head; property: "metaOpacity"; to: 1.0; duration: 260; easing.type: Easing.InQuad }
  }

  // ---- the bar ------------------------------------------------------------

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: bluetooth.bar
    text: bluetooth.glyph
    onPressed: function(which) {
      if (which === Qt.RightButton) bluetooth.toggleBluetooth()
      else bluetooth.toggle()
    }
  }

  // ---- the panel ----------------------------------------------------------

  KeyboardPanel {
    id: card
    anchorItem: button
    owner: bluetooth
    bar: bluetooth.bar
    open: bluetooth.opened
    focusTarget: keys
    contentWidth: card.fittedContentWidth(Style.space(380))
    contentHeight: card.fittedContentHeight(stack.implicitHeight)

    // j, k, h and l move the cursor, Return acts on what it is on, x
    // forgets, b turns Bluetooth on or off.
    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { cursor.nudge(dx, dy) }
      onActivateRequested: if (cursor.shown) cursor.press()
      onDeleteRequested: if (cursor.shown) cursor.forgetHere()
      onCloseRequested: bluetooth.close()
      onTabRequested: function(direction) { bluetooth.switchPanel(direction) }
      onTextKey: function(t) {
        if (t.toLowerCase() === "b") bluetooth.toggleBluetooth()
      }

      Column {
        id: stack
        anchors.fill: parent
        spacing: Style.space(14)

        // The icon says what the radio is doing; the switch alone turns it on
        // or off, and is the cursor's stop above the lists.
        PanelHero {
          id: head
          title: "Bluetooth"
          meta: bluetooth.heroLine
          foreground: bluetooth.ink
          fontFamily: bluetooth.typeface
          iconOpacity: bluetooth.live ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              textFormat: Text.PlainText
              text: bluetooth.glyph
              color: bluetooth.ink
              font { family: bluetooth.typeface; pixelSize: Style.font.display }
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              id: radioSwitch
              visible: bluetooth.reachable
              checked: bluetooth.live
              hasCursor: cursor.shown && cursor.place.section === "header"
              foreground: bluetooth.ink
              onHovered: function(on) { if (on) cursor.point("header", cursor.place.index, false) }
              onToggled: bluetooth.toggleBluetooth()

              PanelToolTip {
                visible: radioSwitch.containsMouse
                text: bluetooth.live ? "Turn Bluetooth off" : "Turn Bluetooth on"
                fontFamily: bluetooth.typeface
              }
            }
          }
        }

        Rule {}

        Column {
          id: connectedColumn
          visible: bluetooth.connectedList.length > 0
          width: parent.width
          spacing: Style.space(10)

          Heading { text: "CONNECTED" }

          Repeater {
            model: bluetooth.connectedList
            DeviceItem { width: connectedColumn.width }
          }
        }

        Rule { visible: bluetooth.connectedList.length > 0 && bluetooth.scrollList.length > 0 }

        // Capped in height, so that a crowded room does not push the card off
        // the screen. The view keeps the cursor's row in sight, and moves only
        // when that row is cut off, so it never lurches under a still pointer.
        ListView {
          id: scroller
          width: parent.width
          height: Math.min(contentHeight, Style.space(400))
          spacing: Style.space(10)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          model: bluetooth.scrollList
          currentIndex: bluetooth.scrollAt
          // A turn later: each report of the scan makes the model anew, which
          // resets the view under a call made at once.
          onCurrentIndexChanged: if (currentIndex >= 0) Qt.callLater(reveal)

          function reveal() {
            if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain)
          }

          // A Column leaves out the heading it hides; a height bound to
          // `visible` as well loops when the view hides a delegate.
          delegate: Column {
            id: entry
            required property var modelData
            required property int index
            readonly property string title: Model.titleAt(bluetooth.scrollList, index)

            width: ListView.view.width
            spacing: Style.space(10)

            Rule { visible: entry.index > 0 && entry.title !== "" }
            Heading { visible: entry.title !== ""; text: entry.title }
            DeviceItem { width: entry.width; modelData: entry.modelData }
          }

          TouchpadScroll { flickable: scroller }
        }

        Text {
          visible: bluetooth.connectedList.length === 0 && bluetooth.scrollList.length === 0
          width: parent.width
          textFormat: Text.PlainText
          text: !bluetooth.reachable ? "No Bluetooth adapter" : !bluetooth.live ? "Turn Bluetooth on to scan" : "Scanning for devices…"
          color: bluetooth.faint
          font { family: bluetooth.typeface; pixelSize: Style.font.bodySmall }
          wrapMode: Text.WordWrap
        }
      }
    }
  }

  component Heading: PanelSectionHeader {
    foreground: bluetooth.ink
    fontFamily: bluetooth.typeface
  }

  component Rule: PanelSeparator {
    foreground: bluetooth.ink
  }

  // A device: its name over what is happening to it and, on a paired or
  // connected one under the pointer or the cursor, a button to forget it.
  // <modelData> is a row of Model.rowsOf. What is under way is the panel's,
  // so it stays with the device as it moves between the lists.
  component DeviceItem: CursorSurface {
    id: deviceItem
    required property var modelData
    readonly property var device: modelData.dev
    readonly property string list: modelData.section
    readonly property int slot: modelData.indexInSection
    readonly property bool canForget: Model.forgettable(list)
    readonly property string doing: Model.actionFor(bluetooth.underway, device.address)
    readonly property bool onRow: cursor.shown && cursor.place.section === list && cursor.place.index === slot
    readonly property color tone: Model.lively(device, doing) ? bluetooth.ink : bluetooth.faint

    hasCursor: onRow && !cursor.place.onForget
    current: device.connected
    foreground: bluetooth.ink
    implicitHeight: body.implicitHeight + Style.spacing.rowPaddingX

    MouseArea {
      id: pointer
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      cursorShape: deviceItem.device ? Qt.PointingHandCursor : Qt.ArrowCursor
      onContainsMouseChanged: if (containsMouse) cursor.point(deviceItem.list, deviceItem.slot, false)
      onClicked: function(mouse) { bluetooth.rowClicked(deviceItem, mouse.button === Qt.RightButton) }
    }

    PanelToolTip {
      visible: text !== "" && pointer.containsMouse && !cursor.place.onForget
      text: Model.clickHint(deviceItem.device, !deviceItem.canForget)
      fontFamily: bluetooth.typeface
    }

    Item {
      id: body
      anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: Style.space(10); rightMargin: Style.space(10) }
      implicitHeight: Math.max(mark.implicitHeight, words.implicitHeight, forget.implicitHeight)

      Text {
        id: mark
        anchors { left: parent.left; verticalCenter: parent.verticalCenter }
        textFormat: Text.PlainText
        text: deviceItem.current ? "󰂱" : "󰂯"
        color: deviceItem.tone
        font { family: bluetooth.typeface; pixelSize: Style.font.heading }
      }

      Column {
        id: words
        anchors {
          left: mark.right; leftMargin: Style.space(10)
          right: forget.visible ? forget.left : parent.right; rightMargin: forget.visible ? Style.space(8) : 0
          verticalCenter: parent.verticalCenter
        }
        spacing: Style.space(1)

        Text {
          width: words.width
          textFormat: Text.PlainText
          text: Model.label(deviceItem.device) || "Device"
          color: bluetooth.ink
          font { family: bluetooth.typeface; pixelSize: Style.font.body }
          elide: Text.ElideRight
        }

        Text {
          width: words.width
          visible: text !== ""
          textFormat: Text.PlainText
          text: Model.status(deviceItem.device, deviceItem.doing, deviceItem.list)
          color: deviceItem.tone
          font { family: bluetooth.typeface; pixelSize: Style.font.caption }
          elide: Text.ElideRight
        }
      }

      PanelActionButton {
        id: forget
        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
        visible: deviceItem.canForget && (pointer.containsMouse || deviceItem.onRow)
        iconText: "󰅙"
        tooltipText: "Forget"
        foreground: bluetooth.ink
        fontFamily: bluetooth.typeface
        hasCursor: deviceItem.onRow && cursor.place.onForget
        onHovered: function(on) {
          if (on) cursor.point(deviceItem.list, deviceItem.slot, true)
          else if (pointer.containsMouse) cursor.put(Model.cursor(cursor.place.section, cursor.place.index, false))
        }
        onClicked: bluetooth.act(bluetooth.liveDevice(deviceItem.device), "forget")
      }
    }
  }
}
