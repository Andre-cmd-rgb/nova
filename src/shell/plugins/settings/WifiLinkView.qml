import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "WifiLinkModel.js" as Net

// The part of Wi-Fi's page the bar's Wi-Fi menu leaves out: the link's
// addresses, the band the connection is on, and the DNS provider.
// nova-network-status reads the link, nova-network-band reads the band and
// keeps a connection on one, and nova-dns reads the provider and sets one
// (through polkit, as root).
Column {
  id: root
  spacing: Style.space(22)

  // What the commands last read.
  property var link: ({})
  property var bands: Net.readBands("")
  property string provider: ""
  // A band or a provider asked for, shown while its command runs; and why
  // the last one was refused.
  property string bandAsked: ""
  property string providerAsked: ""
  property string refused: ""
  property bool customOpen: false

  readonly property bool linked: !!link.iface && (link.type === "wifi" || link.type === "ethernet")
  readonly property bool busy: change.running
  // On Wi-Fi with bands to choose from or one to undo, and through the
  // reconnect a choice causes, when for a moment there is no link.
  readonly property bool bandOffered: (link.type === "wifi" || bandAsked !== "")
    && (bands.available.length > 1 || bands.selected !== "auto")

  readonly property var providers: [
    { label: "Automatic", value: "DHCP" },
    { label: "Cloudflare", value: "Cloudflare" },
    { label: "Google", value: "Google" },
    { label: "Custom", value: "Custom" }
  ]

  function read() {
    readLink.ask()
    readBand.ask()
  }

  function pickBand(choice) {
    if (busy || choice === (bandAsked || bands.selected)) return
    bandAsked = choice
    refused = ""
    change.asker = "band"
    change.command = ["nova-network-band", choice]
    change.running = true
  }

  // A preset is set at once; Custom opens the field for the servers.
  function pickProvider(name) {
    if (busy || custom.busy) return
    customOpen = name === "Custom"
    if (customOpen) return
    providerAsked = name
    refused = ""
    change.asker = "dns"
    change.command = ["nova-dns", name]
    change.running = true
  }

  function copy(value) {
    if (value) Quickshell.execDetached(["wl-copy", "--", value])
  }

  Component.onCompleted: {
    read()
    readDns.ask()
  }

  // The link and the band follow a connection made or left elsewhere.
  Timer {
    interval: 5000
    repeat: true
    running: true
    onTriggered: root.read()
  }

  Probe {
    id: readLink
    command: ["nova-network-status", "--verbose"]
    onAnswered: function (text) { root.link = Net.readFields(text) }
  }

  // Mid-reconnect there is no network to read bands from: the last answer
  // stands until there is.
  Probe {
    id: readBand
    command: ["nova-network-band"]
    onAnswered: function (text) {
      var heard = Net.readBands(text)
      if (root.bandAsked !== "" && heard.available.length === 0) return
      root.bands = heard
    }
  }

  Probe {
    id: readDns
    command: ["nova-dns"]
    onAnswered: function (text) { root.provider = text.trim() || "DHCP" }
  }

  Process {
    id: change
    property string asker: ""
    stderr: StdioCollector { id: complaint }
    onExited: function (code) {
      var said = complaint.text.trim()
      if (change.asker === "band") {
        if (code !== 0) root.refused = said || "Could not change the band."
        root.bandAsked = ""
        root.read()
      } else {
        if (code === 0) root.provider = root.providerAsked
        else root.refused = said || "Could not change DNS."
        root.providerAsked = ""
      }
    }
  }

  Section {
    title: "CONNECTION"
    visible: root.linked

    Line {
      label: "IP Address"
      detail: root.link.ip || ""
      Button {
        text: "Copy"
        bordered: true
        enabled: !!root.link.ip
        onClicked: root.copy(root.link.ip)
      }
    }

    Line {
      label: "Gateway"
      detail: root.link.gateway || ""
      visible: !!root.link.gateway
      Button {
        text: "Copy"
        bordered: true
        onClicked: root.copy(root.link.gateway)
      }
    }
  }

  Section {
    title: "WI-FI BAND"
    visible: root.bandOffered

    ButtonGroup {
      options: Net.bandChoices(root.bands)
      value: root.bandAsked || root.bands.selected
      enabled: !root.busy
      onChanged: function (value) { root.pickBand(value) }
    }

    Caption {
      width: parent.width
      text: root.bandAsked !== "" ? "Reconnecting…" : Net.bandNote(root.bands)
    }
  }

  Section {
    title: "DNS"

    ButtonGroup {
      options: root.providers
      value: root.customOpen ? "Custom" : (root.providerAsked || root.provider)
      enabled: !root.busy
      onChanged: function (value) { root.pickProvider(value) }
    }

    Caption {
      width: parent.width
      text: root.providerAsked !== "" ? "Changing DNS…"
        : (root.provider === "DHCP" && !root.customOpen) ? "The network's own DNS servers." : ""
      visible: text.length > 0
    }

    DnsView {
      id: custom
      width: parent.width
      title: ""
      visible: root.customOpen
      onApplied: {
        root.customOpen = false
        readDns.ask()
      }
    }
  }

  Caption {
    width: parent.width
    visible: root.refused.length > 0
    text: root.refused
  }

  // A command whose whole output is its answer, asked again only once it has
  // answered.
  component Probe: Process {
    id: probe
    signal answered(string text)

    function ask() {
      if (!running) running = true
    }

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: probe.answered(text)
    }
  }
}
