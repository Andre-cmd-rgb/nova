import QtQuick
import qs.Commons
import "BarModel.js" as BarModel

// The bar's three sections in one window. The left one starts 8 px from
// the bar's start, the right one ends 8 px from its end, and the centre
// spans the whole bar beneath them: its anchor widget at the bar's middle,
// the widgets before and after it to either side, or with no anchor all of
// them centred as one run. The centre's empty part takes the bar's own
// gestures.
//
// Made for one orientation (<standing> on a side bar): a bar turned on its
// side gets a new one (ScreenBar), so nothing here follows bar.vertical,
// which would lay every widget out once more on its way out.
Item {
  id: sections

  required property Item bar
  required property bool standing

  readonly property var layout: bar.builtLayout
  // Where the centre's anchor is in it; -1 for none.
  readonly property int anchorAt: BarModel.indexOfId(layout.center, bar.anchorId)
  readonly property bool anchored: anchorAt !== -1

  anchors.fill: parent

  Item {
    id: centre

    anchors.fill: parent

    Grip {
      anchors.fill: parent
    }

    HoverHandler {
      onHoveredChanged: sections.bar.pointerOnCentre(hovered)
      // Turned on its side, or its screen unplugged, the bar is made anew
      // with no leave.
      Component.onDestruction: if (hovered) sections.bar.pointerOnCentre(false)
    }

    Run {
      section: "center"
      shown: !sections.anchored
      entries: sections.layout.center
      anchors.centerIn: parent
    }

    Run {
      section: "center"
      shown: sections.anchored
      entries: BarModel.before(sections.layout.center, sections.bar.anchorId)
      anchors.right: sections.standing ? undefined : anchorPlace.left
      anchors.bottom: sections.standing ? anchorPlace.top : undefined
      anchors.verticalCenter: sections.standing ? undefined : anchorPlace.verticalCenter
      anchors.horizontalCenter: sections.standing ? anchorPlace.horizontalCenter : undefined
    }

    // Kept while the centre has an anchor, whatever else changes: the
    // anchor's widget stays, its settings handed to it anew.
    Loader {
      id: anchorPlace

      active: sections.anchored
      anchors.centerIn: parent
      sourceComponent: WidgetSlot {
        bar: sections.bar
        section: "center"
        entry: sections.layout.center[sections.anchorAt]
      }
    }

    Run {
      section: "center"
      shown: sections.anchored
      entries: BarModel.after(sections.layout.center, sections.bar.anchorId)
      anchors.left: sections.standing ? undefined : anchorPlace.right
      anchors.top: sections.standing ? anchorPlace.bottom : undefined
      anchors.verticalCenter: sections.standing ? undefined : anchorPlace.verticalCenter
      anchors.horizontalCenter: sections.standing ? anchorPlace.horizontalCenter : undefined
    }
  }

  Run {
    section: "left"
    entries: sections.layout.left
    anchors.left: sections.standing ? undefined : parent.left
    anchors.top: sections.standing ? parent.top : undefined
    anchors.leftMargin: Style.space(8)
    anchors.topMargin: Style.space(8)
    anchors.verticalCenter: sections.standing ? undefined : parent.verticalCenter
    anchors.horizontalCenter: sections.standing ? parent.horizontalCenter : undefined
  }

  Run {
    section: "right"
    entries: sections.layout.right
    anchors.right: sections.standing ? undefined : parent.right
    anchors.bottom: sections.standing ? parent.bottom : undefined
    anchors.rightMargin: Style.space(8)
    anchors.bottomMargin: Style.space(8)
    anchors.verticalCenter: sections.standing ? undefined : parent.verticalCenter
    anchors.horizontalCenter: sections.standing ? parent.horizontalCenter : undefined
  }

  // A run of widgets along the bar: a row, or a column on a side bar. One
  // not shown builds none: the centre has a run for each way it can be laid
  // out, and building both would run every widget in it twice.
  component Run: Grid {
    id: run

    property string section: ""
    property var entries: []
    property bool shown: true

    visible: shown && entries.length > 0
    rows: sections.standing ? -1 : 1
    columns: sections.standing ? 1 : -1

    Repeater {
      model: run.visible ? run.entries : []

      WidgetSlot {
        required property var modelData

        bar: sections.bar
        section: run.section
        entry: modelData
      }
    }
  }

  // The bar's own gestures, on the centre's empty part: a drag, or a press
  // held, takes the bar to another edge; a double click makes it
  // see-through, or solid again.
  component Grip: MouseArea {
    id: grip

    property bool moving: false
    // The click a move ends with is not a click.
    property bool afterMove: false
    property point downAt: Qt.point(0, 0)

    acceptedButtons: Qt.LeftButton
    cursorShape: moving ? Qt.ClosedHandCursor : Qt.ArrowCursor
    pressAndHoldInterval: 200

    function follow(x, y) {
      var drag = sections.bar.barDrag
      drag.follow(sections.bar.screenPoint(grip.mapToItem(null, x, y), drag.window))
    }

    function startMoving(x, y) {
      if (moving) return
      moving = true
      sections.bar.barDrag.begin(sections.bar.windowOf(grip))
      follow(x, y)
    }

    onPressed: function(mouse) {
      moving = false
      afterMove = false
      downAt = Qt.point(mouse.x, mouse.y)
    }

    // A widget above hands its press-and-hold down without the press, and a
    // move with no press would have no release to end it.
    onPressAndHold: function(mouse) {
      if (pressed) startMoving(mouse.x, mouse.y)
    }

    onPositionChanged: function(mouse) {
      if (!(mouse.buttons & Qt.LeftButton)) return
      if (moving) follow(mouse.x, mouse.y)
      else if (Math.abs(mouse.x - downAt.x) + Math.abs(mouse.y - downAt.y) >= Style.space(4)) startMoving(mouse.x, mouse.y)
    }

    onReleased: function(mouse) {
      if (!moving) return
      moving = false
      afterMove = true
      sections.bar.barDrag.end(true)
      mouse.accepted = true
    }

    onCanceled: {
      moving = false
      afterMove = false
      sections.bar.barDrag.end(false)
    }

    onClicked: function(mouse) {
      if (!afterMove) return
      afterMove = false
      mouse.accepted = true
    }

    onDoubleClicked: function(mouse) {
      if (afterMove) {
        afterMove = false
        return
      }
      if (mouse.button !== Qt.LeftButton) return
      sections.bar.toggleSeeThrough()
      mouse.accepted = true
    }
  }
}
