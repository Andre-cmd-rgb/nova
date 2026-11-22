import QtQuick
import Quickshell
import Quickshell.Io
import "Readouts.js" as Readouts

// What the bar's CPU, Graphics and Memory readouts show, read for all of
// them at once: how busy the processor and the graphics card are, and how
// much memory is in use.
//
// It is cheap by being idle. Each readout on a bar holds its part (hold,
// release), and nothing is read while none is held, or while the screen is
// locked or dark. Held, it reads /proc/stat, /proc/meminfo and the card's
// one file every two seconds, only the parts that are held, and a number
// that has not changed as a whole percentage is not set again, so nothing
// that draws it is told. A file is loaded the moment its part is first held
// (setting its path does that), which is the first reading of the measure,
// so the number comes after one tick and not two.
Item {
  id: root

  // Injected by the shell.
  property var shell: null

  // Where the files are, the tests' fake tree in place of the real one:
  // set here by the QML tests, and by NOVA_PROC and NOVA_SYS for the
  // pictures (tools/screenshots), which show no computer's own load.
  property string procRoot: Quickshell.env("NOVA_PROC") || "/proc"
  property string drmRoot: (Quickshell.env("NOVA_SYS") || "/sys") + "/class/drm"
  property int interval: 2000

  readonly property string probe: decodeURIComponent(String(Qt.resolvedUrl("bin/drm-cards")).replace(/^file:\/\//, ""))

  // How many readouts hold each part (one on each screen's bar counts).
  property int cpuHolds: 0
  property int memoryHolds: 0
  property int gpuHolds: 0
  readonly property bool wanted: cpuHolds + memoryHolds + gpuHolds > 0

  // The lock screen's service: nothing is read while the screen is locked
  // or switched off. Found when a readout first asks, by then it is there.
  property var lock: null
  readonly property bool paused: !!lock && (lock.locked === true || lock.darkened === true)
  readonly property bool sampling: wanted && !paused

  // The readings: whole percentages, -1 until there is one.
  property int cpu: -1
  property int memory: -1
  property int graphics: -1
  property int memoryUsedKb: 0
  property int memoryTotalKb: 0
  // The graphics card read, and what the other cards are doing.
  property var card: null
  property var otherCards: []

  // Said after each look at the cards, for a tooltip that waits for it.
  signal cardsRead()

  readonly property string memoryWords: Readouts.memoryWords(memoryTotalKb > 0 ? { usedKb: memoryUsedKb, totalKb: memoryTotalKb } : null)
  readonly property string graphicsWords: Readouts.graphicsWords(card, graphics, otherCards)

  property var cpuBefore: null
  property real gpuBefore: NaN
  property real gpuBeforeAt: 0

  function hold(part) {
    if (!lock && shell && typeof shell.serviceFor === "function") lock = shell.serviceFor("nova.lock")
    if (part === "cpu") cpuHolds++
    else if (part === "memory") memoryHolds++
    else if (part === "gpu") {
      if (gpuHolds++ === 0) refreshCards()
    }
  }

  function release(part) {
    if (part === "cpu" && cpuHolds > 0 && --cpuHolds === 0) { cpuBefore = null; cpu = -1 }
    else if (part === "memory" && memoryHolds > 0 && --memoryHolds === 0) memory = -1
    else if (part === "gpu" && gpuHolds > 0 && --gpuHolds === 0) { gpuBefore = NaN; graphics = -1 }
  }

  // Looks at the cards again: which one draws the desktop, and whether the
  // others are on. Not on a timer: at the first readout, and when a tooltip
  // is wanted.
  function refreshCards() {
    if (!cardsProc.running) cardsProc.running = true
  }

  // Reads what is held, once.
  function sample() {
    if (cpuHolds > 0) cpuFile.reload()
    if (memoryHolds > 0) memoryFile.reload()
    if (gpuHolds > 0 && card) gpuFile.reload()
  }

  // A reading set only when it differs, and a missing one (-1) not at all,
  // so the last number stands while there is nothing newer.
  function takeCpu(text) {
    const now = Readouts.parseCpu(text)
    const percent = Readouts.cpuPercent(cpuBefore, now)
    cpuBefore = now
    if (percent >= 0 && percent !== cpu) cpu = percent
  }

  function takeMemory(text) {
    const now = Readouts.parseMemory(text)
    if (!now) return
    const percent = Readouts.memoryPercent(now)
    if (percent !== memory) memory = percent
    if (now.usedKb !== memoryUsedKb) memoryUsedKb = now.usedKb
    if (now.totalKb !== memoryTotalKb) memoryTotalKb = now.totalKb
  }

  function takeGpu(text) {
    const now = Readouts.number(text)
    const at = Date.now()
    const percent = Readouts.gpuPercent(card ? card.kind : "", gpuBefore, now, at - gpuBeforeAt)
    gpuBefore = now
    gpuBeforeAt = at
    if (percent >= 0 && percent !== graphics) graphics = percent
  }

  function takeCards(text) {
    const cards = Readouts.parseCards(text)
    const chosen = Readouts.chooseCard(cards)
    if (!chosen !== !card || (chosen && chosen.file !== card.file)) {
      gpuBefore = NaN
      graphics = -1
      card = chosen
    }
    otherCards = Readouts.otherCards(cards, chosen)
    cardsRead()
  }

  // Stale readings are not carried over a pause: the first one after it
  // only starts a new measure.
  onSamplingChanged: {
    cpuBefore = null
    gpuBefore = NaN
  }

  Timer {
    interval: root.interval
    running: root.sampling
    repeat: true
    triggeredOnStart: true
    onTriggered: root.sample()
  }

  FileView {
    id: cpuFile
    path: root.cpuHolds > 0 ? root.procRoot + "/stat" : ""
    printErrors: false
    onLoaded: root.takeCpu(text())
  }

  FileView {
    id: memoryFile
    path: root.memoryHolds > 0 ? root.procRoot + "/meminfo" : ""
    printErrors: false
    onLoaded: root.takeMemory(text())
  }

  FileView {
    id: gpuFile
    path: root.gpuHolds > 0 && root.card ? root.card.file : ""
    printErrors: false
    onLoaded: root.takeGpu(text())
  }

  Process {
    id: cardsProc
    command: [root.probe, root.drmRoot]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.takeCards(text)
    }
  }
}
