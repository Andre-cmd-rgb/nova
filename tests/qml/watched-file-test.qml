// warns: failed: Unknown failure when opening file.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// WatchedFile follows its file through bursts of quick changes, the ways
// Nova's files change: replaced by a rename (nova-sessiond's), written in
// place (nova caffeine's), removed, and removed and made again, a few
// milliseconds apart or none, and a large write that takes a moment to read,
// for the next change to land in. After each burst it has the file as the
// last change left it, or no file. A plain FileView that reads again at
// each change was left on an old reading after 2 to 9 of these 50 bursts,
// in each of four runs: its reload() does nothing while a read is under way
// (Quickshell 0.3.2). A file removed between FileView's look and its open
// is warned of whatever printErrors says (the warning this test allows),
// and read again after.
ShellRoot {
  id: test

  readonly property string file: Quickshell.env("HOME") + "/watched"
  readonly property int bursts: 50
  property int burst: 0
  property int misses: 0
  property string seen: "<nothing read>"
  property string want: ""

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  WatchedFile {
    id: watched
    path: test.file
    onLoaded: test.seen = text()
    onLoadFailed: test.seen = ""
  }

  // A burst of 1 to 12 changes; prints what the file holds at its end.
  Process {
    id: changes
    command: ["bash", "-c", `
      f=$1 n=$2 count=$((RANDOM % 20 + 1))
      for ((i = 0; i < count; i++)); do
        case $((RANDOM % 6)) in
          0) printf 'r%s.%s\\n' "$n" "$i" >"$f.new" && mv -f "$f.new" "$f" ;;
          1) rm -f "$f" ;;
          2) printf 'w%s.%s\\n' "$n" "$i" >"$f" ;;
          3) rm -f "$f"; printf 'n%s.%s\\n' "$n" "$i" >"$f" ;;
          4) printf 'a%s.%s\\n' "$n" "$i" >>"$f" ;;
          5) { printf 'b%s.%s\\n' "$n" "$i"; head -c 1000000 /dev/zero | tr '\\0' b; } >"$f" ;;
        esac
        ((RANDOM % 6)) || sleep 0.00$((RANDOM % 9))
      done
      [[ ! -f $f ]] || cat "$f"`, "burst", test.file, String(test.burst)]
    stdout: StdioCollector { id: end; waitForEnd: true }
    onExited: {
      test.want = end.text
      settle.restart()
    }
  }

  // Long enough for a change's read and the one after it.
  Timer {
    id: settle
    interval: 500
    onTriggered: {
      if (test.seen !== test.want) {
        test.misses++
        console.log("burst " + test.burst + ": the file holds " + JSON.stringify(test.want.slice(0, 12)) + ", read " + JSON.stringify(test.seen.slice(0, 12)))
      }
      if (++test.burst < test.bursts) {
        changes.running = true
        return
      }
      test.check(test.misses === 0, "after each of " + test.bursts + " bursts of quick changes, the file as the last left it (" + test.misses + " not)")
      console.log("DONE")
      Qt.quit()
    }
  }

  // A turn later: Quickshell takes Qt.quit() only once the shell is up.
  Component.onCompleted: Qt.callLater(() => { changes.running = true })
}
