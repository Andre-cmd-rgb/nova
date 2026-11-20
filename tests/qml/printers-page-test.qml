// stub: bin/nova-printers nova-printers
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/settings" as Settings
import "plugins/settings/PrintersModel.js" as Model

// Settings → Printers against a stub of nova-printers: the printers and what
// each is doing in plain words, the one chosen (the default, or the one a
// notice names) with its inks, documents and choices, the commands each
// button runs, the controls off with one line why for a user who is not an
// administrator, the empty state, and Add Printer from the device found to
// the command that adds it.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }
  function same(got, want, what) {
    const equal = JSON.stringify(got) === JSON.stringify(want)
    console.log((equal ? "ok   " : "FAIL ") + what + (equal ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  Settings.PrintersView { id: page; width: 600; interval: 100000 }
  Settings.PrintersView { id: noted; width: 600; interval: 100000; focusPrinter: "Old" }

  FileView { id: listFile; path: test.home + "/pr-list"; printErrors: false; onSaved: test.saved() }
  FileView { id: failFile; path: test.home + "/pr-fail"; printErrors: false; onSaved: test.saved() }
  FileView { id: ranFile; path: test.home + "/pr-ran"; blockLoading: true; printErrors: false; onSaved: test.saved() }

  property var then: null
  function write(file, text, next) {
    then = next
    file.setText(text)
  }
  function saved() {
    const next = then
    then = null
    if (next) next()
  }

  function ran() {
    ranFile.reload()
    return ranFile.text().trim().split("\n").filter(line => line !== "")
  }

  // The first Item under <item> for which <test> holds, or null.
  function find(item, test) {
    const below = item.contentItem ? [item.contentItem] : item.children
    for (const child of below) {
      if (test(child)) return child
      const deeper = find(child, test)
      if (deeper) return deeper
    }
    return null
  }

  function all(item, test) {
    let found = []
    const below = item.contentItem ? [item.contentItem] : item.children
    for (const child of below) {
      if (test(child)) found.push(child)
      found = found.concat(all(child, test))
    }
    return found
  }

  function button(under, text) {
    return find(under, item => item.text === text && typeof item.clicked === "function")
  }

  // The steps, one after another: a function to run, or { until, what }.
  property var steps: []
  function go(list) {
    steps = list
    advance()
  }
  function advance() {
    if (steps.length === 0) {
      console.log("DONE")
      Qt.quit()
      return
    }
    const step = steps.shift()
    if (typeof step === "function") {
      step()
      Qt.callLater(advance)
    } else {
      waiter.step = step
      waiter.tries = 0
      waiter.restart()
    }
  }

  Timer {
    id: waiter
    property var step: null
    property int tries: 0
    interval: 50
    repeat: true
    onTriggered: {
      if (step.until()) {
        stop()
        advance()
      } else if (++tries > 100) {
        stop()
        test.check(false, step.what)
        steps = []
        console.log("DONE")
        Qt.quit()
      }
    }
  }

  function until(cond, what) { return { until: cond, what: what } }

  property var office: null

  Component.onCompleted: go([
    until(() => page.loaded && page.shown.name === "Hall", "the page reads the printers"),
    () => {
      same(page.printers.map(p => p.name), ["Office", "Hall", "Old"], "the printers CUPS has")
      same(page.selectedName, "Hall", "the default one is chosen")
      same(page.printers.map(p => Model.status(p).text), ["Printing “report.pdf”  ·  Low on ink or toner", "Ready", "Paused"], "each says what it is doing")
      check(find(page, item => item.text === "Default" && item.visible) !== null, "the default one is marked")
      check(page.may && page.adminLine === "", "an administrator has every control and no line")
      check(find(page, item => item.text === "INK AND TONER") === null || !find(page, item => item.text === "INK AND TONER").visible, "no ink section for a printer that reports none")
      page.select("Office")
    },
    until(() => page.shown.name === "Office", "the page reads the printer chosen"),
    () => {
      same(page.shown.markers.map(m => m.name), ["Black toner", "Cyan toner", "Magenta toner"], "its inks")
      same(page.shown.markers.map(m => Model.levelText(m)), ["80%", "5%", ""], "at their levels, none for one unknown")
      same(page.shown.jobs.map(j => j.name), ["report.pdf", "Budget.pdf"], "its documents")
      same(all(page, item => item.text === "Cancel" && typeof item.clicked === "function" && item.visible).length, 2, "each with Cancel")
      const signIns = () => all(page, item => item.text === "Sign In…" && typeof item.clicked === "function" && item.visible)
      page.user = "someone"
      same(signIns().length, 0, "another's job held for a password has no Sign In: CUPS takes it from its owner alone")
      page.user = "ann"
      same(signIns().length, 1, "the user's own has, and the one printing has none")
      signIns()[0].clicked()
    },
    until(() => ran().length === 1, "Sign In runs"),
    () => {
      same(ran(), ["sign-in Office 12"], "Sign In has the job asked about again, on Nova's card")
      write(ranFile, "", () => {})
    },
    until(() => ran().length === 0, "the commands noted are cleared"),
    () => {
      check(button(page, "Make Default") !== null, "it can be made the default")
      button(page, "Cancel").clicked()
      button(page, "Print Test Page").clicked()
      button(page, "Pause").clicked()
      button(page, "Make Default").clicked()
    },
    until(() => ran().length === 4, "the buttons' commands run"),
    () => {
      same(ran(), ["cancel Office 11", "test-page Office", "pause Office", "default Office"], "Cancel, Print Test Page, Pause and Make Default run nova-printers' commands, in order")
      page.setOption("media", "iso_a4_210x297mm")
      same(page.chosenNow, { media: "iso_a4_210x297mm" }, "a choice shows at once")
    },
    until(() => ran().length === 5, "the choice is made"),
    () => {
      same(ran()[4], "option Office media iso_a4_210x297mm", "paper size is the user's own option")
      const dropdowns = all(page, item => item.options !== undefined && item.changed !== undefined && item.visible)
      same(dropdowns.map(d => d.value), ["na_letter_8.5x11in", "default", "monochrome"], "the options show the user's choices, and the default where there is none")
      same(dropdowns.map(d => d.options.length), [3, 4, 3], "only what the printer takes: two sizes, three sides, two modes, each with the default")
      same(dropdowns[1].options.map(o => o.label), ["Default (One-sided)", "One-sided", "Two-sided", "Two-sided, short edge"], "two-sided in words")

      // Hall: one paper size, black and white only, one side: nothing to choose.
      page.select("Hall")
    },
    until(() => page.shown.name === "Hall", "Hall is read"),
    () => {
      same(all(page, item => item.options !== undefined && item.changed !== undefined && item.visible).length, 0, "a printer with nothing to choose has no choices")
      check(find(page, item => item.text === "No documents waiting") !== null, "and says no document waits")
      check(button(page, "Make Default") === null || !button(page, "Make Default").visible, "the default one is not offered to be made")
      // Removing asks first.
      button(page, "Remove…").clicked()
      check(page.removeSheet.opened, "Remove asks first")
      button(page.removeSheet, "Cancel").clicked()
      check(!page.removeSheet.opened && ran().length === 5, "and Cancel removes nothing")
      button(page, "Remove…").clicked()
      button(page.removeSheet, "Remove").clicked()
    },
    until(() => ran().length === 6, "the printer is removed"),
    () => {
      same(ran()[5], "remove Hall", "Remove, once asked, removes")
      check(!page.removeSheet.opened, "and the question is gone")
      write(failFile, "nova-printers: Removing a printer needs an administrator: this user is not in CUPS's admin group (sys root wheel).\n", () => {
        page.run(["nova-printers", "pause", "Old"])
      })
    },
    until(() => page.failure !== "", "a failure is said"),
    () => {
      check(page.failure.indexOf("needs an administrator") > 0 && page.failure.indexOf("nova-printers:") < 0, "a failed command's words are said, without the program's name")
      write(failFile, "", () => {})
      page.refresh()
    },

    // The notice's printer is the one shown.
    until(() => noted.loaded && noted.shown.name === "Old", "a printer named by a notice is shown"),
    () => same(noted.selectedName, "Old", "the printer a notice's button names is chosen, over the default"),

    // Not an administrator.
    () => write(listFile, JSON.stringify({
      printers: [{ name: "Office", info: "", location: "", model: "", uri: "ipp://x/", state: 3, reasons: ["media-jam-error"], message: "", accepting: true, jobs: [] }],
      default: "Office", admin: { allowed: false, groups: ["sys", "root", "wheel"] } }), () => page.refresh()),
    until(() => !page.may, "the page reads that this user may not administer"),
    () => {
      same(page.adminLine, "Adding, removing and pausing printers is for administrators (the wheel group). This account is not one.", "one plain line says why")
      check(find(page, item => item.text === page.adminLine) !== null, "and it is on the page")
      same(all(page, item => item.text === "Add Printer…" && typeof item.clicked === "function" && item.visible).map(b => b.enabled), [false], "Add Printer is off")
      same(button(page, "Pause").enabled, false, "so is Pause")
      same(button(page, "Remove…").enabled, false, "and Remove")
      same(button(page, "Print Test Page").enabled, true, "a test page is for everyone")
      same(Model.status(page.printers[0]).text, "Paper jam", "a jam is said")
    },

    // No printers.
    () => write(listFile, JSON.stringify({ printers: [], default: "", admin: { allowed: true, groups: ["wheel"] } }), () => page.refresh()),
    until(() => page.printers.length === 0, "the page reads that there are none"),
    () => {
      const none = find(page, item => item.label === "No printers")
      check(none !== null && none.visible, "no printers: it says so")
      same(all(page, item => item.text === "Add Printer…" && typeof item.clicked === "function" && item.visible).length, 1, "with Add Printer… once")
      same(page.selectedName, "", "and nothing chosen")
      page.addSheet.open()
    },

    // Add Printer.
    until(() => page.addSheet.searched, "the printers are looked for"),
    () => {
      same(page.addSheet.fresh.map(d => d.info), ["Acme Laser 9", "Office laser", "Acme Inkjet Z"], "the printers found, those that work without a driver first")
      page.addSheet.choose(page.addSheet.fresh[0])
      same([page.addSheet.step, page.addSheet.name, page.addSheet.driver.id, page.addSheet.driver.name], ["details", "Acme_Laser_9", "everywhere", "Works without a driver"], "one that works without a driver: named, and IPP Everywhere")
      page.addSheet.add()
    },
    until(() => ran().length === 8, "the printer is added"),
    () => {
      same(ran()[7], "add Acme_Laser_9 dnssd://Acme%20Laser._ipp._tcp.local/?uuid=1 everywhere", "add runs with the name, the device and -m everywhere")
      same(page.wantName, "Acme_Laser_9", "and it is chosen once CUPS lists it")
      page.addSheet.open()
    },
    until(() => page.addSheet.searched, "the printers are looked for again"),
    () => {
      page.addSheet.choose(page.addSheet.fresh[2])
    },
    until(() => page.addSheet.driver !== null, "the driver for its make and model is found"),
    () => {
      same(page.addSheet.driver.id, "drv:///acme.drv/inkjet-z.ppd", "the first driver CUPS lists for the model is the one offered")
      page.addSheet.all()
    },
    until(() => page.addSheet.allDrivers.length === 3, "every driver is listed"),
    () => {
      same(page.addSheet.step, "drivers", "Choose… lists every driver")
      same(page.addSheet.found.map(d => d.id), ["drv:///acme.drv/inkjet-z.ppd", "drv:///sample.drv/generic.ppd", "everywhere"], "to search")
      page.addSheet.use(page.addSheet.found[1])
      same([page.addSheet.step, page.addSheet.driver.id], ["details", "drv:///sample.drv/generic.ppd"], "one chosen is the driver")
      page.addSheet.name = "bad name"
      page.addSheet.add()
      same(ran().length, 8, "a name with a space adds nothing")
    }
  ])
}
