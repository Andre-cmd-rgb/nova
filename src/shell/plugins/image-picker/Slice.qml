import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import qs.Commons

// One image of the picker's carousel: a slanted slice of it, or, chosen,
// the whole image open in the middle. A click opens a slice; on the open
// one, it takes the image.
Item {
  id: slice

  required property int index
  // ImagePicker.qml, whose image this is.
  required property var picker

  readonly property var image: picker.images[index]
  readonly property string thumbnail: image ? image.thumbnail : ""
  readonly property bool kept: picker.positions[index] >= 0
  readonly property bool chosen: kept && index === picker.chosen
  // How far it is from the chosen one, among the images the filter keeps:
  // slices more than 16 away are not drawn.
  readonly property int offset: picker.positions[index] - picker.chosenPosition
  readonly property bool nearby: kept && Math.abs(offset) <= 16

  // A slice loads its thumbnail once it comes near the chosen one, and
  // keeps it, so that moving through the carousel does not have Qt drop
  // and decode textures again, until the picker lets them all go.
  property bool sourceActivated: nearby
  onNearbyChanged: if (nearby) sourceActivated = true

  Connections {
    target: slice.picker
    function onThumbnailsReleasedChanged() {
      if (slice.picker.thumbnailsReleased) slice.sourceActivated = slice.nearby
    }
  }

  visible: nearby
  x: chosen ? picker.openX
    : offset < 0 ? picker.openX + offset * picker.pitch
    : picker.openX + picker.expandedWidth + picker.sliceSpacing + (offset - 1) * picker.pitch
  width: chosen ? picker.expandedWidth : picker.sliceWidth
  height: chosen ? picker.expandedHeight : picker.sliceHeight
  y: chosen ? 0 : (picker.expandedHeight - picker.sliceHeight) / 2
  z: chosen ? 100 : 50 - Math.min(Math.abs(offset), 40)

  // The slice's corners: a parallelogram leaning by skewOffset.
  readonly property real lean: Math.abs(picker.skewOffset)
  readonly property real topLeft: picker.skewOffset >= 0 ? lean : 0
  readonly property real topRight: picker.skewOffset >= 0 ? width : width - lean
  readonly property real bottomRight: picker.skewOffset >= 0 ? width - lean : width
  readonly property real bottomLeft: picker.skewOffset >= 0 ? 0 : lean

  // The parallelogram, white, as the mask the image is cut out by.
  Item {
    id: outline
    anchors.fill: parent
    visible: false
    layer.enabled: true

    Shape {
      anchors.fill: parent
      antialiasing: true
      preferredRendererType: Shape.CurveRenderer
      ShapePath {
        fillColor: "white"
        strokeColor: "transparent"
        startX: slice.topLeft; startY: 0
        PathLine { x: slice.topRight; y: 0 }
        PathLine { x: slice.bottomRight; y: slice.height }
        PathLine { x: slice.bottomLeft; y: slice.height }
        PathLine { x: slice.topLeft; y: 0 }
      }
    }
  }

  // The image, cut out, and dimmed unless it is the chosen one.
  Item {
    anchors.fill: parent
    layer.enabled: true
    layer.smooth: true
    layer.effect: MultiEffect {
      maskEnabled: true
      maskSource: outline
      maskThresholdMin: 0.3
      maskSpreadAtMin: 0.3
    }

    Image {
      anchors.fill: parent
      source: !slice.picker.thumbnailsReleased && slice.sourceActivated && slice.thumbnail ? Util.fileUrl(slice.thumbnail) : ""
      // Decoded at the open slice's size, the largest any slice is drawn,
      // so that moving the choice reloads none: the 1536x864 thumbnails
      // are made for a 2x screen, and a picture with no thumbnail is the
      // original, which may be a 50-megapixel photo.
      sourceSize: Qt.size(slice.picker.expandedWidth, slice.picker.expandedHeight)
      fillMode: Image.PreserveAspectCrop
      asynchronous: false
      cache: true
      smooth: true
    }

    Rectangle {
      anchors.fill: parent
      color: Util.alpha(slice.picker.dimColor, slice.chosen ? 0 : 0.42)
    }
  }

  // Its edge, thicker and in the theme's colour when chosen.
  Shape {
    anchors.fill: parent
    antialiasing: true
    preferredRendererType: Shape.CurveRenderer
    ShapePath {
      fillColor: "transparent"
      strokeColor: slice.chosen ? slice.picker.selectedBorder : slice.picker.unselectedBorder
      strokeWidth: slice.chosen ? 3 : 1
      startX: slice.topLeft; startY: 0
      PathLine { x: slice.topRight; y: 0 }
      PathLine { x: slice.bottomRight; y: slice.height }
      PathLine { x: slice.bottomLeft; y: slice.height }
      PathLine { x: slice.topLeft; y: 0 }
    }
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: slice.chosen ? slice.picker.accept() : slice.picker.choose(slice.index)
  }
}
