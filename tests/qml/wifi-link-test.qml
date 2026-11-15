import QtQuick
import Quickshell
import "plugins/settings/WifiLinkModel.js" as Model

// The rules of Settings' Wi-Fi page below the networks: what
// nova-network-status --verbose and nova-network-band print, and the band's
// choices and the line under them.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  // JSON leaves out what is undefined, and so does the test's answer.
  function same(one, other) {
    return JSON.stringify(one === undefined ? null : one) === JSON.stringify(other)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    check(same([Model.ssidText("caf\\xc3\\xa9"), Model.ssidText("plain name"), Model.ssidText("tab\\x09here"), Model.ssidText("bad\\xff"), Model.ssidText("del\\x7f"), Model.ssidText(null), Model.ssidText("100%")], ["café","plain name","tab\\x09here","bad\\xff","del\\x7f","","100%"]), "an SSID's bytes as text")
    check(same(Model.readFields("type\twifi\nssid\t  My Net \niface\twlan0  \nnoise\nspeed\t\t300\n"), {"type":"wifi","ssid":"  My Net ","iface":"wlan0","speed":"300"}), "a reading's fields")
    check(same(Model.readFields(undefined), {}), "no reading")
    check(same(Model.readBands("band\t5\nselected\t2.4\navailable\t2.4  5 6\n"), {"band":"5","selected":"2.4","available":["2.4","5","6"]}), "the bands")
    check(same(Model.readBands(""), {"band":"","selected":"auto","available":[]}), "none read")
    check(same([Model.bandLabel("2.4"), Model.bandLabel("")], ["2.4 GHz",""]), "a band's label")
    check(same(Model.bandChoices({ band: "5", selected: "auto", available: ["2.4", "5"] }).map(c => c.value), ["auto","2.4","5"]), "the band's choices")
    check(same(Model.bandChoices({ band: "5", selected: "6", available: ["2.4", "5"] }).map(c => c.label), ["Automatic","2.4 GHz","5 GHz","6 GHz"]), "with a pinned band no longer answering")
    check(same([Model.bandNote({ band: "5", selected: "auto", available: [] }), Model.bandNote({ band: "", selected: "auto", available: [] }), Model.bandNote({ band: "5", selected: "5", available: [] })], ["On 5 GHz now. Wi-Fi picks the band; choosing one reconnects.","Wi-Fi picks the band.","Kept on 5 GHz for this network. Choosing a band reconnects."]), "the band's note")

    console.log("DONE")
    Qt.quit()
  }
}
