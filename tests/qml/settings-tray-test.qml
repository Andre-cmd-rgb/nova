import QtQuick
import Quickshell
import "plugins/settings" as Settings
import "plugins/settings/TrayIcons.js" as TrayIcons
import "plugins/bar/widgets/tray/TrayList.js" as TrayList

// Settings → Menu Bar's tray icons (TrayIconsView), with stand-in icons, as
// there is no bus here for the tray to list real ones: a row for each icon
// in the tray and each hidden one, by its app's name; a switch that hides a
// shown one (its name kept first, then its key hidden) and shows a hidden
// one again, each through `nova bar set nova.tray`. An icon's own menu ends
// with Quit, so this is where an icon is hidden. Two apps that share an Id
// (Electron's) have a row each, and the bar hides only the one hidden.
ShellRoot {
  id: test

  property Item stage: Item { width: 600 }
  property var ran: []

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function same(got, want, what) {
    const ok = JSON.stringify(got) === JSON.stringify(want)
    check(ok, what + (ok ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  // Every Item under <item> for which <keep> holds.
  function all(item, keep) {
    let out = []
    for (const child of item.children) {
      if (keep(child)) out.push(child)
      out = out.concat(all(child, keep))
    }
    return out
  }

  Component {
    id: made
    Settings.TrayIconsView {
      width: 600
      onCommand: (argv, changes) => test.ran = test.ran.concat([{ argv: argv, changes: changes }])
    }
  }

  Component.onCompleted: Qt.callLater(run)

  function run() {
    // What is kept: an id hidden once, a name in one line.
    same(TrayIcons.hide(["a"], "b"), ["a", "b"], "hiding one adds its id")
    same([TrayIcons.hide(["a"], "a"), TrayIcons.hide(undefined, "a"), TrayIcons.hide(["a"], "")], [["a"], ["a"], ["a"]],
      "once, and not for no id")
    same(TrayIcons.show(["a", "b"], "a"), ["b"], "showing one takes its id out")
    same(TrayIcons.named({ a: "A" }, "telegram", { title: " Telegram\n Desktop ", tooltipTitle: "T" }), { a: "A", telegram: "Telegram Desktop" },
      "a hidden icon keeps its app's name, in one line")
    same([TrayIcons.named(null, "x", { title: "", tooltipTitle: "Tip" }), TrayIcons.named(["no"], "x", {}), TrayIcons.named({}, "", { title: "A" })],
      [{ x: "Tip" }, {}, {}], "its tooltip's when it has no title; nothing for none")

    // The rows.
    const icons = [{ id: "steam", title: "Steam" }, { id: "telegram", title: "", tooltipTitle: "Telegram" },
      { id: "steam", title: "Steam" }, { id: "", title: "No id" }, { id: "quiet", title: "" }]
    same(TrayIcons.rows(icons, ["blueman", "telegram"], { blueman: "Bluetooth" }), [
      { id: "blueman", name: "Bluetooth", hidden: true, here: false },
      { id: "quiet", name: "quiet", hidden: false, here: true },
      { id: "steam", name: "Steam", hidden: false, here: true },
      { id: "telegram", name: "Telegram", hidden: true, here: true }],
      "each icon in the tray once and each hidden one, by name; one that says nothing by its id")

    // Electron's apps count the same Ids: Discord and Slack are two rows,
    // and hiding one hides it alone, whether the other runs or not.
    const discord = { id: "chrome_status_icon_1", title: "Discord" }
    const slack = { id: "chrome_status_icon_1", title: "Slack" }
    const chats = [discord, slack]
    same(TrayIcons.rows(chats, [], {}).map(row => [row.id, row.name]),
      [["chrome_status_icon_1\tDiscord", "Discord"], ["chrome_status_icon_1\tSlack", "Slack"]], "two apps, one Id: a row each")
    const away = TrayIcons.hide([], TrayIcons.rows([discord], [], {})[0].id)
    same(away, ["chrome_status_icon_1\tDiscord"], "hidden by its Id and Title, though it runs alone")
    same(TrayList.shown(chats, away).map(item => item.title), ["Slack"], "the bar leaves out Discord alone")
    same(TrayIcons.rows(chats, away, {}).map(row => [row.name, row.hidden]), [["Discord", true], ["Slack", false]],
      "and Settings shows it so")
    same(TrayIcons.rows([], away, {}), [{ id: "chrome_status_icon_1\tDiscord", name: "Discord", hidden: true, here: false }],
      "gone, it is listed by its title")
    // An Id kept alone, as earlier releases did, hides both; showing one
    // keeps the other hidden by its own key.
    same(TrayList.shown(chats, ["chrome_status_icon_1"]), [], "an Id alone hides every icon with it")
    same(TrayIcons.rows(chats, ["chrome_status_icon_1"], {}).map(row => row.hidden), [true, true], "both rows off")
    same(TrayIcons.show(["a", "chrome_status_icon_1"], "chrome_status_icon_1\tSlack", chats), ["a", "chrome_status_icon_1\tDiscord"],
      "Slack shown: Discord stays hidden")
    same(TrayIcons.show(["steam", "steam\tSteam", "b"], "steam", []), ["b"], "an Id shown with what else named it")
    // Any other Id is the icon whatever its title says.
    same(TrayList.shown([{ id: "telegram", title: "Telegram (3)" }], ["telegram"]), [], "a title that changes keeps it hidden")
    same(TrayIcons.itemOf(chats, "chrome_status_icon_1\tSlack"), slack, "a row's icon, by its key")
    const steams = [{ id: "steam", title: "Steam" }, { id: "steam", title: "Steam Beta" }]
    same(TrayIcons.rows(steams, [], {}).map(row => row.id), ["steam\tSteam", "steam\tSteam Beta"],
      "any Id two apps share, by its titles")

    // The view: switches on for the shown, off for the hidden.
    const view = made.createObject(test.stage, { items: icons, bar: { hiddenTray: ["blueman", "telegram"], hiddenTrayNames: { blueman: "Bluetooth" } } })
    check(view.visible, "the section shows while there is an icon to list")
    const toggles = () => all(view, item => item.label !== undefined && item.checked !== undefined && item.detail !== undefined)
    same(toggles().map(t => [t.label, t.checked, t.detail]), [["Bluetooth", false, "Not running"], ["quiet", true, ""],
      ["Steam", true, ""], ["Telegram", false, ""]], "a switch for each, on while it shows in the bar")

    toggles()[2].clicked()
    same(test.ran.map(r => r.argv), [
      ["nova", "bar", "set", "nova.tray", "names", '{"blueman":"Bluetooth","steam":"Steam"}', "--json"],
      ["nova", "bar", "set", "nova.tray", "hidden", '["blueman","telegram","steam"]', "--json"]],
      "Steam's switch turned off: its name kept, then its id hidden")
    same(test.ran.map(r => r.changes), [{ "bar.hiddenTrayNames": { blueman: "Bluetooth", steam: "Steam" } },
      { "bar.hiddenTray": ["blueman", "telegram", "steam"] }], "and Settings shows both at once")

    test.ran = []
    toggles()[0].clicked()
    same(test.ran.map(r => r.argv), [["nova", "bar", "set", "nova.tray", "hidden", '["telegram"]', "--json"]],
      "Bluetooth's turned on: it is no longer hidden, though its app is not running")

    const empty = made.createObject(test.stage, { items: [], bar: {} })
    check(!empty.visible, "with no icon and none hidden, there is no section")

    console.log("DONE")
    Qt.quit()
  }
}
