import QtQuick
import qs.Commons
import qs.Ui

// A group of settings under an optional capitalised title.
Column {
  property alias title: header.text
  width: parent ? parent.width : 0
  spacing: Style.space(8)
  PanelSectionHeader {
    id: header
    visible: text.length > 0
  }
}
