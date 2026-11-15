import QtQuick
import qs.Commons
import qs.Ui

// A bar drawn as a frame, for what a drag leaves and shows: the place a
// widget was taken from, the widget under the pointer, the edge the bar
// would go to. The bar's background, or none on a see-through bar, inside a
// line of its text colour; <rounded> into a pill where it is short.
BorderSurface {
  required property Item bar
  property bool rounded: false

  color: bar.transparent ? "transparent" : bar.background
  frame: Border.flat(bar.textColour, 1)
  radius: rounded ? Math.min(Style.cornerRadius, height / 2) : 0
}
