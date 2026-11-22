import QtQuick
import Quickshell
import "plugins/bar/BarModel.js" as Model
import "plugins/bar/widgets/tray/TrayList.js" as Tray

// The bar's rules, apart from its windows: what a layout entry says, the
// centre's anchor, a change of settings alone, a widget moved in shell.json,
// the copy a key reaches, where a drag lands, where a tooltip goes, and which
// tray icons show.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function same(one, other) {
    return JSON.stringify(one) === JSON.stringify(other)
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  // Entries as the bar's sections hand them to a slot: through a Repeater,
  // which hands an object on as something other than the object.
  Item {
    Repeater {
      id: handed
      model: [{ id: "nova.clock", format: "HH:mm" }, "nova.menu", { id: "disk", exec: "df" }]

      Item {
        required property var modelData
      }
    }
  }

  // Copies of a widget as the bar hands them to reached(): a slot named
  // <name>, on <screen>, open or not, drawn unless <hidden>.
  function copy(name, screen, open, hidden) {
    return { slot: { name: name, visible: !hidden, width: hidden ? 0 : 20, height: 20 }, screen: screen, open: open === true }
  }

  function picked(copies, focused) {
    const slot = Model.reached(copies, focused)
    return slot ? slot.name : null
  }

  function run() {
    const center = [{ id: "nova.indicators" }, { id: "nova.clock", format: "HH:mm" }, { id: "nova.weather" }]

    // The centre's anchor: as shell.json names it, the clock for a name not
    // in the centre (one from before a rename), and none when none is named.
    check(Model.centerAnchor("nova.weather", center) === "nova.weather", "the widget shell.json names")
    check(Model.centerAnchor("old.clock", center) === "nova.clock", "a name not in the centre is the clock")
    check(Model.centerAnchor("old.clock", [{ id: "nova.weather" }]) === "old.clock", "unless the clock is not there either")
    check(Model.centerAnchor("", center) === "" && Model.centerAnchor(undefined, center) === "", "none named is none")

    // Entries.
    check(Model.entryId("nova.clock") === "nova.clock" && Model.entryId({ id: "nova.menu" }) === "nova.menu", "an entry's id, bare or in an object")
    check(Model.entryId({ id: 3 }) === "3" && Model.entryId({}) === "" && Model.entryId({ id: null }) === "" && Model.entryId(null) === "", "an id made a string, and none for none")
    check(same(Model.entrySettings({ id: "nova.clock", format: "HH:mm", size: 2 }), { format: "HH:mm", size: 2 }), "an entry's settings are all but its id")
    check(same(Model.entrySettings("nova.clock"), {}) && same(Model.entrySettings(null), {}), "a bare id has none")
    const slot = n => handed.itemAt(n).modelData
    check(Model.entryId(slot(0)) === "nova.clock" && Model.entryId(slot(1)) === "nova.menu", "an entry's id, handed through a Repeater")
    check(same(Model.entrySettings(slot(0)), { format: "HH:mm" }) && Model.customType(slot(2)) === "command", "and its settings and type")
    check(Model.indexOfId(center, "nova.weather") === 2 && Model.indexOfId(center, "nova.menu") === -1 && Model.indexOfId(null, "x") === -1, "where an id is in a section")
    check(same(Model.before(center, "nova.clock"), [center[0]]) && same(Model.after(center, "nova.clock"), [center[2]]), "the centre either side of its anchor")
    check(same(Model.before(center, "nova.menu"), []) && same(Model.after(center, "nova.menu"), []), "and nothing either side of one it lacks")
    check(same(Model.before(center, "nova.indicators"), []) && same(Model.after(center, "nova.weather"), []), "nothing before the first or after the last")

    // A user's own widgets.
    check(Model.customType({ id: "x", type: "qml", exec: "date" }) === "qml", "a type named is the type")
    check(Model.customType({ id: "x", exec: "date" }) === "command" && Model.customType({ id: "x", exec: "date", source: "f.qml" }) === "command", "with something to run, a command")
    check(Model.customType({ id: "x", source: "f.qml" }) === "qml", "with a file, QML")
    check(Model.customType({ id: "nova.clock" }) === "" && Model.customType("nova.clock") === "", "else one of Nova's")
    check(Model.customSource({ id: "x", source: "~/w/x.qml" }, "/home/u", "/home/u/.config/nova") === "/home/u/w/x.qml", "~/ is the home folder")
    check(Model.customSource({ id: "x", source: "$HOME/x.qml" }, "/home/u", "/c") === "/home/u/x.qml", "and so is $HOME/")
    check(Model.customSource({ id: "x", source: "/opt/x.qml" }, "/home/u", "/c") === "/opt/x.qml", "a path is the path")
    check(Model.customSource({ id: "notes" }, "/home/u", "/c") === "/c/bar/modules/notes.qml", "no source: the modules folder")
    check(Model.customSource({ id: "../x" }, "/h", "/c") === "" && Model.customSource({ id: "/x" }, "/h", "/c") === "" && Model.customSource({}, "/h", "/c") === "", "an id that leaves it is none")

    // A change of settings alone is pushed to the widgets in place.
    const was = { left: ["nova.menu"], center: center, right: [{ id: "nova.power", showPercentage: false }] }
    const clockFormat = { left: ["nova.menu"], center: [center[0], { id: "nova.clock", format: "HH:mm:ss" }, center[2]], right: was.right }
    check(same(Model.settingsOnlyChanges(was, was), []), "no change, nothing to push")
    check(same(Model.settingsOnlyChanges(was, clockFormat), [{ region: "center", index: 1, entry: { id: "nova.clock", format: "HH:mm:ss" } }]), "a setting changed is pushed, with its place")
    check(Model.settingsOnlyChanges(was, { left: [], center: center, right: was.right }) === null, "a widget gone builds again")
    check(Model.settingsOnlyChanges(was, { left: ["nova.workspaces"], center: center, right: was.right }) === null, "another widget in a place builds again")
    check(Model.settingsOnlyChanges({ left: [{ id: "u", exec: "date" }] }, { left: [{ id: "u", exec: "uptime" }] }) === null, "a user's widget changed builds again")
    check(Model.settingsOnlyChanges({ left: ["nova.spacer", "nova.spacer"] }, { left: [{ id: "nova.spacer", size: 4 }, "nova.spacer"] }) === null, "and one of two of a kind")
    check(Model.settingsOnlyChanges(null, was) === null && Model.settingsOnlyChanges(was, []) === null, "a layout that is none builds again")

    // A widget moved in shell.json.
    const config = { bar: { layout: { left: ["a", "b", "c"], right: ["d"] } } }
    check(Model.moveEntry(config, "left", "a", "left", "c") && same(config.bar.layout.left, ["b", "a", "c"]), "moved right, before the one named")
    check(Model.moveEntry(config, "left", "c", "right", "d") && same(config.bar.layout, { left: ["b", "a"], right: ["c", "d"] }), "to another section")
    check(Model.moveEntry(config, "right", "c", "left", "") && same(config.bar.layout.left, ["b", "a", "c"]), "to a section's end")
    check(!Model.moveEntry(config, "left", "a", "left", "c") && same(config.bar.layout.left, ["b", "a", "c"]), "to where it is: no move")
    check(!Model.moveEntry(config, "left", "x", "right", ""), "one not there: no move")
    const bare = {}
    check(!Model.moveEntry(bare, "left", "a", "center", "") && same(bare, { bar: { layout: { left: [], center: [] } } }), "the sections a file lacks are made")

    // The copy a key reaches.
    check(picked([copy("one", "DP-1"), copy("two", "DP-2")], "DP-2") === "two", "the copy on the focused screen")
    check(picked([copy("one", "DP-1", true), copy("two", "DP-2")], "DP-2") === "one", "an open one wherever it is")
    check(picked([copy("one", "DP-1"), copy("two", "DP-2")], "HDMI-A-1") === "one", "with none on the focused screen, the first copy's screen")
    check(picked([copy("one", "DP-1"), copy("two", "DP-2")], "") === "one", "and with no screen focused")
    check(picked([copy("hidden", "DP-2", false, true), copy("drawn", "DP-2")], "DP-2") === "drawn", "a copy drawn before one at no size")
    check(picked([copy("hidden", "DP-2", false, true), copy("other", "DP-1")], "DP-2") === "hidden", "but one at no size before none")
    check(picked([], "DP-1") === null && picked(null, "DP-1") === null, "no copies, none")
    check(Model.isDrawn({ visible: true, width: 1, height: 1 }) && !Model.isDrawn({ visible: true, width: 0, height: 1 }) && !Model.isDrawn({ visible: false, width: 1, height: 1 }), "drawn: shown, and of some size")
    check(Model.sameScreen({ name: "DP-1" }, { name: "DP-1" }) && !Model.sameScreen({ name: "DP-1" }, { name: "DP-2" }) && !Model.sameScreen(null, { name: "DP-1" }) && !Model.sameScreen({ name: "" }, { name: "" }), "screens are one by their name")

    // Where a dragged widget lands.
    const places = [{ slot: "a", x: 0, y: 0, width: 40, height: 26 }, { slot: "b", x: 50, y: 0, width: 40, height: 26 }, { slot: "z", x: 99, y: 0, width: 0, height: 26 }]
    check(same(Model.dropPlace(places, { x: 3, y: 9 }), { slot: "a", after: false }), "before the widget whose start is nearest")
    check(same(Model.dropPlace(places, { x: 44, y: 9 }), { slot: "a", after: true }), "after the one whose end is")
    check(same(Model.dropPlace(places, { x: 200, y: 9 }), { slot: "b", after: true }), "past the last, after it; one at no size passed over")
    check(Model.dropPlace([], { x: 1, y: 1 }) === null && Model.dropPlace(places, {}) === null, "nowhere, no place")
    check(same(Model.dropMarker({ x: 10, y: 0 }, 40, 26, true, 2), { x: 49, y: 0, width: 2, height: 26 }), "the line at a widget's end")

    check(Model.travelled({ x: 1, y: 1 }, { x: 4, y: -1 }) === 5, "how far a pointer went, along and across")

    // The bar's lists of slots and buttons.
    const one = { n: 1 }, two = { n: 2 }
    const list = [one]
    check(Model.listed(list, one, true) === list && Model.listed(list, two, false) === list && Model.listed(list, null, true) === list, "a list that would not change is the same list")
    check(same(Model.listed(list, two, true), [one, two]) && same(Model.listed([one, two], one, false), [two]), "else a new one, with it at the end or without it")

    // The bar's part of a shell.json, and a section of a layout.
    const written = { bar: [] }
    check(same(Model.barOf(written), {}) && same(written, { bar: {} }), "a bar part that is not an object is made anew")
    check(Model.barOf(config) === config.bar, "one there is the one")
    check(same(Model.section({ left: ["a"] }, "left"), ["a"]) && same(Model.section({ left: "a" }, "left"), []) && same(Model.section(null, "left"), []), "a section, empty for none")

    // Where a tooltip goes.
    check(same(Model.tipCorner(40, 26, 60, 6), { x: -10, y: 32 }), "under a widget, centred on it")

    // The tray's icons: all of them but those hidden, by id, whichever app
    // registered first.
    const icons = [{ id: "telegram", title: "Telegram" }, { id: "blueman", title: "Bluetooth" }, { id: "nm-applet", title: "" }, { id: "blueman", title: "A" }]
    check(same(Tray.shown(icons, []).map(item => item.title), ["A", "Bluetooth", "", "Telegram"]), "every icon, by id and then title")
    check(same(Tray.shown(icons, ["blueman"]).map(item => item.id), ["nm-applet", "telegram"]), "those hidden left out")
    check(Tray.shown(icons, undefined).length === 4 && Tray.shown(null, []).length === 0 && icons.length === 4, "no list, no items; the items given are not reordered")
    check(same(Tray.list("x"), []), "a setting that is no list is none")
    check(same(Tray.shown(icons, ["blueman\tA"]).map(item => item.title), ["Bluetooth", "", "Telegram"]),
      "one of two with an Id, by its Id and Title (Commons/TrayKey.js)")

    check(Model.hex(1, 0, 0.5) === "#ff0080" && Model.hex(2, -1, 0.02) === "#ff0005", "channels as #rrggbb, held to 0 and 1")

    console.log("DONE")
    Qt.quit()
  }
}
