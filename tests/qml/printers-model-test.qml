import QtQuick
import Quickshell
import "plugins/settings/PrintersModel.js" as Printers

// The Printers page's rules: what a printer's state and reasons say in plain
// words, its paper, two-sided and color choices as the printer offers them,
// and how a device found is named.
ShellRoot {
  function check(got, want, what) {
    const same = JSON.stringify(got) === JSON.stringify(want)
    console.log((same ? "ok   " : "FAIL ") + what + (same ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  function say(printer) { return Printers.status(printer).text }

  Component.onCompleted: Qt.callLater(function () {
    const idle = { name: "Office", state: 3, reasons: [], accepting: true, jobs: [] }
    check(Printers.status(idle), { text: "Ready", tone: "ready" }, "an idle printer is ready")
    check(say(Object.assign({}, idle, { reasons: ["media-empty-error"] })), "Out of paper", "media-empty is out of paper")
    check(say(Object.assign({}, idle, { reasons: ["media-needed-warning"] })), "Out of paper", "media-needed too")
    check(say(Object.assign({}, idle, { reasons: ["media-jam-error"] })), "Paper jam", "a paper jam")
    check(say(Object.assign({}, idle, { reasons: ["cover-open-error"] })), "Cover open", "a cover open")
    check(say(Object.assign({}, idle, { reasons: ["door-open-report"] })), "Cover open", "a door open")
    check(say(Object.assign({}, idle, { reasons: ["toner-empty-error"] })), "Out of ink or toner", "toner-empty")
    check(Printers.status(Object.assign({}, idle, { reasons: ["toner-low-warning"] })), { text: "Low on ink or toner", tone: "warning" }, "low on toner is a warning")
    check(say(Object.assign({}, idle, { reasons: ["media-low-warning"] })), "Low on paper", "low on paper")
    check(say(Object.assign({}, idle, { reasons: ["offline-report"] })), "Can’t be reached", "offline is not reached")
    check(Printers.status(Object.assign({}, idle, { state: 5, reasons: ["paused"] })), { text: "Paused", tone: "quiet" }, "stopped and paused is paused")
    check(say(Object.assign({}, idle, { state: 5 })), "Stopped", "stopped with no reason is stopped")
    check(say(Object.assign({}, idle, { accepting: false })), "Not accepting documents", "not accepting")
    // A problem is said before a pause, and what is wrong before what is low.
    check(say(Object.assign({}, idle, { state: 5, reasons: ["paused", "media-jam-error"] })), "Paper jam", "a jam over a pause")
    const busy = Object.assign({}, idle, { state: 4, jobs: [{ id: 3, name: "report.pdf", state: 3 }, { id: 4, name: "slides.pdf", state: 5 }] })
    check(say(busy), "Printing “slides.pdf”", "the document being printed is named")
    check(say(Object.assign({}, busy, { reasons: ["toner-low-warning"] })), "Printing “slides.pdf”  ·  Low on ink or toner", "and what it is low on")
    check(say(Object.assign({}, idle, { state: 4 })), "Printing", "printing with no job known")

    check(Printers.kind({ name: "Office", model: "Acme Laser 9", location: "Hall" }), "Acme Laser 9  ·  Hall", "the model and where it is")
    check(Printers.kind({ name: "Office", model: "Unknown", info: "Front desk", location: "" }), "Front desk", "a model unknown falls back to the description")
    check(Printers.kind({ name: "Office", model: "", info: "Office", location: "" }), "", "a description that is the name says nothing")

    check([3, 4, 5, 6].map(s => Printers.jobText({ state: s, reasons: [] })), ["Waiting", "On hold", "Printing", "Stopped"], "jobs' states")
    check(Printers.jobText({ state: 4, reasons: ["cups-held-for-authentication"] }), "Asks for a user name and password", "a held job that asks for a password")

    check([80, 0, -1, -2, -3, 100, 101].map(l => Printers.levelOf({ level: l })), [80, 0, -1, -1, -1, 100, -1], "levels the printer does not give are -1")
    check(Printers.levelText({ level: 5 }), "5%", "a level in words")
    check(Printers.markerColor({ color: "#00FFFF" }, "#fff"), "#00FFFF", "a marker's own color")
    check(Printers.markerColor({ color: "none" }, "#fff"), "#fff", "none is the page's")
    check(Printers.markerColor({ color: "#00FFFF#FF00FF" }, "#fff"), "#fff", "several colors in one are the page's")

    const names = ["iso_a4_210x297mm", "na_letter_8.5x11in", "na_legal_8.5x14in", "iso_a5_148x210mm", "jis_b5_182x257mm",
      "na_index-4x6_4x6in", "om_small-photo_100x150mm", "iso_a4_210x297mm", "na_letter_8.5x11in_borderless", "auto", "main", "photo"]
    check(names.map(Printers.paperName), ["A4", "Letter", "Legal", "A5", "B5", "4×6 in", "100 × 150 mm", "A4", null, null, null, null], "paper keywords in words, trays and types left out")
    check(Printers.papers(names).map(p => p.label), ["A4", "Letter", "Legal", "A5", "B5", "4×6 in", "100 × 150 mm"], "each size once, in the printer's order")
    check(Printers.papers(["iso_a4_210x297mm", "iso_a4_8.27x11.69in"]).length, 1, "a size in two units once")

    check(Printers.sides(["one-sided"]), [], "a printer with one side is not asked")
    check(Printers.sides(["one-sided", "two-sided-long-edge", "two-sided-short-edge"]).map(s => s.label), ["One-sided", "Two-sided", "Two-sided, short edge"], "two sides offered with one")
    check(Printers.colors(["monochrome"]), [], "a black-and-white printer is not asked")
    check(Printers.colors(["auto", "color", "monochrome"]).map(c => c.label), ["Color", "Black and white"], "color and black and white, not auto")
    const paper = Printers.papers(["iso_a4_210x297mm", "na_letter_8.5x11in"])
    check(Printers.withDefault(paper, "iso_a4_210x297mm").map(o => o.label), ["Default (A4)", "A4", "Letter"], "the printer's own choice named in the first")
    check(Printers.withDefault(paper, "").map(o => o.label)[0], "Default", "or not named")
    check([Printers.chosen(paper, "na_letter_8.5x11in"), Printers.chosen(paper, ""), Printers.chosen(paper, "tabloid")], ["na_letter_8.5x11in", "default", "default"], "what is chosen, the default when it is not one offered")

    check(Printers.adminLine({ allowed: true, groups: ["wheel"] }), "", "an administrator has no line")
    check(Printers.adminLine({ allowed: false, groups: ["sys", "root", "wheel"] }), "Adding, removing and pausing printers is for administrators (the wheel group). This account is not one.", "anyone else is told why")
    check(Printers.adminLine(null), "", "before it is read, nothing")

    check(Printers.suggestName({ info: "Acme Laser 9 (office)" }, []), "Acme_Laser_9_office", "a name from the device's own words")
    check(Printers.suggestName({ info: "Acme Laser 9" }, ["Acme_Laser_9", "Acme_Laser_9_2"]), "Acme_Laser_9_3", "one that is not taken")
    check(Printers.suggestName({ info: "" , model: "" }, []), "Printer", "none from a device that says nothing")
    check(["Office", "a-b_c.d", "-x", "a b", "a/b", "a#b", ""].map(Printers.validName), [true, true, false, false, false, false, false], "names CUPS takes")

    const devices = [
      { uri: "usb://Acme/Z", info: "Acme Z", model: "Acme Z", driverless: false },
      { uri: "dnssd://Acme%20Z._ipp._tcp.local/", info: "Acme Z", model: "Acme Z", driverless: true },
      { uri: "dnssd://Hall._ipp._tcp.local/", info: "Hall", model: "Hall", driverless: true },
      { uri: "ipp://old/", info: "Old", model: "Old", driverless: true }
    ]
    check(Printers.newDevices(devices, [{ uri: "ipp://old/" }]).map(d => d.uri), ["dnssd://Acme%20Z._ipp._tcp.local/", "dnssd://Hall._ipp._tcp.local/"], "added ones are left out, a USB printer found twice stays once, and driverless first")
    check(Printers.deviceText(devices[1]), "Works without a driver", "a driverless device says so")
    check(Printers.deviceText({ uri: "usb://x", info: "A", model: "Acme A" }), "Acme A  ·  USB", "a USB device with its model")
    check(Printers.deviceText({ uri: "socket://10.0.0.5", info: "Box", model: "Box" }), "Network", "a network one")

    const drivers = [{ id: "a", name: "Acme Z, hpcups" }, { id: "b", name: "Generic PostScript" }, { id: "c", name: "Acme Z Series PCL" }]
    check(Printers.matchingDrivers(drivers, "acme z", 10).map(d => d.id), ["a", "c"], "drivers with every word")
    check(Printers.matchingDrivers(drivers, "", 2).map(d => d.id), ["a", "b"], "all, up to the limit")
    check(Printers.recommended({ driverless: true }, []).id, "everywhere", "a driverless device takes IPP Everywhere")
    check(Printers.recommended({ driverless: false }, drivers).id, "a", "else CUPS's first")
    check(Printers.recommended({ driverless: false }, []), null, "else none")
    console.log("DONE")
    Qt.quit()
  })
}
