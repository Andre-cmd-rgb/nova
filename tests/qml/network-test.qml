import QtQuick
import Quickshell
import "plugins/panels/network/Model.js" as Model

// The network panel's rules: glyphs, the header's words, the rows of networks
// and what they say, and the keys' cursor.
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
    check(same([Model.linkName("ethernet", true), Model.linkName("wifi", true), Model.linkName("disconnected", true), Model.linkName("disconnected", false)], ["Ethernet","Wi-Fi","Wi-Fi","Network"]), "the header's title")
    check(same([Model.linkNote("ethernet", false, true, false), Model.linkNote("wifi", false, true, false), Model.linkNote("disconnected", false, true, false), Model.linkNote("wifi", true, true, false), Model.linkNote("wifi", true, true, true), Model.linkNote("disconnected", true, true, false), Model.linkNote("disconnected", false, false, false)], ["Connected","Turned Off","Turned Off","Connected","Sign in required","Not connected","Not connected"]), "the header's note")
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

    check(same([Model.beyond("radio", 1, { rows: true }), Model.beyond("radio", 1, { rows: false }), Model.beyond("rows", -1, { radio: true }), Model.beyond("rows", -1, { radio: false }), Model.beyond("radio", -1, { rows: true }), Model.beyond("rows", 1, { radio: true })], ["rows","radio","radio","rows","radio","rows"]), "the cursor's stops: the switch above the networks")

    console.log("DONE")
    Qt.quit()
  }
}
