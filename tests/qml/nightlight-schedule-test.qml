// zone: Europe/London
import QtQuick
import Quickshell
import qs.Commons
import "plugins/services/nightlight/Schedule.js" as Schedule

// The night light's schedule: sunrise and sunset by the sunrise equation,
// against the almanac's minute (London at midsummer); none where the sun
// stays up or down; the last turn by the sun and at set hours, across
// midnight and the change of the clocks; and the warmth kept to its range.
// In London's time zone, which changes its clocks on 29 March 2026.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function clock(time) {
    return Qt.formatTime(new Date(time), "HH:mm")
  }

  // A turn as text: "on 21:21" or "off 04:43", or "none".
  function said(turn) {
    return turn ? (turn.on ? "on " : "off ") + Qt.formatDateTime(new Date(turn.since), "d HH:mm") : "none"
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    const london = [51.5074, -0.1278]
    const midsummer = Schedule.sun(new Date(2026, 5, 21, 9).getTime(), london[0], london[1])
    check(clock(midsummer.rise) === "04:43" && clock(midsummer.set) === "21:21", "London at midsummer: up at 04:43, down at 21:21, as the almanac has it: " + clock(midsummer.rise) + " " + clock(midsummer.set))
    const sameDay = Schedule.sun(new Date(2026, 5, 21, 23, 59).getTime(), london[0], london[1])
    check(sameDay.rise === midsummer.rise, "any time of the day gives that day's sun")
    const winter = Schedule.sun(new Date(2026, 11, 21).getTime(), london[0], london[1])
    const near = (time, hour, minute) => Math.abs(time - new Date(2026, 11, 21, hour, minute).getTime()) <= 120000
    check(near(winter.rise, 8, 4) && near(winter.set, 15, 53), "and at midwinter, within two minutes of 08:04 and 15:53: " + clock(winter.rise) + " " + clock(winter.set))
    check(Schedule.sun(new Date(2026, 11, 21).getTime(), 69.65, 18.96) === null && Schedule.sun(new Date(2026, 5, 21).getTime(), 69.65, 18.96) === null,
      "Tromsø: no sunrise at midwinter, no sunset at midsummer")

    check(said(Schedule.lastTurn(new Date(2026, 5, 21, 23).getTime(), london[0], london[1])) === "on 21 21:21", "after sunset: on since it")
    check(said(Schedule.lastTurn(new Date(2026, 5, 22, 2).getTime(), london[0], london[1])) === "on 21 21:21", "past midnight: still yesterday's sunset")
    check(said(Schedule.lastTurn(new Date(2026, 5, 22, 12).getTime(), london[0], london[1])) === "off 22 04:43", "by day: off since sunrise")
    check(Schedule.lastTurn(new Date(2026, 11, 21, 12).getTime(), 69.65, 18.96) === null, "no sun to go by: no turn")

    check(said(Util.lastTurn(new Date(2026, 10, 16, 23).getTime(), 22 * 60, 7 * 60)) === "on 16 22:00", "set hours across midnight: on at 22:00")
    check(said(Util.lastTurn(new Date(2026, 10, 17, 3).getTime(), 22 * 60, 7 * 60)) === "on 16 22:00", "still on at 03:00, since the evening before")
    check(said(Util.lastTurn(new Date(2026, 10, 17, 7).getTime(), 22 * 60, 7 * 60)) === "off 17 07:00", "off from 07:00 on the minute")
    check(said(Util.lastTurn(new Date(2026, 10, 17, 12).getTime(), 9 * 60, 17 * 60 + 30)) === "on 17 09:00", "hours within a day")
    check(Util.lastTurn(Date.now(), 600, 600) === null, "the same time twice is no hours")
    // The clocks go forward at 01:00 on 29 March: 01:30 is not on them. Qt
    // makes it 00:30, a browser 02:30; either way the turn is made, once.
    const spring = Util.lastTurn(new Date(2026, 2, 29, 3).getTime(), 90, 6 * 60)
    check(spring && spring.on && new Date(spring.since).getDate() === 29 && spring.since < new Date(2026, 2, 29, 3).getTime(),
      "a turn in the hour the clocks skip is still made that night: " + said(spring))

    // Looked up again, the weather's place a little west of the time zone's
    // city: the sunset some minutes later, the same turn.
    const evening = new Date(2026, 5, 21, 23).getTime()
    const there = Schedule.lastTurn(evening, london[0], london[1]), west = Schedule.lastTurn(evening, london[0], london[1] - 1.5)
    check(there.since !== west.since && Util.turnName(there) === Util.turnName(west) && Util.turnName(there) === "on 2026-06-21",
      "a turn kept by its day, which a sunset some minutes later is still: " + Util.turnName(west))
    check(Util.turnName(Util.lastTurn(new Date(2026, 10, 17, 3).getTime(), 22 * 60, 7 * 60)) === "on 2026-11-16" && Util.turnName(null) === "",
      "and an evening's turn by the evening's day, past midnight")

    check(Util.minutesOf("22:00", -1) === 1320 && Util.minutesOf("7:05", -1) === 425, "a time of day in minutes")
    check(Util.minutesOf("24:00", -1) === -1 && Util.minutesOf("", 5) === 5 && Util.minutesOf(undefined, 5) === 5, "and anything else is the default")

    check(Schedule.warmth(3400) === 3400 && Schedule.warmth("3000") === 3000, "a warmth in range")
    check(Schedule.warmth(6500) === 4000 && Schedule.warmth(1000) === 4000 && Schedule.warmth(undefined) === 4000, "and the night's for anything else")

    console.log("DONE")
    Qt.quit()
  }
}
