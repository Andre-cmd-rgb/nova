import QtQuick
import Quickshell
import "plugins/settings/DnsModel.js" as Dns

ShellRoot {
  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }
  Component.onCompleted: Qt.callLater(function () {
    var good = ["1.1.1.1", "192.0.2.255", "10.0.0.1", "::1", "::", "2001:db8::1", "1:2:3:4:5:6:7:8"]
    check(good.every(Dns.validAddress), "IPv4, full IPv6 and compressed IPv6 validate")
    var bad = ["", "1.1.1.256", "1.2.3", "example.org", "1::2::3", "12345::", ":1:2", "1:2:3:4:5:6:7:8:9", ":::1", "--help", "1.1.1.1;true", "192.168.01.1", "010.1.1.1"]
    check(!bad.some(Dns.validAddress), "typos and shell syntax are refused")
    check(Dns.servers(" 1.1.1.1, 2001:db8::1 ").length === 2, "spaces and commas separate two addresses")
    check(Dns.servers("1.1.1.1 1.0.0.1 2606:4700:4700::1111 2606:4700:4700::1001").length === 4, "two of each family, as the presets have")
    check(Dns.servers("1.1.1.1 1.0.0.1 8.8.8.8 8.8.4.4 9.9.9.9").length === 0 && Dns.servers(" ").length === 0, "empty and more than four addresses cannot apply")
    console.log("DONE")
    Qt.quit()
  })
}
