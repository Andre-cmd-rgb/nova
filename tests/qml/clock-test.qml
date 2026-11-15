import QtQuick
import Quickshell
import "plugins/panels/clock/Model.js" as Model

// The clock's rules: the formats a right click walks, the ISO week, the
// shares of the year and of a life, the day weeks start on, and the month's
// grid. The answers are those of the rules as they were before their
// rewrite.
ShellRoot {
  function check(ok, what) {
    console.log((ok ? "ok   " : "FAIL ") + what)
  }

  function same(one, other) {
    return JSON.stringify(one) === JSON.stringify(other)
  }

  function gridText(grid) {
    return grid.map(w => w.week + ": " + w.days.map(d => [d.key, d.year, d.month, d.day, d.weekday, (d.inMonth ? "m" : "-") + (d.weekend ? "w" : "-") + (d.today ? "t" : "-")].join("/")).join(" ")).join("\n")
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(run)

  function run() {
    check(same(Model.formats(false), ["dddd HH:mm","dddd h:mm AP","HH:mm","h:mm AP","ddd d MMM HH:mm","ddd d MMM h:mm AP","d MMMM 'W'ww yyyy","yyyy-MM-dd HH:mm"]), "the formats a right click walks")
    check(same(Model.formats(true), ["HH\n—\nmm","h\n—\nmm\nAP","dd\nMMM\n'W'ww\n''yy","HH\nmm"]), "and on a side bar")
    check(same(Model.formatRing("HH:mm:ss", "d MMM", ["HH:mm", "h:mm AP"]), ["HH:mm","h:mm AP","d MMM","HH:mm:ss"]), "the walk: presets, then the alternate and the format")
    check(same(Model.formatRing("HH:mm", null, ["HH:mm", "", "h:mm AP", "HH:mm"]), ["HH:mm","h:mm AP"]), "each once, and nothing empty")
    check(same(Model.formatRing(undefined, "", []), ["HH:mm"]), "with nothing, HH:mm")
    check(same(Model.formatRing("a", "b", null), ["b","a"]), "with no presets")
    check(same(Model.nextFormat(["a", "b", "c"], "b"), "c"), "the next format")
    check(same(Model.nextFormat(["a", "b", "c"], "c"), "a"), "round from the last")
    check(same(Model.nextFormat(["a", "b"], "z"), "a"), "the first after one not in the walk")
    check(same(Model.nextFormat(["a", "b"], null), "a"), "and after none")
    check(same(Model.nextFormat([], "a"), ""), "no walk, no format")
    check(same(Model.withWeek("'W'ww yyyy", 2026, 0, 1), "'W'01 yyyy"), "the ISO week in a format")
    check(same(Model.withWeek("ww", 2026, 11, 31), "53"), "week 53")
    check(same(Model.withWeek("ww/ww", 2024, 11, 30), "01/01"), "week 1 in the year before")
    check(same(Model.withWeek("ww", 2026, 10, 15) + Model.withWeek("ww", 2026, 10, 16), "4647"), "a week from Monday")
    check(same(Model.keyOf(new Date(2026, 2, 5, 23, 59)), "2026-03-05"), "a day's key")
    check(same(Model.yearShare(2026, 0, 1), 0), "the year's share on 1 January")
    check(same(Model.yearShare(2026, 11, 31), 0.9972602739726028), "on 31 December")
    check(same(Model.yearShare(2028, 6, 1), 0.4972677595628415), "in a leap year")
    check(same([Model.percent(0.734), Model.percent(0.005), Model.percent(1)], [73,1,100]), "a percent")
    check(same(Model.monthCount(2026, 10), 24322), "months as one number")
    check(same(Model.monthAt(Model.monthCount(2026, 10) + 3), {"year":2027,"month":1}), "and back")
    check(same(Model.monthAt(Model.monthCount(2026, 0) - 1), {"year":2025,"month":11}), "back over a year")
    check(same(Model.birthYear(" 1990 ", 2026), 1990), "the year of birth")
    check(same([Model.birthYear("90", 2026), Model.birthYear("19900", 2026), Model.birthYear("199a", 2026), Model.birthYear(null, 2026)], [0,0,0,0]), "not four digits")
    check(same([Model.birthYear("2027", 2026), Model.birthYear("1906", 2026), Model.birthYear("1905", 2026), Model.birthYear("2026", 2026)], [0,1906,0,2026]), "not in the future nor over 120 years back")
    check(same(Model.birthYear("1990", "x"), 0), "with no year to count from")
    check(same([Model.age("1990", 2026), Model.age("", 2026), Model.age(1990, 2026.4)], [36,0,36]), "the age")
    check(same([Model.lifeSpan("80"), Model.lifeSpan(" 100 "), Model.lifeSpan(""), Model.lifeSpan("0"), Model.lifeSpan("151"), Model.lifeSpan("150"), Model.lifeSpan("8.5"), Model.lifeSpan(undefined)], [80,100,90,90,90,150,90,90]), "a life's span")
    check(same([Model.lifeShare("45", "90"), Model.lifeShare(45, ""), Model.lifeShare("0", "90"), Model.lifeShare("121", "200"), Model.lifeShare("100", "80"), Model.lifeShare("x", "90")], [0.5,0.5,0,0,1,0]), "the share lived")
    check(same([Model.weekStart(0, 1), Model.weekStart(8, 1), Model.weekStart(-1, 1), Model.weekStart(2.6, 1), Model.weekStart(NaN, 3)], [0,1,6,3,3]), "the week's start from a number")
    check(same([Model.weekStart("Sunday", 1), Model.weekStart(" sat ", 1), Model.weekStart("WED", 1), Model.weekStart("thursdays", 1), Model.weekStart("sund", 1)], [0,6,3,1,1]), "from a name")
    check(same([Model.weekStart("6", 1), Model.weekStart("13", 1), Model.weekStart("-2", 1), Model.weekStart("x", 1)], [6,6,5,1]), "from digits")
    check(same([Model.weekStart(null, 0), Model.weekStart("", 6), Model.weekStart(undefined, undefined), Model.weekStart("", "")], [0,6,1,1]), "else the locale's, else Monday")
    check(same([Model.weekStartName(0), Model.weekStartName("sat"), Model.weekStartName(null)], ["sunday","saturday","monday"]), "its word")
    check(same([Model.otherWeekStart(1), Model.otherWeekStart(0), Model.otherWeekStart(3), Model.otherWeekStart(null)], [0,1,1,0]), "the W heading's other start")
    check(same([Model.weekdayOrder(1), Model.weekdayOrder(0), Model.weekdayOrder("sat")], [[1,2,3,4,5,6,0],[0,1,2,3,4,5,6],[6,0,1,2,3,4,5]]), "the days from the start")
    check(same(gridText(Model.monthGrid(2026, 1, 1, "2026-02-14")), "5: 2026-01-26/2026/0/26/1/--- 2026-01-27/2026/0/27/2/--- 2026-01-28/2026/0/28/3/--- 2026-01-29/2026/0/29/4/--- 2026-01-30/2026/0/30/5/--- 2026-01-31/2026/0/31/6/-w- 2026-02-01/2026/1/1/0/mw-\n6: 2026-02-02/2026/1/2/1/m-- 2026-02-03/2026/1/3/2/m-- 2026-02-04/2026/1/4/3/m-- 2026-02-05/2026/1/5/4/m-- 2026-02-06/2026/1/6/5/m-- 2026-02-07/2026/1/7/6/mw- 2026-02-08/2026/1/8/0/mw-\n7: 2026-02-09/2026/1/9/1/m-- 2026-02-10/2026/1/10/2/m-- 2026-02-11/2026/1/11/3/m-- 2026-02-12/2026/1/12/4/m-- 2026-02-13/2026/1/13/5/m-- 2026-02-14/2026/1/14/6/mwt 2026-02-15/2026/1/15/0/mw-\n8: 2026-02-16/2026/1/16/1/m-- 2026-02-17/2026/1/17/2/m-- 2026-02-18/2026/1/18/3/m-- 2026-02-19/2026/1/19/4/m-- 2026-02-20/2026/1/20/5/m-- 2026-02-21/2026/1/21/6/mw- 2026-02-22/2026/1/22/0/mw-\n9: 2026-02-23/2026/1/23/1/m-- 2026-02-24/2026/1/24/2/m-- 2026-02-25/2026/1/25/3/m-- 2026-02-26/2026/1/26/4/m-- 2026-02-27/2026/1/27/5/m-- 2026-02-28/2026/1/28/6/mw- 2026-03-01/2026/2/1/0/-w-\n10: 2026-03-02/2026/2/2/1/--- 2026-03-03/2026/2/3/2/--- 2026-03-04/2026/2/4/3/--- 2026-03-05/2026/2/5/4/--- 2026-03-06/2026/2/6/5/--- 2026-03-07/2026/2/7/6/-w- 2026-03-08/2026/2/8/0/-w-"), "February from Monday")
    check(same(gridText(Model.monthGrid(2026, 10, 0, "")), "45: 2026-11-01/2026/10/1/0/mw- 2026-11-02/2026/10/2/1/m-- 2026-11-03/2026/10/3/2/m-- 2026-11-04/2026/10/4/3/m-- 2026-11-05/2026/10/5/4/m-- 2026-11-06/2026/10/6/5/m-- 2026-11-07/2026/10/7/6/mw-\n46: 2026-11-08/2026/10/8/0/mw- 2026-11-09/2026/10/9/1/m-- 2026-11-10/2026/10/10/2/m-- 2026-11-11/2026/10/11/3/m-- 2026-11-12/2026/10/12/4/m-- 2026-11-13/2026/10/13/5/m-- 2026-11-14/2026/10/14/6/mw-\n47: 2026-11-15/2026/10/15/0/mw- 2026-11-16/2026/10/16/1/m-- 2026-11-17/2026/10/17/2/m-- 2026-11-18/2026/10/18/3/m-- 2026-11-19/2026/10/19/4/m-- 2026-11-20/2026/10/20/5/m-- 2026-11-21/2026/10/21/6/mw-\n48: 2026-11-22/2026/10/22/0/mw- 2026-11-23/2026/10/23/1/m-- 2026-11-24/2026/10/24/2/m-- 2026-11-25/2026/10/25/3/m-- 2026-11-26/2026/10/26/4/m-- 2026-11-27/2026/10/27/5/m-- 2026-11-28/2026/10/28/6/mw-\n49: 2026-11-29/2026/10/29/0/mw- 2026-11-30/2026/10/30/1/m-- 2026-12-01/2026/11/1/2/--- 2026-12-02/2026/11/2/3/--- 2026-12-03/2026/11/3/4/--- 2026-12-04/2026/11/4/5/--- 2026-12-05/2026/11/5/6/-w-\n50: 2026-12-06/2026/11/6/0/-w- 2026-12-07/2026/11/7/1/--- 2026-12-08/2026/11/8/2/--- 2026-12-09/2026/11/9/3/--- 2026-12-10/2026/11/10/4/--- 2026-12-11/2026/11/11/5/--- 2026-12-12/2026/11/12/6/-w-"), "November from Sunday")
    check(same(gridText(Model.monthGrid(2026, 11, 6, "2027-01-01")), "49: 2026-11-28/2026/10/28/6/-w- 2026-11-29/2026/10/29/0/-w- 2026-11-30/2026/10/30/1/--- 2026-12-01/2026/11/1/2/m-- 2026-12-02/2026/11/2/3/m-- 2026-12-03/2026/11/3/4/m-- 2026-12-04/2026/11/4/5/m--\n50: 2026-12-05/2026/11/5/6/mw- 2026-12-06/2026/11/6/0/mw- 2026-12-07/2026/11/7/1/m-- 2026-12-08/2026/11/8/2/m-- 2026-12-09/2026/11/9/3/m-- 2026-12-10/2026/11/10/4/m-- 2026-12-11/2026/11/11/5/m--\n51: 2026-12-12/2026/11/12/6/mw- 2026-12-13/2026/11/13/0/mw- 2026-12-14/2026/11/14/1/m-- 2026-12-15/2026/11/15/2/m-- 2026-12-16/2026/11/16/3/m-- 2026-12-17/2026/11/17/4/m-- 2026-12-18/2026/11/18/5/m--\n52: 2026-12-19/2026/11/19/6/mw- 2026-12-20/2026/11/20/0/mw- 2026-12-21/2026/11/21/1/m-- 2026-12-22/2026/11/22/2/m-- 2026-12-23/2026/11/23/3/m-- 2026-12-24/2026/11/24/4/m-- 2026-12-25/2026/11/25/5/m--\n53: 2026-12-26/2026/11/26/6/mw- 2026-12-27/2026/11/27/0/mw- 2026-12-28/2026/11/28/1/m-- 2026-12-29/2026/11/29/2/m-- 2026-12-30/2026/11/30/3/m-- 2026-12-31/2026/11/31/4/m-- 2027-01-01/2027/0/1/5/--t\n1: 2027-01-02/2027/0/2/6/-w- 2027-01-03/2027/0/3/0/-w- 2027-01-04/2027/0/4/1/--- 2027-01-05/2027/0/5/2/--- 2027-01-06/2027/0/6/3/--- 2027-01-07/2027/0/7/4/--- 2027-01-08/2027/0/8/5/---"), "December into a week 53, from Saturday")
    check(same(gridText(Model.monthGrid(2027, 0, 1, null)), "53: 2026-12-28/2026/11/28/1/--- 2026-12-29/2026/11/29/2/--- 2026-12-30/2026/11/30/3/--- 2026-12-31/2026/11/31/4/--- 2027-01-01/2027/0/1/5/m-- 2027-01-02/2027/0/2/6/mw- 2027-01-03/2027/0/3/0/mw-\n1: 2027-01-04/2027/0/4/1/m-- 2027-01-05/2027/0/5/2/m-- 2027-01-06/2027/0/6/3/m-- 2027-01-07/2027/0/7/4/m-- 2027-01-08/2027/0/8/5/m-- 2027-01-09/2027/0/9/6/mw- 2027-01-10/2027/0/10/0/mw-\n2: 2027-01-11/2027/0/11/1/m-- 2027-01-12/2027/0/12/2/m-- 2027-01-13/2027/0/13/3/m-- 2027-01-14/2027/0/14/4/m-- 2027-01-15/2027/0/15/5/m-- 2027-01-16/2027/0/16/6/mw- 2027-01-17/2027/0/17/0/mw-\n3: 2027-01-18/2027/0/18/1/m-- 2027-01-19/2027/0/19/2/m-- 2027-01-20/2027/0/20/3/m-- 2027-01-21/2027/0/21/4/m-- 2027-01-22/2027/0/22/5/m-- 2027-01-23/2027/0/23/6/mw- 2027-01-24/2027/0/24/0/mw-\n4: 2027-01-25/2027/0/25/1/m-- 2027-01-26/2027/0/26/2/m-- 2027-01-27/2027/0/27/3/m-- 2027-01-28/2027/0/28/4/m-- 2027-01-29/2027/0/29/5/m-- 2027-01-30/2027/0/30/6/mw- 2027-01-31/2027/0/31/0/mw-\n5: 2027-02-01/2027/1/1/1/--- 2027-02-02/2027/1/2/2/--- 2027-02-03/2027/1/3/3/--- 2027-02-04/2027/1/4/4/--- 2027-02-05/2027/1/5/5/--- 2027-02-06/2027/1/6/6/-w- 2027-02-07/2027/1/7/0/-w-"), "January, its first week the year before's")
    check(same(gridText(Model.monthGrid(2026, 8, 1, "2026-09-06")), "36: 2026-08-31/2026/7/31/1/--- 2026-09-01/2026/8/1/2/m-- 2026-09-02/2026/8/2/3/m-- 2026-09-03/2026/8/3/4/m-- 2026-09-04/2026/8/4/5/m-- 2026-09-05/2026/8/5/6/mw- 2026-09-06/2026/8/6/0/mwt\n37: 2026-09-07/2026/8/7/1/m-- 2026-09-08/2026/8/8/2/m-- 2026-09-09/2026/8/9/3/m-- 2026-09-10/2026/8/10/4/m-- 2026-09-11/2026/8/11/5/m-- 2026-09-12/2026/8/12/6/mw- 2026-09-13/2026/8/13/0/mw-\n38: 2026-09-14/2026/8/14/1/m-- 2026-09-15/2026/8/15/2/m-- 2026-09-16/2026/8/16/3/m-- 2026-09-17/2026/8/17/4/m-- 2026-09-18/2026/8/18/5/m-- 2026-09-19/2026/8/19/6/mw- 2026-09-20/2026/8/20/0/mw-\n39: 2026-09-21/2026/8/21/1/m-- 2026-09-22/2026/8/22/2/m-- 2026-09-23/2026/8/23/3/m-- 2026-09-24/2026/8/24/4/m-- 2026-09-25/2026/8/25/5/m-- 2026-09-26/2026/8/26/6/mw- 2026-09-27/2026/8/27/0/mw-\n40: 2026-09-28/2026/8/28/1/m-- 2026-09-29/2026/8/29/2/m-- 2026-09-30/2026/8/30/3/m-- 2026-10-01/2026/9/1/4/--- 2026-10-02/2026/9/2/5/--- 2026-10-03/2026/9/3/6/-w- 2026-10-04/2026/9/4/0/-w-\n41: 2026-10-05/2026/9/5/1/--- 2026-10-06/2026/9/6/2/--- 2026-10-07/2026/9/7/3/--- 2026-10-08/2026/9/8/4/--- 2026-10-09/2026/9/9/5/--- 2026-10-10/2026/9/10/6/-w- 2026-10-11/2026/9/11/0/-w-"), "September in Chile's year")
    check(same(Object.keys(Model.monthGrid(2026, 0, 1, "")[0].days[0]), ["key", "year", "month", "day", "weekday", "inMonth", "weekend", "today"]), "a grid cell's fields")
    const noon = Model.noonOf("2026-03-29")
    check(noon.getFullYear() === 2026 && noon.getMonth() === 2 && noon.getDate() === 29 && noon.getHours() === 12, "a day by its key, at noon, on the day the clocks change")

    console.log("DONE")
    Qt.quit()
  }
}
