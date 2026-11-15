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
  Line {
    label: "DNS Servers"
    Button {
      text: change.running ? "Applying…" : "Apply"
      bordered: true
      enabled: !change.running && root.servers.length > 0
      onClicked: root.apply()
    }
  }
  TextField {
    id: addresses
    width: parent.width
    placeholderText: "1.1.1.1 2606:4700:4700::1111"
    enabled: !change.running
    onAccepted: root.apply()
  }
  Caption {
    width: parent.width
    text: root.result || (addresses.text.length > 0 && root.servers.length === 0 ? "Enter one to four IPv4 or IPv6 addresses." : "")
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
