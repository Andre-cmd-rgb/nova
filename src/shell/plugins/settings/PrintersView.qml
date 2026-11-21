import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "PrintersModel.js" as Model

// Printers' page in Settings, over `nova-printers` (CUPS's own tools): the
// printers CUPS has and what each is doing, and for the one chosen its ink
// or toner, the documents waiting for it, a test page, pausing, the default,
// and the paper, two-sided and color choices it offers, which are the
// user's own (lpoptions). Add Printer lists the printers on the network
// and plugged in, with the driver CUPS recommends for each. Adding,
// removing and pausing are for CUPS's administrators (its SystemGroup, the
// wheel group on Arch): for anyone else the controls are off, with a line
// that says why.
//
// While the page is shown it asks CUPS every few seconds; it is made only
// while Settings' window is open (Panel's loader), so nothing is asked after.
Column {
  id: root
  spacing: Style.space(22)

  // Where the sheets open: the window.
  property Item overlayParent: null
  // The printer to show, and the job to point at, as a notification's
  // button asks for them.
  property string focusPrinter: ""
  property string focusJob: ""
  // How often CUPS is asked.
  property int interval: 4000

  // The sheets, for the tests.
  property alias addSheet: addSheet
  property alias removeSheet: removeSheet

  property var printers: []
  property bool loaded: false
  property bool reachable: true
  property string defaultName: ""
  property var admin: ({ allowed: true, groups: [] })
  property string selectedName: ""
  property var detail: ({})
  property string failure: ""
  // Whose jobs this user may sign in for: their own.
  property string user: Quickshell.env("USER") || ""
  // The printer to select once it is in the list (the one just added).
  property string wantName: ""
  // What the user chose in the options, shown until CUPS has it.
  property var chosenNow: ({})

  readonly property var selected: {
    for (var i = 0; i < printers.length; i++) if (printers[i].name === selectedName) return printers[i]
    return null
  }
  readonly property var shown: selected && detail.name === selected.name ? detail : ({})
  readonly property bool may: admin.allowed !== false
  readonly property bool paused: !!selected && Model.has(selected.reasons, ["paused", "moving-to-paused"])
  readonly property string adminLine: Model.adminLine(admin)
  readonly property var names: printers.map(function (p) { return p.name })

  // ---- asking CUPS ---------------------------------------------------------------

  function refresh() {
    if (!listProc.running) listProc.running = true
    else listAgain = true
  }
  property bool listAgain: false

  function select(name) {
    if (name === selectedName) return
    selectedName = name
    chosenNow = ({})
    refreshDetail()
  }

  function refreshDetail() {
    if (selectedName === "" || detailProc.running) return
    detailProc.command = ["nova-printers", "detail", selectedName]
    detailProc.running = true
  }

  function gotList(text) {
    var parsed
    try {
      parsed = JSON.parse(String(text))
    } catch (e) {
      return
    }
    if (!parsed || !Array.isArray(parsed.printers)) return
    printers = parsed.printers
    defaultName = parsed.default || ""
    admin = parsed.admin || ({ allowed: true, groups: [] })
    reachable = true
    loaded = true
    var wanted = ""
    if (wantName !== "" && names.indexOf(wantName) >= 0) {
      wanted = wantName
      wantName = ""
    } else if (focusPrinter !== "" && focusUsed !== focusPrinter && names.indexOf(focusPrinter) >= 0) {
      wanted = focusPrinter
      focusUsed = focusPrinter
    }
    if (wanted !== "") {
      if (selectedName !== wanted) { selectedName = wanted; chosenNow = ({}) }
    } else if (names.indexOf(selectedName) < 0) {
      selectedName = names.indexOf(defaultName) >= 0 ? defaultName : (names.length > 0 ? names[0] : "")
      chosenNow = ({})
    }
    refreshDetail()
  }
  // The focus asked for is taken once: a printer chosen after it stays.
  property string focusUsed: ""
  onFocusPrinterChanged: {
    focusUsed = ""
    refresh()
  }

  function gotDetail(text) {
    try {
      var parsed = JSON.parse(String(text))
      if (parsed && typeof parsed === "object") {
        detail = parsed
        chosenNow = ({})
      }
    } catch (e) {
      // A truncated read keeps what is shown.
    }
  }

  Process {
    id: listProc
    command: ["nova-printers", "list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.gotList(text)
    }
    onExited: function (code) {
      if (code !== 0) root.reachable = false
      if (root.listAgain) {
        root.listAgain = false
        root.refresh()
      }
    }
  }

  Process {
    id: detailProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.gotDetail(text)
    }
  }

  // Polled while the page is there, and then it is not.
  Timer {
    interval: root.interval
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Changes run one at a time, in order, and CUPS is asked again after the last.
  property var queue: []

  function run(argv) {
    failure = ""
    queue = queue.concat([argv])
    pump()
  }

  function pump() {
    if (act.running || queue.length === 0) return
    var next = queue.slice()
    act.command = next.shift()
    queue = next
    act.running = true
  }

  Process {
    id: act
    stderr: StdioCollector { id: actErrors }
    onExited: function (code) {
      if (code !== 0) {
        var words = String(actErrors.text).trim().split("\n").pop().replace(/^nova-printers: /, "")
        root.failure = words || "That did not work."
        root.queue = []
        root.chosenNow = ({})
      }
      if (root.queue.length > 0) root.pump()
      else root.refresh()
    }
  }

  function setOption(key, value) {
    if (!selected) return
    var next = Object.assign({}, chosenNow)
    next[key] = value
    chosenNow = next
    run(["nova-printers", "option", selected.name, key, value])
  }

  // ---- messages ----------------------------------------------------------------------

  Caption {
    width: parent.width
    visible: root.failure.length > 0
    text: root.failure
    color: Commons.Color.urgent
    TapHandler { onTapped: root.failure = "" }
  }

  Caption {
    width: parent.width
    visible: !root.reachable && root.printers.length === 0
    text: "Can’t reach the print service."
  }

  // ---- the printers ------------------------------------------------------------------

  Section {
    title: "PRINTERS"

    Repeater {
      model: root.printers
      delegate: Rectangle {
        id: row
        required property var modelData
        readonly property bool current: modelData.name === root.selectedName
        readonly property var report: Model.status(modelData)
        readonly property string kind: Model.kind(modelData)
        width: parent.width
        height: Style.space(56)
        radius: Style.cornerRadius
        color: current ? Style.selectedFill : (hover.hovered ? Qt.alpha(Commons.Color.foreground, 0.05) : "transparent")

        HoverHandler { id: hover }
        TapHandler { onTapped: root.select(row.modelData.name) }

        Text {
          id: glyph
          anchors.left: parent.left
          anchors.leftMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          text: "\u{F042A}"
          textFormat: Text.PlainText
          color: row.current ? Commons.Color.accent : Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.icon * 1.4
        }

        Column {
          anchors.left: glyph.right
          anchors.leftMargin: Style.space(12)
          anchors.right: tag.visible ? tag.left : parent.right
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            width: parent.width
            text: row.modelData.name
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: row.current
          }
          Text {
            width: parent.width
            text: row.report.text
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: row.report.tone === "problem" ? Commons.Color.urgent
              : row.report.tone === "busy" ? Commons.Color.accent
              : Commons.Color.quieter(Commons.Color.foreground, Commons.Color.background, 0.6)
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        Text {
          id: tag
          anchors.right: parent.right
          anchors.rightMargin: Style.space(14)
          anchors.verticalCenter: parent.verticalCenter
          visible: row.modelData.name === root.defaultName
          text: "Default"
          textFormat: Text.PlainText
          color: Commons.Color.quieter(Commons.Color.foreground, Commons.Color.background, 0.6)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }
    }

    Line {
      visible: root.loaded && root.printers.length === 0
      label: "No printers"
      Button {
        text: "Add Printer…"
        bordered: true
        enabled: root.may
        onClicked: addSheet.open()
      }
    }

    Item {
      width: parent.width
      height: add.height
      visible: root.printers.length > 0
      Button {
        id: add
        anchors.right: parent.right
        text: "Add Printer…"
        bordered: true
        enabled: root.may
        opacity: enabled ? 1 : 0.5
        onClicked: addSheet.open()
      }
    }

    Caption {
      width: parent.width
      visible: root.loaded && !root.may
      text: root.adminLine
    }
  }

  // ---- the printer chosen --------------------------------------------------------------

  Section {
    title: root.selected ? root.selected.name.toUpperCase() : ""
    visible: root.selected !== null

    Line {
      label: root.selected ? Model.status(root.selected).text : ""
      detail: root.selected ? Model.kind(root.selected) : ""
      Row {
        spacing: Style.space(8)
        Button {
          text: "Print Test Page"
          bordered: true
          onClicked: root.run(["nova-printers", "test-page", root.selected.name])
        }
        Button {
          text: root.paused ? "Resume" : "Pause"
          bordered: true
          enabled: root.may
          opacity: enabled ? 1 : 0.5
          onClicked: root.run(["nova-printers", root.paused ? "resume" : "pause", root.selected.name])
        }
      }
    }

    Line {
      label: "Default printer"
      detail: root.selected && root.selected.name === root.defaultName ? "Documents go here unless an app chooses another" : ""
      Button {
        visible: !!root.selected && root.selected.name !== root.defaultName
        text: "Make Default"
        bordered: true
        onClicked: root.run(["nova-printers", "default", root.selected.name])
      }
      Text {
        visible: !!root.selected && root.selected.name === root.defaultName
        text: "Yes"
        textFormat: Text.PlainText
        color: Commons.Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }
  }

  Section {
    title: "INK AND TONER"
    visible: root.selected !== null && (root.shown.markers || []).length > 0

    Repeater {
      model: root.shown.markers || []
      delegate: Line {
        id: marker
        required property var modelData
        readonly property int level: Model.levelOf(modelData)
        readonly property color ink: Model.markerColor(modelData, Commons.Color.foreground)
        label: modelData.name

        Row {
          spacing: Style.space(10)
          Rectangle {
            id: track
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(150)
            height: Style.space(8)
            radius: height / 2
            color: Qt.alpha(Commons.Color.foreground, 0.12)
            border.width: 1
            border.color: Qt.alpha(Commons.Color.foreground, 0.2)
            clip: true
            Rectangle {
              width: marker.level < 0 ? 0 : Math.max(parent.height, parent.width * marker.level / 100)
              height: parent.height
              radius: parent.radius
              color: marker.ink
              // Black ink on a dark page, and white on a light one, still shows.
              border.width: 1
              border.color: Qt.alpha(Commons.Color.foreground, 0.35)
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(40)
            horizontalAlignment: Text.AlignRight
            text: marker.level < 0 ? "—" : Model.levelText(marker.modelData)
            textFormat: Text.PlainText
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }

  Section {
    title: "WAITING TO PRINT"
    visible: root.selected !== null

    Repeater {
      model: root.shown.jobs || []
      delegate: Line {
        id: job
        required property var modelData
        label: modelData.name || "Document"
        detail: Model.jobText(modelData) + (modelData.user ? "  ·  " + modelData.user : "")
        Row {
          spacing: Style.space(8)
          // A held job's user name and password, asked for again on Nova's
          // card (nova-sessiond's printing duty): CUPS takes them from the
          // job's owner alone.
          Button {
            text: "Sign In…"
            bordered: true
            visible: Model.asksForPassword(job.modelData) && (!job.modelData.user || job.modelData.user === root.user)
            onClicked: root.run(["nova-printers", "sign-in", root.selected.name, String(job.modelData.id)])
          }
          Button {
            text: "Cancel"
            bordered: true
            onClicked: root.run(["nova-printers", "cancel", root.selected.name, String(job.modelData.id)])
          }
        }
      }
    }

    Caption {
      width: parent.width
      visible: (root.shown.jobs || []).length === 0
      text: "No documents waiting"
    }
  }

  Section {
    title: "YOUR DEFAULTS"
    visible: root.selected !== null && (paper.choices.length > 1 || twoSided.choices.length > 0 || colors.choices.length > 0)

    Line {
      id: paper
      property var choices: Model.papers((root.shown.media || {}).supported)
      property var options: Model.withDefault(choices, (root.shown.media || {}).default)
      visible: choices.length > 1
      label: "Paper size"
      Dropdown {
        options: paper.options
        value: Model.chosen(paper.choices, root.chosenNow.media !== undefined ? root.chosenNow.media : (root.shown.media || {}).mine)
        onChanged: function (value) { root.setOption("media", value) }
      }
    }

    Line {
      id: twoSided
      property var choices: Model.sides((root.shown.sides || {}).supported)
      property var options: Model.withDefault(choices, (root.shown.sides || {}).default)
      visible: choices.length > 0
      label: "Two-sided"
      Dropdown {
        options: twoSided.options
        value: Model.chosen(twoSided.choices, root.chosenNow.sides !== undefined ? root.chosenNow.sides : (root.shown.sides || {}).mine)
        onChanged: function (value) { root.setOption("sides", value) }
      }
    }

    Line {
      id: colors
      property var choices: Model.colors((root.shown.color || {}).supported)
      property var options: Model.withDefault(choices, (root.shown.color || {}).default)
      visible: choices.length > 0
      label: "Color"
      Dropdown {
        options: colors.options
        value: Model.chosen(colors.choices, root.chosenNow.color !== undefined ? root.chosenNow.color : (root.shown.color || {}).mine)
        onChanged: function (value) { root.setOption("color", value) }
      }
    }
  }

  Section {
    visible: root.selected !== null
    Line {
      label: "Remove this printer"
      Button {
        text: "Remove…"
        bordered: true
        enabled: root.may
        opacity: enabled ? 1 : 0.5
        onClicked: removeSheet.opened = true
      }
    }
  }

  // ---- removing ------------------------------------------------------------------------------

  SettingsSheet {
    id: removeSheet
    parent: root.overlayParent
    anchors.fill: parent
    z: 100
    onCanceled: opened = false

    Text {
      width: parent.width
      text: root.selected ? "Remove “" + root.selected.name + "”?" : ""
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.title
    }
    Caption {
      width: parent.width
      text: "Documents waiting for it are not printed."
    }
    Row {
      anchors.right: parent.right
      spacing: Style.space(8)
      Button { text: "Cancel"; bordered: true; tabStop: true; onClicked: removeSheet.opened = false }
      Button {
        text: "Remove"
        bordered: true
        foreground: Commons.Color.urgent
        tabStop: true
        onClicked: {
          removeSheet.opened = false
          var name = root.selected.name
          root.selectedName = ""
          root.run(["nova-printers", "remove", name])
        }
      }
    }
  }

  // ---- adding ----------------------------------------------------------------------------------

  // Add Printer: the printers found (step "devices"), a name and a driver
  // for the one chosen ("details"), and the other drivers, searched
  // ("drivers").
  SettingsSheet {
    id: addSheet
    parent: root.overlayParent
    anchors.fill: parent
    z: 100

    property string step: "devices"
    property var devices: []
    property bool searched: false
    property var device: null
    property var recommendedDrivers: []
    // While CUPS is asked for the drivers that fit the device chosen.
    property bool lookingForDriver: false
    property bool askedDrivers: false
    property var allDrivers: []
    property var driver: null
    property string name: ""
    readonly property var fresh: Model.newDevices(devices, root.printers)
    readonly property var found: Model.matchingDrivers(allDrivers, driverSearch.text, 100)

    function open() {
      step = "devices"
      devices = []
      searched = false
      device = null
      driver = null
      askedDrivers = false
      allDrivers = []
      opened = true
      discover.running = true
    }

    function choose(chosen) {
      device = chosen
      name = Model.suggestName(chosen, root.names)
      recommendedDrivers = []
      driver = chosen.driverless ? Model.recommended(chosen, []) : null
      askedDrivers = false
      step = "details"
      lookingForDriver = !chosen.driverless
      // The best fit for its make and model comes first.
      wantedModel = chosen.driverless ? "" : chosen.model || chosen.info
      if (wantedModel !== "") lookUp()
    }

    // The make and model the drivers are looked up for, "" for none: the
    // device chosen last. A look for another, still running, is let end and
    // its answer dropped, and this one asked then.
    property string wantedModel: ""

    function lookUp() {
      if (modelDrivers.running || wantedModel === "") return
      modelDrivers.asked = wantedModel
      modelDrivers.command = ["nova-printers", "drivers", wantedModel]
      modelDrivers.running = true
    }

    function all() {
      step = "drivers"
      driverSearch.text = ""
      if (!askedDrivers) {
        askedDrivers = true
        everyDriver.running = true
      }
      driverSearch.forceActiveFocus()
    }

    function use(chosen) {
      driver = { id: chosen.id, name: chosen.name, driverless: false }
      step = "details"
    }

    function add() {
      if (!device || !driver || !Model.validName(name)) return
      opened = false
      root.wantName = name
      root.run(["nova-printers", "add", name, device.uri, driver.id])
    }

    onCanceled: opened = false

    Process {
      id: discover
      command: ["nova-printers", "discover"]
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          try {
            addSheet.devices = JSON.parse(String(text)).devices || []
          } catch (e) {
            addSheet.devices = []
          }
        }
      }
      stderr: StdioCollector { id: discoverErrors }
      onExited: function (code) {
        addSheet.searched = true
        if (code !== 0) root.failure = String(discoverErrors.text).trim().replace(/^nova-printers: /, "") || "Could not look for printers."
      }
    }

    Process {
      id: modelDrivers
      // The make and model this run asks about.
      property string asked: ""
      readonly property bool current: asked === addSheet.wantedModel
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          if (!modelDrivers.current) return
          try {
            addSheet.recommendedDrivers = JSON.parse(String(text)).drivers || []
          } catch (e) {
            addSheet.recommendedDrivers = []
          }
          var best = Model.recommended(addSheet.device || ({}), addSheet.recommendedDrivers)
          if (best && !addSheet.driver) addSheet.driver = best
        }
      }
      stderr: StdioCollector { id: modelDriverErrors }
      onExited: function (code) {
        if (code !== 0 && current) root.failure = String(modelDriverErrors.text).trim().replace(/^nova-printers: /, "") || "Could not look for a driver."
      }
      // Done, failed, or never started (no exit then): the line says what
      // was found, and Choose… is there either way. A device chosen while
      // another's look ran is looked up once that one ends.
      onRunningChanged: {
        if (running) return
        if (!current && addSheet.wantedModel !== "") Qt.callLater(addSheet.lookUp)
        else addSheet.lookingForDriver = false
      }
    }

    Process {
      id: everyDriver
      command: ["nova-printers", "drivers"]
      stdout: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          try {
            addSheet.allDrivers = JSON.parse(String(text)).drivers || []
          } catch (e) {
            addSheet.allDrivers = []
          }
        }
      }
      stderr: StdioCollector { id: everyDriverErrors }
      onExited: function (code) {
        if (code !== 0) root.failure = String(everyDriverErrors.text).trim().replace(/^nova-printers: /, "") || "Could not list the drivers."
      }
    }

    Text {
      width: parent.width
      text: addSheet.step === "devices" ? "Add Printer" : addSheet.step === "drivers" ? "Choose a Driver" : "Add “" + (addSheet.device ? addSheet.device.info || addSheet.device.uri : "") + "”"
      textFormat: Text.PlainText
      elide: Text.ElideRight
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.title
    }

    // The printers found.
    ListView {
      id: deviceList
      width: parent.width
      height: Style.space(240)
      visible: addSheet.step === "devices"
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      model: addSheet.fresh

      delegate: Rectangle {
        id: choice
        required property var modelData
        width: deviceList.width
        height: Style.space(48)
        radius: Style.cornerRadius
        color: hoverDevice.hovered ? Style.selectedFill : "transparent"
        HoverHandler { id: hoverDevice }
        TapHandler { onTapped: addSheet.choose(choice.modelData) }

        Column {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          spacing: Style.space(2)
          Text {
            width: parent.width
            text: choice.modelData.info || choice.modelData.model || choice.modelData.uri
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
          Caption {
            width: parent.width
            text: Model.deviceText(choice.modelData)
            elide: Text.ElideRight
            wrapMode: Text.NoWrap
          }
        }
      }

      Caption {
        anchors.centerIn: parent
        visible: addSheet.fresh.length === 0
        text: addSheet.searched ? "No printers found" : "Looking for printers…"
      }
    }

    Caption {
      width: parent.width
      visible: addSheet.step === "devices" && addSheet.fresh.length > 0 && !addSheet.searched
      text: "Looking for printers…"
    }

    // The name and the driver.
    Column {
      width: parent.width
      spacing: Style.space(12)
      visible: addSheet.step === "details"

      Line {
        label: "Name"
        TextField {
          id: nameField
          width: Style.space(220)
          text: addSheet.name
          onTextChanged: addSheet.name = text
          onAccepted: addSheet.add()
        }
      }
      Caption {
        width: parent.width
        visible: addSheet.name.length > 0 && !Model.validName(addSheet.name)
        text: "A name has no spaces, slashes or number signs."
        color: Commons.Color.urgent
      }
      Line {
        label: "Driver"
        detail: addSheet.driver ? addSheet.driver.name : addSheet.lookingForDriver ? "Looking for a driver…" : "No driver found"
        Button {
          text: "Choose…"
          bordered: true
          onClicked: addSheet.all()
        }
      }
    }

    // Another driver, found by its words.
    Column {
      width: parent.width
      spacing: Style.space(12)
      visible: addSheet.step === "drivers"

      TextField {
        id: driverSearch
        width: parent.width
        placeholderText: "Search"
        onTextChanged: driverList.currentIndex = 0
        onAccepted: if (addSheet.found.length > 0) addSheet.use(addSheet.found[driverList.currentIndex])
        Keys.onPressed: function (event) {
          if (event.key === Qt.Key_Down) driverList.currentIndex = Math.min(addSheet.found.length - 1, driverList.currentIndex + 1)
          else if (event.key === Qt.Key_Up) driverList.currentIndex = Math.max(0, driverList.currentIndex - 1)
          else return
          event.accepted = true
        }
      }

      ListView {
        id: driverList
        width: parent.width
        height: Style.space(220)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: addSheet.found

        delegate: Rectangle {
          id: pick
          required property var modelData
          required property int index
          width: driverList.width
          height: Style.space(32)
          radius: Style.cornerRadius
          color: ListView.isCurrentItem ? Style.selectedFill : "transparent"
          HoverHandler { onHoveredChanged: if (hovered) driverList.currentIndex = pick.index }
          TapHandler { onTapped: addSheet.use(pick.modelData) }
          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            text: pick.modelData.name
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }
        }

        Caption {
          anchors.centerIn: parent
          visible: addSheet.found.length === 0
          text: everyDriver.running ? "Loading drivers…" : "No drivers found"
        }
      }
    }

    Row {
      anchors.right: parent.right
      spacing: Style.space(8)
      Button {
        visible: addSheet.step !== "devices"
        text: "Back"
        bordered: true
        tabStop: true
        onClicked: addSheet.step = addSheet.step === "drivers" ? "details" : "devices"
      }
      Button { text: "Cancel"; bordered: true; tabStop: true; onClicked: addSheet.opened = false }
      Button {
        visible: addSheet.step === "details"
        text: "Add"
        bordered: true
        tabStop: true
        enabled: !!addSheet.driver && Model.validName(addSheet.name)
        opacity: enabled ? 1 : 0.5
        onClicked: addSheet.add()
      }
    }
  }
}
