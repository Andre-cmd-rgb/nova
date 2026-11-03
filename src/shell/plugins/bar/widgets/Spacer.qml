import QtQuick
import qs.Ui

// Room along the bar and nothing in it: the entry's `size` in pixels, 12
// when it names none, and none at all at 0 or less.
BarWidget {
  readonly property var size: settings ? settings.size : undefined
  readonly property int length: size === undefined ? 12 : Number(size)

  moduleName: "nova.spacer"
  visible: length > 0
  implicitWidth: vertical ? barSize : length
  implicitHeight: vertical ? length : barSize
}
