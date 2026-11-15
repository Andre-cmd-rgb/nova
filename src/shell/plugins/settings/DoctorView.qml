import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Column {
  id: root
  width: parent ? parent.width : 0
  spacing: Style.space(8)
  property var results: []
  property string failure: ""
  readonly property bool busy: doctor.running

  function readResults(text, code) {
    try {
      var rows = JSON.parse(text)
      if (!Array.isArray(rows) || !rows.every(function (r) {
        return r && ["ok", "warn", "FAIL", "--"].indexOf(r.level) >= 0 && typeof r.what === "string" && Array.isArray(r.how)
      })) throw new Error("Invalid results")
      results = rows
      failure = code > 1 ? "The check could not finish." : ""
    } catch (e) { failure = "Could not read the check results." }
  }

  function check() {
    if (busy) return
    failure = ""
    results = []
    doctor.running = true
  }
  Process {
    id: doctor
    command: ["nova-doctor", "--json"]
    stdout: StdioCollector { id: output }
    onExited: function (code) { root.readResults(output.text, code) }
  }
  Line {
    label: "Check for Problems"
    Button { text: root.busy ? "Checking…" : "Check"; bordered: true; enabled: !root.busy; onClicked: root.check() }
  }
  Repeater {
    model: root.results
    Row {
      id: result
      required property var modelData
      width: root.width
      spacing: Style.space(8)
      Text {
        width: Style.space(40)
        text: result.modelData.level
        color: result.modelData.level === "FAIL" ? Commons.Color.urgent
          : (result.modelData.level === "--" ? Commons.Color.muted : Commons.Color.foreground)
        opacity: result.modelData.level === "warn" ? 0.7 : 1
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        textFormat: Text.PlainText
      }
      Column {
        width: parent.width - Style.space(48)
        Text {
          width: parent.width
          text: result.modelData.what
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: result.modelData.level === "--" ? Style.font.bodySmall : Style.font.body
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
        }
        Repeater {
          model: result.modelData.how
          Caption { required property string modelData; width: parent.width; text: modelData }
        }
      }
    }
  }
  Caption { width: parent.width; visible: text.length > 0; text: root.failure }

}
