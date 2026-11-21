// stub: bin/nova-tray-quit nova-tray-quit
// warns: hyprland_focus_grab_v1
// warns: XDG_CURRENT_DESKTOP sucks
// warns: Failed to create wl_display
import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/bar/widgets/tray" as Tray

// A tray icon's menu card (TrayMenu), the real one, under a bar on a headless
// compositor, with a stand-in for the app's menu shaped like Steam's: games,
// then groups split by separators, the last entry the app's own Exit. Every
// entry it shows lies whole inside the card, or the card scrolls and says
// there is more: Steam's menu once came out cut, its Big Picture halved and
// its Exit Steam out of sight, under a card held to 420 pixels with the
// whole screen free below it. Entries that come after the card opened grow
// it, fewer shrink it, a menu taller than the screen scrolls with a sign at
// the end that has more, and so does a submenu. The card's own last row
// quits the app, by the name nova-tray-quit (a stub here) gives, and is not
// there when it refuses.
//
// Offscreen, with a floating window for the bar: on the runner's sway (too
// old an xdg-shell to reposition a popup) a card that changes size while
// open stops drawing, where Hyprland resizes it as the app's menu changes.
// BarPopup's focus grab says it has no Hyprland to grab with: the warnings
// above.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")

  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function same(got, want, what) {
    const ok = JSON.stringify(got) === JSON.stringify(want)
    check(ok, what + (ok ? "" : ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want)))
  }

  function finish() {
    console.log("DONE")
    Qt.quit()
  }

  // Waits for <done> to hold, then calls <then>; fails <what> after 5 s.
  function when(done, then, what) {
    waiter.done = done
    waiter.then = then
    waiter.what = what
    waiter.left = 100
    waiter.start()
  }

  Timer {
    id: waiter
    property var done: null
    property var then: null
    property string what: ""
    property int left: 0
    interval: 50
    repeat: true
    onTriggered: {
      if (done()) {
        stop()
        then()
      } else if (--left <= 0) {
        stop()
        test.check(false, what)
        test.finish()
      }
    }
  }

  // A moment for the compositor to place and size the card, then <then>.
  function settled(then) {
    settle.then = then
    settle.restart()
  }

  Timer {
    id: settle
    property var then: null
    interval: 400
    onTriggered: then()
  }

  FileView {
    id: quitAnswer
    path: test.home + "/tray-quit"
    printErrors: false
    blockWrites: true
  }

  FileView {
    id: calls
    path: test.home + "/stub-calls"
    printErrors: false
    blockLoading: true
  }

  // ----- the bar, the icon's place on it, and the card -----

  FloatingWindow {
    id: barWindow
    implicitWidth: 800
    implicitHeight: 30
    color: "black"

    Item {
      id: spot
      anchors.right: parent.right
      anchors.rightMargin: 300
      width: 30
      height: 30
    }
  }

  property QtObject fakeBar: QtObject {
    readonly property int thickness: 30
    property var popup: null
    function claimPopup(key, open) { popup = open ? key : null }
  }

  // What holds the card: the tray widget, whose close() the card calls.
  property Item host: Item {
    property var bar: test.fakeBar
    function close() { menu.open = false }
  }

  Tray.TrayMenu {
    id: menu
    widget: spot
    host: test.host
    ink: "black"
    face: "monospace"
    onChosen: menu.open = false
    // A submenu's entries are the stand-in's own.
    listerKind: Component {
      QtObject {
        property var menu: null
        readonly property var children: menu ? menu.subEntries : []
      }
    }
  }

  // ----- the app's menu, a stand-in -----

  Component {
    id: entryKind
    QtObject {
      property string text: ""
      property bool isSeparator: false
      property bool enabled: true
      property bool hasChildren: false
      property int buttonType: QsMenuButtonType.None
      property int checkState: Qt.Unchecked
      property string icon: ""
      property var subEntries: []
      property int chosen: 0
      function triggered() { chosen++ }
    }
  }

  function entry(text, more) {
    return entryKind.createObject(test, Object.assign({ text: text }, more || {}))
  }

  function line() {
    return entryKind.createObject(test, { isSeparator: true })
  }

  // Steam's, as on the owner's bar: five games, Store to Community, Friends
  // and Settings, Big Picture, and Exit Steam last.
  function steam() {
    return [entry("Assetto Corsa"), entry("Scrap Mechanic"), entry("Drift Legends 2"), entry("skate."),
      entry("Schedule I: Free Sample"), line(), entry("Store"), entry("Library"), entry("Community"), line(),
      entry("Friends"), entry("Settings"), line(), entry("Big Picture"), line(), entry("Exit Steam")]
  }

  // A menu of <count> entries, in groups of five.
  function many(count, name) {
    const out = []
    for (let i = 1; i <= count; i++) {
      out.push(entry((name || "Entry") + " " + i))
      if (i % 5 === 0 && i < count) out.push(line())
    }
    return out
  }

  // ----- what the card shows -----

  // Every Item under <item>, the window's content included, for which <keep> holds.
  function all(item, keep) {
    const below = item.contentItem ? [item.contentItem] : item.children
    let out = []
    for (const child of below) {
      if (keep(child)) out.push(child)
      out = out.concat(all(child, keep))
    }
    return out
  }

  function rows() {
    return all(menu, item => item.contentY !== undefined && item.flickableDirection !== undefined)[0]
  }

  // The app's entries shown, each { words, line, top, bottom } in the rows'
  // view, which is the part of the card they scroll in.
  function shown() {
    const view = rows()
    return all(view, item => item.modelData !== undefined && item.words !== undefined && item.visible)
      .map(item => {
        const at = item.mapToItem(view, 0, 0)
        return { words: item.words, line: item.line, top: at.y, bottom: at.y + item.height }
      })
  }

  function words() {
    return shown().filter(e => !e.line).map(e => e.words)
  }

  // The card's own last row: its words, or "" when there is none.
  function lastRow() {
    const found = all(menu, item => item.text !== undefined && item.visible && item.color !== undefined
      && /^(Quit|Hide from)/.test(String(item.text)))
    return found.length > 0 ? String(found[0].text) : ""
  }

  // Whether the sign of more with <glyph> is drawn, over the rows' view.
  function sign(glyph) {
    const view = rows()
    return all(menu, item => item.glyph === glyph && item.visible && item.height > 0).some(item => {
      const at = item.mapToItem(view, 0, 0)
      return at.y >= -0.5 && at.y + item.height <= view.height + 0.5
    })
  }

  // Every entry whole inside the view, or else the card scrolls and has the
  // sign up on the side where the cut ones are.
  function fits(what) {
    const view = rows()
    const cutBelow = shown().filter(e => e.bottom > view.height + 0.5).map(e => e.words || "(line)")
    const cutAbove = shown().filter(e => e.top < -0.5).map(e => e.words || "(line)")
    if (cutBelow.length === 0 && cutAbove.length === 0) {
      check(true, what + ": every entry lies whole inside the card")
      return
    }
    check(view.interactive === true, what + ": entries out of sight (" + cutBelow.concat(cutAbove).join(", ") + "), so the card scrolls")
    if (cutBelow.length > 0) check(menu.moreBelow === true && sign("\uf078"), what + ": and has a sign up that there is more below")
    if (cutAbove.length > 0) check(menu.moreAbove === true && sign("\uf077"), what + ": and has a sign up that there is more above")
  }

  // The room the screen leaves below the bar, as BarPopup counts it.
  function room() {
    return barWindow.screen.height - barWindow.height - 2 * 5
  }

  // ----- the steps -----

  Component.onCompleted: Qt.callLater(start)

  function start() {
    when(() => barWindow.visible && barWindow.screen !== null, steamMenu, "the bar is up")
  }

  function steamMenu() {
    quitAnswer.setText("Steam\n")
    menu.load({ id: "steam", title: "steam", menu: null })
    menu.entries = steam()
    menu.open = true
    settled(() => {
      same(words(), ["Assetto Corsa", "Scrap Mechanic", "Drift Legends 2", "skate.", "Schedule I: Free Sample",
        "Store", "Library", "Community", "Friends", "Settings", "Big Picture", "Exit Steam"],
        "Steam's menu: every entry it has, Exit Steam last")
      fits("Steam's menu")
      const view = rows()
      check(view.interactive === false, "Steam's menu fits the screen: the card does not scroll")
      check(menu.moreBelow === false && menu.moreAbove === false, "and says nothing of more")
      check(menu.height <= room(), "the card stays inside the screen's room")
      same(lastRow(), "Quit Steam", "the card's last row quits the app, by the name it is asked for")
      calls.reload()
      check(calls.text().indexOf("nova-tray-quit check steam steam") >= 0, "asked by the icon's id and title")
      grows()
    })
  }

  // Steam fills its menu after it opens: the card grows with it, and shrinks.
  function grows() {
    menu.open = false
    settled(() => {
      menu.load({ id: "steam", title: "Steam", menu: null })
      menu.entries = [entry("Store"), entry("Library")]
      menu.open = true
      settled(() => {
        const small = menu.height
        same(words(), ["Store", "Library"], "a menu that opens with two entries")
        menu.entries = steam()
        settled(() => {
          check(menu.height > small, "entries that come after it opened grow the card (" + small + " → " + menu.height + ")")
          fits("the menu filled after it opened")
          const full = menu.height
          menu.entries = [entry("Store"), line(), entry("Exit Steam")]
          settled(() => {
            check(menu.height < full, "fewer entries shrink it (" + full + " → " + menu.height + ")")
            fits("the menu emptied again")
            repeats()
          })
        })
      })
    })
  }

  // An entry that only repeats the app's name, a separator after it or at
  // either end, and two in a row, are left out; one between entries stays.
  function repeats() {
    menu.entries = [entry("Steam", { hasChildren: true, subEntries: [entry("Inside")] }), line(), entry("Show"), line(),
      line(), entry("Hide"), line()]
    settled(() => {
      same(words(), ["Show", "Hide"], "the entry that repeats the app's name is left out")
      same(shown().filter(e => e.line).length, 1, "one separator between Show and Hide, none at the ends, two in a row as one")
      menu.entries = [entry("Show"), line(), entry("Quit")]
      settled(() => {
        same(shown().map(e => e.line ? "—" : e.words), ["Show", "—", "Quit"], "a separator after a first entry that is shown stays")
        tall()
      })
    })
  }

  // One more than fits: a menu taller than the screen scrolls, says so, and
  // stops saying so once scrolled to its end.
  function tall() {
    const count = Math.ceil(room() / 30) + 1
    menu.entries = many(count)
    settled(() => {
      check(menu.height <= room(), "a menu taller than the screen: the card is held to the screen's room")
      check(rows().interactive === true, "and scrolls")
      check(menu.moreBelow === true && menu.moreAbove === false, "at its top it says there is more below, not above")
      fits("a menu one entry taller than the screen")
      same(lastRow(), "Quit Steam", "the card's own row stays in sight below the scrolling entries")
      rows().contentY = rows().contentHeight - rows().height
      settled(() => {
        check(menu.moreBelow === false && menu.moreAbove === true, "scrolled to the end it says there is more above")
        fits("the tall menu scrolled to its end")
        const last = shown()[shown().length - 1]
        same(last.words, "Entry " + count, "and its last entry is in sight")
        submenu()
      })
    })
  }

  // A submenu takes the card's place under its heading, and is held to the
  // same: whole inside, or scrolling and saying so.
  function submenu() {
    const deep = entry("Games", { hasChildren: true, subEntries: many(Math.ceil(room() / 30) + 3, "Game") })
    menu.entries = [entry("Store"), deep]
    settled(() => {
      menu.descend(deep, "Games")
      settled(() => {
        check(menu.here !== null && words()[0] === "Game 1", "the submenu shows from its first entry")
        check(menu.height <= room(), "a tall submenu: the card is held to the screen's room")
        fits("a tall submenu")
        same(lastRow(), "", "a submenu has no Quit row: it leads back out")
        menu.ascend()
        menu.entries = [entry("A"), entry("B")]
        settled(() => {
          fits("a short submenu's parent")
          refused()
        })
      })
    })
  }

  // An icon nova-tray-quit will not quit: no Quit row; one it will, quit
  // at once, and the card closes.
  function refused() {
    quitAnswer.setText("")
    menu.open = false
    settled(() => {
      // An empty name: quit by no name.
      menu.load({ id: "nm-applet", title: "Network", menu: null })
      menu.entries = [entry("Connect")]
      menu.open = true
      settled(() => {
        same(lastRow(), "Quit", "with no name given, the row says Quit")
        const before = menu.height
        menu.open = false
        quitAnswer.setText("!\n")
        settled(() => {
          menu.load({ id: "nm-applet", title: "Network", menu: null })
          menu.open = true
          settled(() => {
            same(lastRow(), "", "an icon nova-tray-quit refuses has no Quit row")
            check(menu.height < before, "and the card is the row shorter")
            quits()
          })
        })
      })
    })
  }

  function quits() {
    menu.open = false
    quitAnswer.setText("Steam\n")
    settled(() => {
      menu.load({ id: "steam", title: "Steam", menu: null })
      menu.entries = steam()
      menu.open = true
      settled(() => {
        menu.quit()
        check(menu.open === false, "Quit closes the card at once")
        when(() => { calls.reload(); return calls.text().indexOf("nova-tray-quit quit steam Steam") >= 0 },
          finish, "Quit runs nova-tray-quit quit with the icon's id and title")
      })
    })
  }
}
