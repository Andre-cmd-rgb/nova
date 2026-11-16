import QtQuick
import Quickshell
import "plugins/settings"

// The Keyboard & Mouse page, as Settings has it: its state read back only
// once every change has run. Two quick changes, the second before the state
// is back, each build on the one before: German and then French taken out
// leaves US alone, and the rate and then the delay sends both as set. And no
// fifth layout is offered, a US put ahead of a non-Latin first one counted.
ShellRoot {
  id: test

  property Item stage: Item {}
  property var sent: []

  function check(name, got, want) {
    const same = JSON.stringify(got) === JSON.stringify(want)
    console.log((same ? "ok   " : "FAIL ") + name + (same ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  // Every item under <item> that <test> passes, in order.
  function all(item, test) {
    let found = test(item) ? [item] : []
    for (let i = 0; i < item.children.length; i++) found = found.concat(all(item.children[i], test))
    return found
  }

  // The Remove button on the row of layout <code>.
  function removeOf(view, code) {
    const row = all(view, item => item.label === view.known.filter(k => k.value === code).map(k => k.name).concat([code])[0])[0]
    return all(row, item => item.text === "Remove" && typeof item.clicked === "function")[0]
  }

  function slider(view, from, to) {
    return all(view, item => typeof item.letGo === "function" && item.from === from && item.to === to)[0]
  }

  Component {
    id: page
    KeyboardView {}
  }

  function made(input) {
    const view = page.createObject(stage, { input: input })
    view.command.connect(argv => test.sent.push(argv.join(" ")))
    return view
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    const view = made({ layouts: ["us", "de", "fr"], repeat: { delay: 250, rate: 40 }, nonLatin: ["ru"], touchpad: false })
    removeOf(view, "de").clicked()
    removeOf(view, "fr").clicked()
    check("German, then French, taken out before the state is back: US alone", sent, ["nova-input layouts us fr", "nova-input layouts us"])
    check("and the page shows it at once", view.layouts, ["us"])

    sent = []
    const rate = slider(view, 10, 60), delay = slider(view, 3, 20)
    rate._drag(50)
    rate._release()
    delay._drag(6)
    delay._release()
    check("the rate, then the delay: the second keeps the first", sent, ["nova-input repeat 250 50", "nova-input repeat 300 50"])

    const four = made({ layouts: ["us", "ru", "de"], nonLatin: ["ru"] })
    const more = all(four, item => item.text === "Add Layout…")[0]
    check("US, Russian and German: a fourth is offered", more.visible, true)
    sent = []
    four.setLayouts(["ru", "us", "de", "fr"])
    check("Russian moved up: US stays ahead of it, four in all", [sent, four.layouts], [["nova-input layouts us ru de fr"], ["us", "ru", "de", "fr"]])
    check("and no fifth is offered", more.visible, false)
    const own = made({ layouts: ["ru", "de", "fr"], nonLatin: ["ru"] })
    check("three with a non-Latin first and no US, as an input.lua may have them: no fourth, for the US to come", all(own, item => item.text === "Add Layout…")[0].visible, false)

    console.log("DONE")
    Qt.quit()
  }
}
