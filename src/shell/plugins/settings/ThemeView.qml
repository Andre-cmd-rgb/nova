import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The theme and the background, on Settings' Appearance page and the
// welcome's: a tile for each theme in its own colours, the adaptive theme's
// mode while one is in use, and the background's Next and Choose….
Column {
  id: root
  spacing: Style.space(22)

  // The state's appearance.
  property var appearance: ({})
  // Whether the background's row is there: the welcome leaves it out while
  // there is no other background to change to.
  property bool background: true
  // A nova-theme command, which the window runs and then reads the state.
  // <changes>: what it sets, by its path in what this view was given, which
  // Settings shows at once (SettingsState); null for none.
  signal command(var argv, var changes)

  Section {
    title: "THEME"
    Flow {
      width: parent.width
      spacing: Style.space(10)
      Repeater {
        model: root.appearance.themes || []
        delegate: Rectangle {
          id: swatch
          required property var modelData
          readonly property bool current: root.appearance.theme === modelData.name
          width: Style.space(118)
          height: Style.space(70)
          radius: Math.max(4, Style.cornerRadius)
          color: modelData.background || Commons.Color.background
          border.width: current ? 2 : 1
          border.color: current ? Commons.Color.accent : Qt.alpha(Commons.Color.foreground, 0.15)

          Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: Style.space(10)
            width: Style.space(26)
            height: Style.space(6)
            radius: height / 2
            color: swatch.modelData.accent || Commons.Color.accent
          }
          Text {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(10)
            text: swatch.modelData.name.replace(/-/g, " ")
            color: swatch.modelData.foreground || Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            // Two words that do not fit on one line ("catppuccin latte")
            // take two, which the tile has room for.
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
            textFormat: Text.PlainText
          }
          TapHandler { onTapped: if (!swatch.current) root.command(["nova-theme", "set", swatch.modelData.name], { theme: swatch.modelData.name }) }
        }
      }
    }
    Line {
      label: "Adaptive theme"
      visible: (root.appearance.adaptive || "") !== ""
      ButtonGroup {
        options: [{ value: "auto", label: "Auto" }, { value: "dark", label: "Dark" }, { value: "light", label: "Light" }]
        value: root.appearance.adaptive || "auto"
        onChanged: function (value) { root.command(["nova-theme", "adaptive", value], { adaptive: value }) }
      }
    }
  }

  Section {
    title: "BACKGROUND"
    visible: root.background
    Line {
      label: "Background"
      Row {
        spacing: Style.space(8)
        Button { text: "Next"; bordered: true; onClicked: root.command(["nova-theme", "bg", "next"], null) }
        Button { text: "Choose…"; bordered: true; onClicked: root.command(["nova-theme", "bg", "pick"], null) }
      }
    }
  }
}
