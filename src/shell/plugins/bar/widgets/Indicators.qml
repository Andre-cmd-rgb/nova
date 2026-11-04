import QtQuick
import qs.Commons
import qs.Ui
import "../BarModel.js" as BarModel
import "IndicatorList.js" as IndicatorList

// Small switches: a screen recording, the night light, do not disturb,
// Caffeine. Those that are on are lit, nearest the centre; those that are off
// keep their room beside them, and show while the pointer is on the widget or
// on the bar's centre. Each is a file in ../indicators, named in the widget's
// `items` (or `indicators`, its older name), all of them when it names none.
BarWidget {
  id: host
  moduleName: "nova.indicators"

  readonly property var entries: IndicatorList.entries(settings)

  // The ids of those on, and the order they are lit in. The lit row is
  // built from <litRow>, whose items are moved rather than made again, so a
  // lit indicator keeps its copy while another comes or goes.
  property var states: ({})
  property var order: []
  ListModel { id: litRow }

  // What the indicators read: whether to show those that are off. They show
  // while the pointer is on the widget, or on one of them and 120 ms after,
  // so it can cross to the next without it fading; on the bar's centre,
  // unless the bar says not; or always, with `alwaysShow`.
  property bool pointerOnWidget: false
  property bool pointerOnButton: false
  readonly property bool centreHeld: bar?.centerSectionRevealHeld === true && bar?.centerHoverRevealSuppressed !== true
  readonly property bool revealInactiveIndicators: setting("alwaysShow", false) === true || pointerOnWidget || pointerOnButton || centreHeld

  // To the indicators that look for their state themselves (the recording):
  // look now. nova-shell nova.indicators refresh.
  signal refreshRequested()

  function refresh() {
    refreshRequested()
  }

  Component.onCompleted: refreshRequested()

  // An indicator saying it is on or off.
  function said(entry, on) {
    const id = BarModel.entryId(entry)
    if (id === "") return
    states = IndicatorList.turned(states, id, on)
    order = IndicatorList.lit(order, states, listedIds(), on ? id : "")
    relight()
  }

  onEntriesChanged: {
    order = IndicatorList.lit(order, states, listedIds(), "")
    relight()
  }

  function listedIds() {
    return entries.map(entry => BarModel.entryId(entry))
  }

  // <litRow> put in <order>: those gone taken out, the rest moved into
  // place, the new put in.
  function relight() {
    for (let i = litRow.count - 1; i >= 0; i--) {
      if (!order.includes(litRow.get(i).key)) litRow.remove(i)
    }
    order.forEach((key, place) => {
      let at = place
      while (at < litRow.count && litRow.get(at).key !== key) at++
      if (at === litRow.count) litRow.insert(place, { key: key })
      else if (at !== place) litRow.move(at, place, 1)
    })
  }

  function pointerOnArea(on) {
    pointerOnWidget = on
    if (on) letGo.stop()
    else letGo.restart()
  }

  // WidgetButton's, for the off indicators it draws.
  function setIndicatorItemHovered(on) {
    if (on) {
      pointerOnButton = true
      letGo.stop()
    } else {
      letGo.restart()
    }
  }

  Timer {
    id: letGo
    interval: 120
    onTriggered: if (!host.pointerOnWidget) host.pointerOnButton = false
  }

  implicitWidth: rows.implicitWidth
  implicitHeight: rows.implicitHeight

  HoverHandler {
    onHoveredChanged: host.pointerOnArea(hovered)
  }

  // The off ones, then the lit ones, along the bar. The off ones keep their
  // room and only fade: room made on a hover would move the clock and all
  // beside it each time the pointer crossed the bar.
  Line {
    id: rows

    Item {
      implicitWidth: host.vertical ? Math.max(unlit.implicitWidth, host.barSize) : unlit.implicitWidth
      implicitHeight: host.vertical ? unlit.implicitHeight : Math.max(unlit.implicitHeight, host.barSize)
      width: implicitWidth
      height: implicitHeight

      HoverHandler {
        onHoveredChanged: host.pointerOnArea(hovered)
      }

      Line {
        id: unlit
        anchors.verticalCenter: host.vertical ? undefined : parent.verticalCenter
        anchors.horizontalCenter: host.vertical ? parent.horizontalCenter : undefined
        opacity: host.revealInactiveIndicators ? 1 : 0
        enabled: host.revealInactiveIndicators

        Behavior on opacity {
          NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
        }

        Repeater {
          model: host.entries

          Indicator {
            required property var modelData
            entry: modelData
            block: "inactive"
          }
        }
      }
    }

    Line {
      Repeater {
        model: litRow

        Indicator {
          required property string key
          entry: host.entries.find(entry => BarModel.entryId(entry) === key) ?? { id: key }
          block: "active"
        }
      }
    }
  }

  // Indicators in a row along the bar, or a column on a side bar.
  component Line: Grid {
    rows: host.vertical ? -1 : 1
    columns: host.vertical ? 1 : -1
  }

  // One indicator, made from its file. Every one listed has a copy in the
  // off row, which hides itself while it is on, and one that is on has a
  // second copy in the lit row. Both say when they change, which is how the
  // lit row learns what to show.
  component Indicator: Item {
    id: indicator

    required property var entry
    required property string block
    readonly property string name: BarModel.entryId(entry)
    // A lit copy is made for an indicator that is on, and only once it has
    // said so does its going off count: before, it is still loading.
    property bool seenOn: false

    implicitWidth: file.item?.visible ? file.item.implicitWidth : 0
    implicitHeight: file.item?.visible ? file.item.implicitHeight : 0
    width: implicitWidth
    height: implicitHeight

    function report() {
      const on = file.item?.active === true
      if (block === "active" && on) seenOn = true
      else if (block === "active" && !seenOn) return
      host.said(entry, on)
    }

    onEntryChanged: {
      seenOn = false
      report()
    }

    // Which of the properties below the file has, looked up once it is
    // made: asked in a binding, `in` reads the property, and the binding
    // would hang on what it writes.
    property var takes: ({ item: null })

    Loader {
      id: file
      anchors.fill: parent
      source: indicator.name ? Qt.resolvedUrl("../indicators/" + indicator.name + ".qml") : ""
      onItemChanged: {
        const has = { item: item }
        if (item) ["bar", "indicatorBlock", "indicatorHost", "activeOverride"].forEach(name => has[name] = name in item)
        indicator.takes = has
      }
      onLoaded: indicator.report()
      onStatusChanged: if (status === Loader.Error) console.warn("Indicator loader error", indicator.name, source)
    }

    // What the file is handed, as the bar hands a widget its own.
    Hand { takes: indicator.takes; property: "bar"; value: host.bar }
    Hand { takes: indicator.takes; property: "indicatorBlock"; value: indicator.block }
    Hand { takes: indicator.takes; property: "indicatorHost"; value: host }
    Hand { takes: indicator.takes; property: "activeOverride"; value: indicator.block === "active" ? true : null }

    Connections {
      target: file.item
      ignoreUnknownSignals: true
      function onActiveChanged() { indicator.report() }
    }
  }

  // A property of an indicator's file, set while the file has it: <takes>
  // is the file and what it has.
  component Hand: Binding {
    id: hand

    property var takes: ({ item: null })

    target: takes.item
    when: !!hand.takes.item && hand.takes[hand.property] === true
  }
}
