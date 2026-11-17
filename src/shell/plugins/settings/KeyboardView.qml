import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "KeyboardModel.js" as Model

// Keyboard & Mouse's page in Settings, over `nova input`: the keyboard's
// layouts, in order, and the keys that go from one to the next; how a held
// key repeats; the pointer's speed and which way a mouse wheel scrolls; and
// on a touchpad, its scrolling and whether a tap clicks. A change applies at
// once, and is kept over ~/.config/hypr/input.lua. The touchpad's own switch
// is the menu's and its key's. The first layout is the one each session
// starts with; one without Latin letters gets US ahead of it, so that Nova's
// keys work.
Column {
  id: root
  spacing: Style.space(22)

  // `nova input --json`, as `nova-settings state` reads it.
  property var input: ({})
  // Where the sheet that adds a layout opens: the window.
  property Item overlayParent: null
  // A `nova input` command, which the window runs and then reads the state.
  // <changes>: what it sets, by its path in what this view was given, which
  // Settings shows at once (SettingsState); null for none.
  signal command(var argv, var changes)

  readonly property var layouts: sent || input.layouts || []
  readonly property var repeat: input.repeat || ({ delay: 250, rate: 40 })
  readonly property var scrolling: input.naturalScroll || ({})
  // The layouts keyboard.lua puts US ahead of.
  readonly property var nonLatin: input.nonLatin || []

  // xkb's layouts and their variants, by name, read once.
  property var known: []

  // The layouts as last sent, as Hyprland will have them, shown ahead of the
  // state: Settings reads it back only once every change has run, and a
  // second change before then builds on the first, not on the layouts from
  // before it. Dropped as the state has them, or after three seconds
  // without (a change refused), as a slider's knob goes back.
  property var sent: null

  function setLayouts(list) {
    var next = Model.ahead(list, nonLatin)
    if (next.length === 0) return
    sent = next
    settle.restart()
    command(["nova-input", "layouts"].concat(next), null)
  }

  onInputChanged: if (sent && JSON.stringify(input.layouts || []) === JSON.stringify(sent)) sent = null

  Timer {
    id: settle
    interval: 3000
    onTriggered: root.sent = null
  }

  FileView {
    path: "/usr/share/X11/xkb/rules/evdev.lst"
    printErrors: false
    onLoaded: root.known = Model.layouts(text())
  }

  Section {
    title: "KEYBOARD LAYOUTS"

    Repeater {
      model: root.layouts
      delegate: Line {
        id: row
        required property string modelData
        required property int index
        label: Model.nameOf(root.known, modelData)

        Row {
          spacing: Style.space(8)
          visible: root.layouts.length > 1
          Button {
            iconText: "\u{F0143}"
            tooltipText: "Move up"
            bordered: true
            enabled: row.index > 0
            opacity: enabled ? 1 : 0.4
            onClicked: root.setLayouts(Model.moved(root.layouts, row.index, -1))
          }
          Button {
            iconText: "\u{F0140}"
            tooltipText: "Move down"
            bordered: true
            enabled: row.index < root.layouts.length - 1
            opacity: enabled ? 1 : 0.4
            onClicked: root.setLayouts(Model.moved(root.layouts, row.index, 1))
          }
          Button {
            text: "Remove"
            bordered: true
            onClicked: root.setLayouts(Model.moved(root.layouts, row.index, 0))
          }
        }
      }
    }

    Caption {
      width: parent.width
      visible: root.layouts.length === 0
      text: "No layouts found"
    }

    Item {
      width: parent.width
      height: add.height
      // xkb takes four at most, the US a non-Latin first one gets among them.
      Button {
        id: add
        anchors.right: parent.right
        text: "Add Layout…"
        bordered: true
        visible: Model.room(root.layouts, root.nonLatin) > 0
        onClicked: sheet.open()
      }
    }

    Line {
      visible: root.layouts.length > 1
      label: "Next layout"
      Dropdown {
        options: Model.switches(root.input.switch)
        value: root.input.switch || "none"
        onChanged: function (value) {
          if (value !== "other" && value !== root.input.switch) root.command(["nova-input", "switch", value], { switch: value })
        }
      }
    }
  }

  Section {
    title: "KEY REPEAT"

    Line {
      label: "Delay until repeat"
      detail: delay.knobAt * 50 + " ms"
      // In steps of 50 ms.
      LevelSlider {
        id: delay
        width: Style.space(220)
        from: 3
        to: 20
        wheelStep: 1
        whole: true
        value: Math.round(Number(root.repeat.delay) / 50)
        // With the rate where its knob is, not as the state had it: Settings
        // reads the state back only once every change has run.
        onLetGo: at => root.command(["nova-input", "repeat", String(Math.round(at) * 50), String(Math.round(rate.knobAt))],
          { "repeat.delay": Math.round(at) * 50, "repeat.rate": Math.round(rate.knobAt) })
      }
    }

    Line {
      label: "Repeat rate"
      detail: rate.knobAt + " per second"
      LevelSlider {
        id: rate
        width: Style.space(220)
        from: 10
        to: 60
        wheelStep: 5
        whole: true
        value: Number(root.repeat.rate)
        onLetGo: at => root.command(["nova-input", "repeat", String(delay.knobAt === delay.value ? root.repeat.delay : Math.round(delay.knobAt) * 50), String(Math.round(at))],
          { "repeat.rate": Math.round(at) })
      }
    }
  }

  Section {
    title: "POINTER"

    Line {
      label: "Speed"
      detail: Model.speedText(speed.knobAt / 10)
      // In tenths, -1 to 1.
      LevelSlider {
        id: speed
        width: Style.space(220)
        from: -10
        to: 10
        wheelStep: 1
        whole: true
        notches: 3
        value: Math.round(Number(root.input.speed || 0) * 10)
        onLetGo: at => root.command(["nova-input", "speed", String(Math.round(at) / 10)], { speed: Math.round(at) / 10 })
      }
    }

    Toggle {
      width: parent.width
      label: "Natural scrolling with a mouse"
      checked: root.scrolling.mouse === true
      onClicked: root.command(["nova-input", "natural-scroll", "mouse", checked ? "off" : "on"], { "naturalScroll.mouse": !checked })
    }
  }

  Section {
    title: "TOUCHPAD"
    visible: root.input.touchpad === true

    Toggle {
      width: parent.width
      label: "Natural scrolling"
      checked: root.scrolling.touchpad !== false
      onClicked: root.command(["nova-input", "natural-scroll", "touchpad", checked ? "off" : "on"], { "naturalScroll.touchpad": !checked })
    }

    Toggle {
      width: parent.width
      label: "Tap to click"
      checked: root.input.tapToClick !== false
      onClicked: root.command(["nova-input", "tap-to-click", checked ? "off" : "on"], { tapToClick: !checked })
    }
  }

  // The layouts to add, found by name as they are typed: Up and Down move
  // along them, Return adds the one lit.
  SettingsSheet {
    id: sheet
    parent: root.overlayParent
    anchors.fill: parent
    z: 100

    readonly property var found: Model.matching(root.known, search.text, root.layouts)

    function open() {
      search.text = ""
      list.currentIndex = 0
      opened = true
      search.forceActiveFocus()
    }

    function add(index) {
      if (index < 0 || index >= found.length) return
      opened = false
      root.setLayouts(root.layouts.concat([found[index].value]))
    }

    onCanceled: opened = false

    Text {
      width: parent.width
      text: "Add a Layout"
      textFormat: Text.PlainText
      color: Commons.Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.title
    }

    TextField {
      id: search
      width: parent.width
      placeholderText: "Search"
      onTextChanged: list.currentIndex = 0
      onAccepted: sheet.add(list.currentIndex)
      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Down) list.currentIndex = Math.min(sheet.found.length - 1, list.currentIndex + 1)
        else if (event.key === Qt.Key_Up) list.currentIndex = Math.max(0, list.currentIndex - 1)
        else return
        event.accepted = true
      }
    }

    ListView {
      id: list
      width: parent.width
      height: Style.space(260)
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      model: sheet.found

      delegate: Rectangle {
        id: choice
        required property var modelData
        required property int index
        width: list.width
        height: Style.space(32)
        radius: Style.cornerRadius
        color: ListView.isCurrentItem ? Style.selectedFill : "transparent"

        HoverHandler {
          onHoveredChanged: if (hovered) list.currentIndex = choice.index
        }
        TapHandler {
          onTapped: sheet.add(choice.index)
        }

        Text {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(10)
          anchors.rightMargin: Style.space(10)
          text: choice.modelData.name
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
      }

      Caption {
        anchors.centerIn: parent
        visible: sheet.found.length === 0
        text: root.known.length === 0 ? "Could not load layouts." : "No layouts found"
      }
    }

    Row {
      anchors.right: parent.right
      Button { text: "Cancel"; bordered: true; tabStop: true; onClicked: sheet.opened = false }
    }
  }
}
