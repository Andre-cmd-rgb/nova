import QtQuick
import qs.Commons
import "BarModel.js" as BarModel

// The bar's three sections in one window. The left one starts 8 px from
// the bar's start, the right one ends 8 px from its end, and the centre
// spans the whole bar beneath them: its anchor widget at the bar's middle,
// the widgets before and after it to either side, or with no anchor all of
// them centred as one run. The centre's empty part takes the bar's own
// gesture, a double click.
Item {
  id: sections

  required property Item bar

  readonly property var layout: bar.layout
  // Where the centre's anchor is in it; -1 for none.
  readonly property int anchorAt: BarModel.indexOfId(layout.center, bar.anchor)
  readonly property bool anchored: anchorAt !== -1

  anchors.fill: parent

  Item {
    id: centre

    anchors.fill: parent

    // The bar's own gesture, on the centre's empty part: a double click
    // makes it see-through, or solid again. Only the left button.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton
      onDoubleClicked: sections.bar.toggleSeeThrough()
    }

    HoverHandler {
      onHoveredChanged: sections.bar.pointerOnCentre(hovered)
      // Its screen unplugged, the bar is made anew with no leave.
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
      entries: BarModel.before(sections.layout.center, sections.bar.anchor)
      anchors.right: anchorPlace.left
      anchors.verticalCenter: anchorPlace.verticalCenter
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
      entries: BarModel.after(sections.layout.center, sections.bar.anchor)
      anchors.left: anchorPlace.right
      anchors.verticalCenter: anchorPlace.verticalCenter
    }
  }

  Run {
    section: "left"
    entries: sections.layout.left
    anchors.left: parent.left
    anchors.leftMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
  }

  Run {
    section: "right"
    entries: sections.layout.right
    anchors.right: parent.right
    anchors.rightMargin: Style.space(8)
    anchors.verticalCenter: parent.verticalCenter
  }

  // A run of widgets along the bar. One not shown builds none: the centre
  // has a run for each way it can be laid out, and building both would run
  // every widget in it twice.
  component Run: Row {
    id: run

    property string section: ""
    property var entries: []
    property bool shown: true

    visible: shown && entries.length > 0

    // By <shown>, not by being visible: a run is not visible while its
    // window is unmapped for a moment (Remap, after a scale change), and
    // building every widget again for that lost what they held, an open
    // panel among it.
    Repeater {
      model: run.shown ? run.entries : []

      WidgetSlot {
        required property var modelData

        bar: sections.bar
        section: run.section
        entry: modelData
      }
    }
  }
}
