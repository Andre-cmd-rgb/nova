import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "DnsModel.js" as Model

Section {
  id: root
  title: "CUSTOM DNS"
  property string result: ""
  readonly property bool busy: change.running
  signal applied()
  readonly property var servers: Model.servers(addresses.text)

  function apply() {
    if (change.running || servers.length === 0) return
    result = ""
    change.command = ["nova-dns", "Custom"].concat(servers)
    change.running = true
  }
  // The addresses and Apply on one row, as Wi-Fi's password and Join.
  Line {
    label: "DNS servers"
    Row {
      spacing: Style.space(8)
      // Narrower in a narrow window, so the label keeps its room.
      TextField {
        id: addresses
        anchors.verticalCenter: parent.verticalCenter
        width: Math.max(Style.space(160), Math.min(Style.space(300), root.width - Style.space(200)))
        placeholderText: "1.1.1.1 2606:4700:4700::1111"
        enabled: !change.running
        onAccepted: root.apply()
      }
      Button {
        anchors.verticalCenter: parent.verticalCenter
        text: change.running ? "Applying…" : "Apply"
        bordered: true
        enabled: !change.running && root.servers.length > 0
        onClicked: root.apply()
      }
    }
  }
  Caption {
    width: parent.width
    text: root.result || (addresses.text.length > 0 && root.servers.length === 0 ? "Enter up to four IP addresses." : "")
    visible: text.length > 0
  }
  Process {
    id: change
    stderr: StdioCollector { id: error }
    onExited: function (code) {
      root.result = code === 0 ? "DNS updated." : (error.text.trim() || "Could not change DNS.")
      if (code === 0) root.applied()
    }
  }
}
