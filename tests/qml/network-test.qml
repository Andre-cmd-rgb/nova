import QtQuick
import Quickshell
import "plugins/panels/network/Model.js" as Model

// The network panel's rules: glyphs, what nova-network-status and
// nova-network-band print, traffic and pings, the rows of networks and what
// they say, and the keys' cursor. The answers are those of the rules as they
// were before their rewrite.
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
    check(Model.signalOf({ signalStrength: 0.734 }) === 73 && Model.signalOf({ signalStrength: 1 }) === 100 && Model.signalOf({}) === 0, "a network's signal out of 100")
    check(same([0, 1, 20, 21, 40, 41, 60, 61, 80, 81, 100, 150, -5].map(s => Model.signalGlyph(s)), ["󰤯","󰤯","󰤯","󰤟","󰤟","󰤢","󰤢","󰤥","󰤥","󰤨","󰤨","󰤨","󰤯"]), "Wi-Fi bars by the fifth")
    check(same([Model.linkGlyph("wifi", 55), Model.linkGlyph("ethernet", 0), Model.linkGlyph("", 0), Model.linkGlyph("wwan", 90)], ["󰤢","󰈀","󰤮","󰤮"]), "the link's glyph")
    check(same([Model.ssidText("caf\\xc3\\xa9"), Model.ssidText("plain name"), Model.ssidText("tab\\x09here"), Model.ssidText("bad\\xff"), Model.ssidText("del\\x7f"), Model.ssidText(null), Model.ssidText("100%")], ["café","plain name","tab\\x09here","bad\\xff","del\\x7f","","100%"]), "an SSID's bytes as text")
    check(same(Model.readFields("type\twifi\nssid\t  My Net \niface\twlan0  \nnoise\nspeed\t\t300\n"), {"type":"wifi","ssid":"  My Net ","iface":"wlan0","speed":"300"}), "a reading's fields")
    check(same(Model.readFields(undefined), {}), "no reading")
    check(same([Model.linkSpeed({ type: "ethernet", speed: "100" }), Model.linkSpeed({ type: "ethernet", speed: "1000" }), Model.linkSpeed({ type: "ethernet", speed: "2500" }), Model.linkSpeed({ type: "ethernet", speed: "-1" }), Model.linkSpeed({ type: "ethernet", speed: "" }), Model.linkSpeed({ type: "wifi", speed: "866" }), Model.linkSpeed(null)], ["100mbit","1gbit","2.5gbit","","","",""]), "the link speed")
    check(same([Model.linkTitle({ type: "wifi", ssid: "Home" }, "wifi"), Model.linkTitle({ type: "wifi" }, "wifi"), Model.linkTitle({ type: "ethernet", speed: "1000" }, "ethernet"), Model.linkTitle({ iface: "wlan0" }, "disconnected"), Model.linkTitle({}, "disconnected"), Model.linkTitle({}, "none")], ["Home","Wi-Fi","Ethernet (1gbit)","wlan0","Disconnected","No connection"]), "the title")
    check(same(Model.traffic(null, { iface: "wlan0", rx_bytes: "1000", tx_bytes: "500" }, 10), {"iface":"wlan0","rx":1000,"tx":500,"time":10,"down":0,"up":0}), "a first reading of traffic")
    check(same(Model.traffic({ iface: "wlan0", rx: 1000, tx: 500, time: 10, down: 0, up: 0 }, { iface: "wlan0", rx_bytes: "3000", tx_bytes: "400" }, 12), {"iface":"wlan0","rx":3000,"tx":400,"time":12,"down":1000,"up":0}), "the rates from two")
    check(same(Model.traffic({ iface: "wlan0", rx: 1000, tx: 500, time: 10, down: 7, up: 3 }, { iface: "wlan0", rx_bytes: "3000", tx_bytes: "900" }, 10), {"iface":"wlan0","rx":3000,"tx":900,"time":10,"down":7,"up":3}), "one no later keeps the rates")
    check(same(Model.traffic({ iface: "wlan0", rx: 1000, tx: 500, time: 10, down: 7, up: 3 }, { iface: "eth0", rx_bytes: "3000" }, 12), {"iface":"eth0","rx":3000,"tx":0,"time":12,"down":0,"up":0}), "another interface starts over")
    check(same([Model.bytesText(0), Model.bytesText(512.4), Model.bytesText(1023.6), Model.bytesText(1536), Model.bytesText(1048575), Model.bytesText(734003200), Model.bytesText(1073741824), Model.bytesText(-3), Model.bytesText("x"), Model.bytesText(Infinity)], ["0 B","512 B","1024 B","1.5 KB","1024.0 KB","700.0 MB","1.00 GB","0 B","0 B","0 B"]), "bytes as text")
    check(same(Model.rateText(2048), "2.0 KB/s"), "a rate")
    check(same(Model.pings({ iface: "wlan0", samples: [10, null] }, { iface: "wlan0", internet_ping_ms: "12.5" }), {"iface":"wlan0","samples":[10,null,12.5]}), "pings kept")
    check(same(Model.pings({ iface: "wlan0", samples: [10] }, { iface: "wlan0", internet_ping_ms: "timeout" }), {"iface":"wlan0","samples":[10,null]}), "a lost one")
    check(same(Model.pings({ iface: "wlan0", samples: [10] }, { iface: "wlan0" }), {"iface":"wlan0","samples":[]}), "no ping starts over")
    check(same(Model.pings({ iface: "wlan0", samples: [10] }, { iface: "eth0", internet_ping_ms: "3" }), {"iface":"eth0","samples":[3]}), "another interface too")
    check(same(Model.pings({ iface: "e", samples: [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24] }, { iface: "e", internet_ping_ms: "25" }).samples, [2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25]), "the last 24")
    check(same([Model.pingTime([100, 1, 2, null, 3, 4]), Model.pingTime([null, null]), Model.pingTime([]), Model.pingTime([5])], [2.5,-1,-1,5]), "the mean of the last five answers")
    check(same([Model.pingLoss([1, null, null, 2]), Model.pingLoss([]), Model.pingLoss([null, 1, 1])], [50,0,33]), "the loss")
    check(same([Model.pingText(12.34, true), Model.pingText(4.56, true), Model.pingText(0, true), Model.pingText(-1, true), Model.pingText("x", true), Model.pingText(5, false), Model.pingText("250.6", true)], ["12 ms","4.6 ms","0 ms","Timeout","Timeout","--","251 ms"]), "a ping's words")
    check(same([Model.lossText(25, true), Model.lossText(0, true), Model.lossText(-4, true), Model.lossText("x", true), Model.lossText(10, false), Model.lossText("33.7", true)], ["25%","0%","0%","0%","--","33%"]), "the loss's words")
    check(same(Model.readBands("band\t5\nselected\t2.4\navailable\t2.4  5 6\n"), {"band":"5","selected":"2.4","available":["2.4","5","6"]}), "the bands")
    check(same(Model.readBands(""), {"band":"","selected":"auto","available":[]}), "none read")
    check(same([Model.bandName("5"), Model.bandName(""), Model.bandHeading("auto", "6"), Model.bandHeading("auto", ""), Model.bandHeading("5", "5"), Model.bandHint("2.4")], ["5ghz","","WI-FI BAND: 6GHZ","WI-FI BAND","WI-FI BAND","Stay on 2.4ghz"]), "a band's name, heading and hint")
    check(same(Model.networkRow({ connected: 1, known: 0, name: "Home", signalStrength: 0.734, security: 3 }), {"connected":true,"known":false,"ssid":"Home","signal":73,"security":3}), "a network's row")
    check(same([Model.networkRow({}), Model.networkRow(null)], [{"connected":false,"known":false,"ssid":"","signal":0},null]), "of one that says nothing, and of none")
    check(same(Model.sortRows([{ ssid: "a", connected: false, known: false, signal: 90 }, { ssid: "b", connected: false, known: true, signal: 20 }, { ssid: "c", connected: true, known: true, signal: 10 }, { ssid: "d", connected: false, known: true, signal: 70 }, { ssid: "e", connected: false, known: false, signal: 95 }]).map(r => r.ssid), ["c","d","b","e","a"]), "the rows in order")
    check(same([0, 1, 2, 3, 9].map(i => Model.rowHeading([{ known: true }, { known: true }, { known: false }, { known: false }], i)), ["KNOWN NETWORKS","","OTHER NETWORKS","",""]), "headings over the known and the rest")
    check(same([0, 1].map(i => Model.rowHeading([{ known: false }, { known: false }], i)), ["OTHER NETWORKS",""]), "with none known")
    check(same([Model.asksForSecret(0, 0, 9), Model.asksForSecret(9, 0, 9), Model.asksForSecret(3, 0, 9)], [false,false,true]), "what asks for a secret")
    check(same([Model.canForget({ known: true, connected: false }), Model.canForget({ known: true, connected: true }), Model.canForget({ known: false }), Model.canForget(null)], [true,false,false,false]), "what can be forgotten")
    check(same(Model.ENTERPRISE_SCRIPT, "u=$(uuidgen); IFS= read -r pw; nmcli connection add type wifi con-name \"$1\" ssid \"$1\" connection.uuid \"$u\" wifi-sec.key-mgmt wpa-eap 802-1x.eap peap 802-1x.phase2-auth mschapv2 802-1x.identity \"$2\" 802-1x.auth-timeout 8 >/dev/null && printf 'set 802-1x.password %s\\nsave\\nquit\\n' \"$pw\" | nmcli connection edit uuid \"$u\" >/dev/null && nmcli connection up uuid \"$u\" || { nmcli connection delete uuid \"$u\" >/dev/null 2>&1; false; }"), "the enterprise script")
    check(same([1, 2, 3, 4, 5, 6].map(r => Model.failureText(r, true, { NoSecrets: 1, WifiAuthTimeout: 2, WifiNetworkLost: 3, WifiClientDisconnected: 4, WifiClientFailed: 5 })), ["Passphrase required","Wrong password","Network lost","Disconnected","Connection failed","Failed to connect"]), "a failure's words")
    check(same([1, 2, 3].map(r => Model.failureText(r, false, { NoSecrets: 1, WifiAuthTimeout: 2, WifiNetworkLost: 3, WifiClientDisconnected: 4, WifiClientFailed: 5 })), ["Failed to connect","Failed to connect","Network lost"]), "on an open network")
    check(same([1, 2, 3].map(r => Model.asksAgain(r, true, { NoSecrets: 1, WifiAuthTimeout: 2, WifiNetworkLost: 3, WifiClientDisconnected: 4, WifiClientFailed: 5 })).concat([Model.asksAgain(1, false, { NoSecrets: 1, WifiAuthTimeout: 2, WifiNetworkLost: 3, WifiClientDisconnected: 4, WifiClientFailed: 5 })]), [true,true,false,false]), "asked again")
    check(same([Model.UNDERWAY, Model.TIMED_OUT], [{"connect":"Connecting…","disconnect":"Disconnecting…","forget":"Forgetting…"},{"connect":"Timed out connecting","disconnect":"Timed out disconnecting","forget":"Timed out forgetting"}]), "what a row says meanwhile")
    check(same([Model.beyond("radio", 1, { auto: true, rows: true }), Model.beyond("auto", 1, { rows: true }), Model.beyond("rows", 1, { radio: true }), Model.beyond("rows", -1, { radio: true, dns: true }), Model.beyond("radio", -1, { rows: true }), Model.beyond("pills", -1, {})], ["auto","rows","rows","dns","radio","pills"]), "the cursor's stops")

    console.log("DONE")
    Qt.quit()
  }
}
