import QtQuick
import QtQuick.Controls
import qs.Commons

// The open list of Dropdown, SearchableDropdown and MultiSelect: a popup in
// <fill> with the border <borderSpec>, its content a hairline inside the
// border. It takes the focus as it opens.
Popup {
  id: root

  property var borderSpec: Border.none()
  property color fill: "transparent"

  padding: Style.spacing.hairline
  topPadding: Border.top(borderSpec) + Style.spacing.hairline
  rightPadding: Border.right(borderSpec) + Style.spacing.hairline
  bottomPadding: Border.bottom(borderSpec) + Style.spacing.hairline
  leftPadding: Border.left(borderSpec) + Style.spacing.hairline
  focus: true

  background: BorderSurface {
    radius: Style.cornerRadius
    color: root.fill
    borderSpec: root.borderSpec
  }
}
