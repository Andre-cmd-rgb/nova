import QtQuick
import qs.Ui

// Empty room along the bar: `size` pixels, 12 when it names none; none at all
// at 0 or less.
BarWidget {
  readonly property int length: settings && settings.size !== undefined ? Number(settings.size) : 12

  moduleName: "nova.spacer"
  visible: length > 0
  implicitWidth: vertical ? barSize : length
  implicitHeight: vertical ? length : barSize
}
