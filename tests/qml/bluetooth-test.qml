import QtQuick
import Quickshell
import "plugins/panels/bluetooth/Model.js" as Model

// The Bluetooth panel's rules: which devices are shown and where, what a
// row says, what is asked of nova-bluetooth-device and when BlueZ has done
// it, which PipeWire sink is a device's, rfkill's switches, and the keys'
// cursor.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function same(one, other) {
    return JSON.stringify(one) === JSON.stringify(other)
  }

  function names(list) {
    return list.map(d => Model.label(d)).join(",")
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  // A QML list, as Bluetooth.devices.values and Pipewire.nodes.values are.
  Item {
    id: holder
    Item { objectName: "one" }
    Item { objectName: "two" }
  }

  function run() {
    const buds = { address: "AA:BB:CC:DD:EE:01", name: "Buds", deviceName: "Galaxy Buds", connected: true, paired: true, state: 1, batteryAvailable: true, battery: 0.734 }
    const mouse = { address: "AA:BB:CC:DD:EE:02", name: "Mouse", deviceName: "", connected: false, bonded: true, state: 0 }
    const keyboard = { address: "AA:BB:CC:DD:EE:03", name: "Keys", deviceName: "", connected: false, trusted: true }
    const speaker = { address: "AA:BB:CC:DD:EE:04", name: "Speaker", deviceName: "", connected: false }
    const tv = { address: "AA:BB:CC:DD:EE:05", name: "Another", deviceName: "", connected: false }
    const uuid = { address: "AA:BB:CC:DD:EE:06", name: "0000110b-0000-1000-8000-00805f9b34fb" }
    const bare = { address: "AA:BB:CC:DD:EE:07", name: "AA-BB-CC-DD-EE-07" }
    const hexy = { address: "AA:BB:CC:DD:EE:08", name: "0x1812" }
    const all = [speaker, mouse, buds, uuid, null, keyboard, tv, bare, hexy, { address: "x", name: "  " }]

    // Devices.
    check(Model.label(buds) === "Galaxy Buds" && Model.label(mouse) === "Mouse" && Model.label({ name: " Pad " }) === "Pad" && Model.label(null) === "", "a device's name: BlueZ's, else its alias, trimmed")
    check(same(Model.listOf([1, 2]), [1, 2]) && same(Model.listOf({ length: 2, 0: "a", 1: "b" }), ["a", "b"]) && same(Model.listOf(null), []) && same(Model.listOf({ length: -1 }), []), "a list from an array or a QML list")
    check(Model.listOf(holder.children).map(item => item.objectName).join() === "one,two", "and from a QML list of objects")
    const source = [3, 1]
    check(Model.listOf(source) !== source, "a copy, not the array itself")
    const groups = Model.lists(all)
    check(names(groups.connected) === "Galaxy Buds", "connected devices")
    check(names(groups.known) === "Keys,Mouse", "paired, bonded or trusted ones, by name")
    check(names(groups.discovered) === "Another,Speaker", "the rest, by name; made-up names and none left out")
    check(same(Model.rowOf(buds), { address: "AA:BB:CC:DD:EE:01", name: "Buds", deviceName: "Galaxy Buds", connected: true, state: 1, batteryAvailable: true, battery: 0.734, pairing: false }), "a row's copy of a device")
    check(same(Model.rowOf({}), { address: "", name: "", deviceName: "", connected: false, state: -1, batteryAvailable: false, battery: 0, pairing: false }), "and of one that says nothing")
    check(same(Model.sections(groups, false), ["connected", "known"]) && same(Model.sections(groups, true), ["connected", "known", "discovered"]), "the scan's list only while it runs")
    check(same(Model.sections({ connected: [], known: [], discovered: [speaker] }, true), ["discovered"]), "and empty lists not at all")
    check(Model.devicesIn(groups, "known") === groups.known && same(Model.devicesIn(groups, "header"), []), "a list's devices")
    const scroll = Model.scrollRows(groups, ["connected", "known", "discovered"])
    check(same(scroll.map(r => r.section + r.indexInSection + r.dev.name), ["known0Keys", "known1Mouse", "discovered0Another", "discovered1Speaker"]), "the scrolling rows: paired, then the scan's")
    check(Model.scrollRows(groups, ["connected", "known"]).length === 2, "without the scan's while it is not shown")
    check(same(Model.rowsOf([mouse], "known"), [{ dev: Model.rowOf(mouse), section: "known", indexInSection: 0 }]), "a row: the copy, its list and place")
    check(Model.rowIndex(scroll, "discovered", 1) === 3 && Model.rowIndex(scroll, "known", 5) === -1 && Model.rowIndex(scroll, "connected", 0) === -1, "where a row is among the scrolling ones")
    check(Model.titleAt(scroll, 0) === "PAIRED" && Model.titleAt(scroll, 1) === "" && Model.titleAt(scroll, 2) === "AVAILABLE" && Model.titleAt(scroll, 4) === "" && Model.titleAt(scroll, -1) === "", "a heading over the first row of each list")

    // A row.
    const row = Model.rowOf(buds)
    check(Model.status(row, "forgetting", "connected") === "Forgetting…" && Model.status(row, "disconnecting", "known") === "Disconnecting…", "what is being done to it")
    check(Model.status(Object.assign({}, row, { state: 2 }), "", "known") === "Disconnecting…", "BlueZ's disconnecting")
    check(Model.status(row, "", "connected") === "73%" && Model.status(Object.assign({}, row, { batteryAvailable: false }), "", "connected") === "", "connected: its battery, or nothing in the connected list")
    check(Model.status(Object.assign({}, row, { batteryAvailable: false }), "", "known") === "Connected", "and in the paired list, that it is")
    check(Model.status(Model.rowOf(mouse), "connecting", "known") === "Connecting…" && Model.status(Object.assign(Model.rowOf(mouse), { state: 3 }), "", "known") === "Connecting…" && Model.status(Object.assign(Model.rowOf(mouse), { pairing: true }), "", "discovered") === "Connecting…", "connecting, by the panel, BlueZ or a pairing")
    check(Model.status(Model.rowOf(mouse), "", "known") === "" && Model.status({}, "", "known") === "", "else nothing")
    check(Model.lively(row, "") && Model.lively(Model.rowOf(mouse), "connecting") && Model.lively(Object.assign(Model.rowOf(mouse), { state: 3 }), "") && !Model.lively(Model.rowOf(mouse), ""), "full strength while connected or busy")
    check(Model.forgettable("connected") && Model.forgettable("known") && !Model.forgettable("discovered") && !Model.forgettable("header"), "a forget button for a paired device")
    check(Model.clickHint(row, false) === "Disconnect" && Model.clickHint(Model.rowOf(mouse), false) === "Connect" && Model.clickHint(Model.rowOf(speaker), true) === "Pair", "what a click does")

    // Actions.
    const actions = Model.withAction({ a: "connecting" }, "b", "forgetting")
    check(same(actions, { a: "connecting", b: "forgetting" }) && Model.actionFor(actions, "b") === "forgetting" && Model.actionFor(actions, "c") === "", "the actions under way, by address")
    check(same(Model.request(mouse, "connect"), { verb: "connect", word: "connecting" }) && same(Model.request(speaker, "connect"), { verb: "pair", word: "connecting" }), "a connect, or a pairing for one not paired")
    check(same(Model.request(buds, "disconnect"), { verb: "disconnect", word: "disconnecting" }) && same(Model.request(mouse, "forget"), { verb: "forget", word: "forgetting" }), "a disconnect, a forget")
    check(Model.request(buds, "connect") === null && Model.request(mouse, "disconnect") === null && Model.request({}, "connect") === null && Model.request(null, "forget") === null, "nothing to do, nothing asked")
    const later = [Object.assign({}, mouse, { connected: true }), Object.assign({}, buds, { connected: false }), Object.assign({}, keyboard, { trusted: false })]
    const done = Model.settle({ [mouse.address]: "connecting", [buds.address]: "disconnecting", [keyboard.address]: "forgetting", [speaker.address]: "connecting", gone: "forgetting" }, later)
    check(same(done.actions, { [speaker.address]: "connecting" }) && done.changed === true, "BlueZ caught up: those actions taken off")
    check(done.connected.length === 1 && done.connected[0].address === mouse.address, "and the devices just connected")
    const none = Model.settle({ [speaker.address]: "connecting", [buds.address]: "disconnecting" }, [speaker, buds])
    check(none.changed === false && same(none.actions, { [speaker.address]: "connecting", [buds.address]: "disconnecting" }) && none.connected.length === 0, "not yet: left as they are")
    check(Model.settle({ x: "disconnecting" }, [null]).changed === false && Model.settle({ x: "forgetting" }, [null]).changed === true, "a device gone is forgotten, not disconnected")

    // Audio.
    const sink = { ready: true, isSink: true, isStream: false, name: "bluez_output.AA_BB_CC_DD_EE_01.1", description: "", properties: { "api.bluez5.address": "AA:BB:CC:DD:EE:01" } }
    const byName = { ready: true, isSink: true, isStream: false, name: "sink2", description: "Galaxy Buds", properties: {} }
    const stream = { ready: true, isSink: true, isStream: true, name: "bluez_output.AA_BB_CC_DD_EE_01.1", properties: {} }
    const notReady = { ready: false, isSink: true, isStream: false, name: "x", description: "y", properties: { "device.alias": "Speaker" } }
    check(Model.sinkFor([stream, sink], buds) === sink, "a device's sink by its address, not a stream")
    check(Model.sinkFor([byName], buds) === byName && Model.sinkFor([byName], mouse) === null, "else by its name")
    check(Model.sinkFor([notReady], speaker) === null && Model.sinkFor([Object.assign({}, notReady, { ready: true })], speaker) !== null, "a node's properties once it is ready")
    check(Model.sinkFor([sink], null) === null && Model.sinkFor([{ isSink: false, name: "AA:BB:CC:DD:EE:01" }], buds) === null && Model.sinkFor([], buds) === null, "no device, no sink, none")
    check(Model.sinkFor([{ ready: true, isSink: true, isStream: false, name: "x", properties: { "device.string": "aa-bb-cc-dd-ee-01" } }], buds) !== null, "an address in any of its forms")

    // The radio.
    check(same(Model.radio({}, "1700000000.1: idx 0 type 2 op 0 soft 1 hard 0"), { "0": true }), "a Bluetooth switch blocked")
    check(same(Model.radio({ "0": true }, "idx 0 type 2 op 2 soft 0 hard 0"), { "0": false }) && same(Model.radio({ "0": false }, "idx 1 type 2 op 0 soft 0 hard 1"), { "0": false, "1": true }), "unblocked, and another blocked by hand")
    check(same(Model.radio({ "0": true, "1": false }, "idx 0 type 2 op 1 soft 0 hard 0"), { "1": false }), "a switch gone")
    check(Model.radio({}, "idx 0 type 1 op 0 soft 1 hard 0") === null && Model.radio({}, "nonsense") === null, "a line about anything else")

    // The cursor.
    const shown = ["connected", "known", "discovered"]
    const at = (s, i, f) => Model.cursor(s, i, f === true)
    check(same(Model.cursor("known", 1, true), { section: "known", index: 1, onForget: true }), "a cursor: a list, a row, the forget button")
    check(same(Model.move(at("header", 4), 1, shown, groups), at("connected", 0)) && same(Model.move(at("header", 4), -1, shown, groups), at("header", 4)), "from the switch down to the first row; not up")
    check(same(Model.move(at("connected", 0), 1, shown, groups), at("known", 0)) && same(Model.move(at("known", 0), 1, shown, groups), at("known", 1)), "down a list, and into the next")
    check(same(Model.move(at("discovered", 1), 1, shown, groups), at("discovered", 1)), "not past the last")
    check(same(Model.move(at("known", 0), -1, shown, groups), at("connected", 0)) && same(Model.move(at("discovered", 0), -1, shown, groups), at("known", 1)), "up into the list before, at its last row")
    check(same(Model.move(at("connected", 0, true), -1, shown, groups), at("header", 0)) && same(Model.move(at("known", 1, true), -1, shown, groups), at("known", 0)), "up to the switch; the forget button left")
    check(same(Model.move(at("known", 2), 1, [], groups), at("header", 2)) && same(Model.move(at("gone", 2), 1, shown, groups), at("connected", 0)), "with no lists, the switch; from a list not shown, the first")
    check(same(Model.clamp(at("header", 3), shown, groups), at("header", 3)) && same(Model.clamp(at("known", 9, true), shown, groups), at("known", 1, true)), "kept on a row: the switch as it is, a row past the end the last")
    check(same(Model.clamp(at("discovered", 1, true), ["connected"], groups), at("connected", 0, true)) && same(Model.clamp(at("known", 1), [], groups), at("known", 0)), "a list gone, the first shown; none shown, row 0")
    check(same(Model.find(mouse.address, shown, groups, true), at("known", 1, true)) && Model.find(speaker.address, ["connected", "known"], groups, false) === null && Model.find("nowhere", shown, groups, false) === null, "a device found again where it is now")

    console.log("DONE")
    Qt.quit()
  }
}
