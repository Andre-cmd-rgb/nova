import QtQuick
import Quickshell
import Quickshell.Io
import "plugins/readouts" as Readouts
import "plugins/readouts/Readouts.js" as R

// The bar's CPU, Graphics and Memory readouts: the arithmetic on /proc and
// sysfs text, which graphics card is read (bin/drm-cards on fake sysfs
// trees, in which the files a sleeping second card must not be read from
// are pipes that would hang the probe if it opened them), and the service
// against a fake /proc: it reads only while a readout holds a part, only
// the parts held, not while the screen is locked, and sets a number only
// when it changed.
ShellRoot {
  id: test

  readonly property string home: Quickshell.env("HOME")
  readonly property string probe: decodeURIComponent(String(Qt.resolvedUrl("plugins/readouts/bin/drm-cards")).replace(/^file:\/\//, ""))

  function check(ok, what) { console.log((ok ? "ok   " : "FAIL ") + what) }

  property int cpuChanges: 0
  property int graphicsChanges: 0

  Readouts.Service {
    id: service
    procRoot: test.home + "/proc"
    drmRoot: test.home + "/drm/p1"
    interval: 100
    onCpuChanged: test.cpuChanges++
    onGraphicsChanged: test.graphicsChanges++
  }

  QtObject {
    id: lock
    property bool locked: false
    property bool darkened: false
  }

  // Runs <then> once <condition> holds, failing after five seconds.
  function until(what, condition, then) {
    pollMaker.createObject(test, { what: what, condition: condition, then: then })
  }

  Component {
    id: pollMaker
    Timer {
      property string what
      property var condition
      property var then
      property int tries: 0
      interval: 50
      repeat: true
      running: true
      onTriggered: {
        if (condition()) { stop(); then(); destroy() }
        else if (++tries > 100) { test.check(false, "waited too long for " + what + " (cpu " + service.cpu + ", memory " + service.memory + ", graphics " + service.graphics + ", card " + (service.card && service.card.name) + ")"); stop(); console.log("DONE"); Qt.quit() }
      }
    }
  }

  // A shell script that writes <text> into <file> of the fake tree.
  function put(file, text) {
    return "mkdir -p \"$(dirname " + file + ")\"; printf '%s\\n' '" + text + "' >" + file + "\n"
  }

  readonly property string trees: "set -e\ncd '" + home + "'\nmkdir -p drm\n"
    // This computer: an NVIDIA card asleep (its connectors and a boot_vga
    // that must not be read are pipes) and the Intel card that draws.
    + "d=drm/p1; mkdir -p $d/card0/device/power $d/card1/gt/gt0 $d/card1/device/power $d/card1-eDP-1 $d/card1-DP-1 $d/card0-DP-5\n"
    + "ln -s /sys/bus/pci/drivers/nvidia $d/card0/device/driver; echo suspended >$d/card0/device/power/runtime_status\n"
    + "mkfifo $d/card0/device/boot_vga $d/card0-DP-5/status\n"
    + "ln -s /sys/bus/pci/drivers/i915 $d/card1/device/driver; echo active >$d/card1/device/power/runtime_status\n"
    + "echo 1 >$d/card1/device/boot_vga; echo connected >$d/card1-eDP-1/status; echo disconnected >$d/card1-DP-1/status\n"
    + "echo 1000 >$d/card1/gt/gt0/rc6_residency_ms\n"
    // An AMD laptop: the integrated card draws; the asleep discrete one is
    // not read from, its busy share least of all.
    + "d=drm/amd; mkdir -p $d/card0/device/power $d/card1/device/power $d/card0-DP-1 $d/card1-eDP-1\n"
    + "ln -s /sys/bus/pci/drivers/amdgpu $d/card0/device/driver; echo suspended >$d/card0/device/power/runtime_status\n"
    + "mkfifo $d/card0/device/gpu_busy_percent $d/card0/device/boot_vga $d/card0-DP-1/status\n"
    + "ln -s /sys/bus/pci/drivers/amdgpu $d/card1/device/driver; echo active >$d/card1/device/power/runtime_status\n"
    + "echo 1 >$d/card1/device/boot_vga; echo connected >$d/card1-eDP-1/status; echo 37 >$d/card1/device/gpu_busy_percent\n"
    // Intel xe, one card.
    + "d=drm/xe; mkdir -p $d/card0/device/tile0/gt0/gtidle $d/card0-eDP-1\n"
    + "ln -s /sys/bus/pci/drivers/xe $d/card0/device/driver; echo 5 >$d/card0/device/tile0/gt0/gtidle/idle_residency_ms; echo connected >$d/card0-eDP-1/status\n"
    // An older i915, and one whose screen is on a different card than the
    // firmware started on, and a card that drives nothing but started
    // the firmware's picture.
    + "d=drm/old; mkdir -p $d/card0/device $d/card0/power $d/card0-LVDS-1\n"
    + "ln -s /sys/bus/pci/drivers/i915 $d/card0/device/driver; echo 9 >$d/card0/power/rc6_residency_ms; echo connected >$d/card0-LVDS-1/status\n"
    + "d=drm/boot; mkdir -p $d/card0/device $d/card0/gt/gt0 $d/card0-HDMI-A-1\n"
    + "ln -s /sys/bus/pci/drivers/i915 $d/card0/device/driver; echo 1 >$d/card0/gt/gt0/rc6_residency_ms; echo 1 >$d/card0/device/boot_vga; echo disconnected >$d/card0-HDMI-A-1/status\n"
    + "d=drm/none; mkdir -p $d/card0/device; ln -s /sys/bus/pci/drivers/virtio_gpu $d/card0/device/driver\n"
    + "for t in p1 amd xe old boot none; do echo \"== $t\"; '" + probe + "' \"$PWD/drm/$t\"; done\n"
    // The fake /proc for the service.
    + "mkdir -p proc; printf 'cpu  100 0 100 800 0 0 0 0 0 0\\ncpu0 1 1 1 1\\n' >proc/stat\n"
    + "printf 'MemTotal:       32768000 kB\\nMemFree: 1 kB\\nMemAvailable:   24576000 kB\\n' >proc/meminfo\n"

  Process {
    id: build
    command: ["bash", "-c", test.trees]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        test.arithmetic()
        test.cards(String(text))
      }
    }
  }

  Process {
    id: edit
    property string script
    command: ["bash", "-c", "cd '" + test.home + "'; " + script]
    onExited: edited()
    signal edited()
  }

  function change(script, then) {
    edit.script = script
    edit.edited.connect(function once() { edit.edited.disconnect(once); then() })
    edit.running = true
  }

  Component.onCompleted: Qt.callLater(() => build.running = true)

  function arithmetic() {
    var a = R.parseCpu("cpu  100 0 100 800 0 0 0 0 0 0\ncpu0 1 1 1 1\n")
    check(a.busy === 200 && a.total === 1000, "CPU: busy is all but idle")
    var b = R.parseCpu("cpu  200 0 200 1000 0 0 0 0 0 0\n")
    check(R.cpuPercent(a, b) === 50, "CPU: half the time between two samples")
    var io = R.parseCpu("cpu  100 0 100 800 100 0 0 0\n")
    check(io.busy === 200 && io.total === 1100, "CPU: waiting for the disk is idle time")
    check(R.cpuPercent(io, R.parseCpu("cpu  100 0 100 800 400 0 0 0\n")) === 0, "CPU: a stretch of waiting is 0% busy")
    check(R.cpuPercent(a, a) === -1 && R.cpuPercent(null, a) === -1, "CPU: no time passed, or no first sample, is no reading")
    check(R.parseCpu("") === null && R.parseCpu("cpu0 1 2 3 4") === null && R.parseCpu("cpu 1 2") === null, "CPU: not /proc/stat is null")
    check(R.cpuPercent({ busy: 0, total: 0 }, { busy: 500, total: 400 }) === 100, "CPU: a figure past the total is held at 100")

    var m = R.parseMemory("MemTotal:       32768000 kB\nMemFree:  1 kB\nMemAvailable:   24576000 kB\n")
    check(m.totalKb === 32768000 && m.usedKb === 8192000, "memory: total less what is available")
    check(R.memoryPercent(m) === 25, "memory: a quarter in use")
    check(R.memoryWords(m) === "7.8 of 31 GB in use", "memory: in words (" + R.memoryWords(m) + ")")
    check(R.memoryWords({ usedKb: 12582912, totalKb: 33554432 }) === "12 of 32 GB in use", "memory: ten GB and over have no decimal")
    check(R.parseMemory("MemTotal: 5 kB\n") === null && R.parseMemory("") === null && R.memoryPercent(null) === -1, "memory: missing figures are no reading")

    check(R.gpuPercent("idle", 1000, 1500, 1000) === 50, "graphics: asleep for half the time is 50% busy")
    check(R.gpuPercent("idle", 1000, 1000, 2000) === 100 && R.gpuPercent("idle", 0, 5000, 2000) === 0, "graphics: never asleep is 100%, asleep throughout 0% (clamped)")
    check(R.gpuPercent("idle", NaN, 5, 2000) === -1 && R.gpuPercent("idle", 1, 5, 0) === -1, "graphics: no first reading is none")
    check(R.gpuPercent("busy", NaN, 37, 0) === 37 && R.gpuPercent("busy", NaN, 140, 0) === 100, "graphics: AMD's file is the share")
    check(R.number("12345\n") === 12345 && isNaN(R.number("")), "graphics: a number in a file")
  }

  function cards(output) {
    var by = {}
    var name = ""
    output.split("\n").forEach(line => {
      if (line.indexOf("== ") === 0) { name = line.slice(3); by[name] = "" }
      else if (name !== "") by[name] += line + "\n"
    })
    var home = test.home + "/drm/"
    var p1 = R.parseCards(by.p1)
    check(p1.length === 2, "cards: both of this computer's are listed")
    var chosen = R.chooseCard(p1)
    check(chosen && chosen.name === "card1" && chosen.file === home + "p1/card1/gt/gt0/rc6_residency_ms" && chosen.kind === "idle",
      "cards: the Intel card that has a screen, read by its rc6 file")
    check(p1[0].driver === "nvidia" && p1[0].runtime === "suspended" && p1[0].file === "" && !p1[0].connected,
      "cards: the asleep NVIDIA one is only named and found asleep")
    check(JSON.stringify(R.otherCards(p1, chosen)) === '[{"name":"card0","maker":"NVIDIA","off":true}]', "cards: the NVIDIA one is off")
    check(R.graphicsWords(chosen, 12, R.otherCards(p1, chosen)) === "Intel graphics: 12% in use\nNVIDIA graphics card: off", "cards: the tooltip's words")
    check(R.graphicsWords(null, -1, []) === "Graphics: no reading on this computer", "cards: no card, said so")

    var amd = R.chooseCard(R.parseCards(by.amd))
    check(amd && amd.name === "card1" && amd.kind === "busy" && amd.file === home + "amd/card1/device/gpu_busy_percent",
      "cards: the AMD card that draws; the asleep discrete one was never read")
    var xe = R.chooseCard(R.parseCards(by.xe))
    check(xe && xe.file === home + "xe/card0/device/tile0/gt0/gtidle/idle_residency_ms", "cards: Intel xe's idle file")
    var old = R.chooseCard(R.parseCards(by.old))
    check(old && old.file === home + "old/card0/power/rc6_residency_ms", "cards: an older i915's rc6 file")
    var boot = R.chooseCard(R.parseCards(by.boot))
    check(boot && boot.name === "card0", "cards: with no screen connected, the card the firmware started on")
    check(R.chooseCard(R.parseCards(by.none)) === null && R.chooseCard([]) === null, "cards: none to read is none")
    check(R.chooseCard([{ name: "card0", driver: "i915", runtime: "suspended", bootVga: true, connected: true, kind: "idle", file: "/x" }]) === null,
      "cards: one that sleeps is not the one drawing")

    service.card = null
    check(!service.sampling, "service: nothing held, nothing read")
    service.hold("cpu")
    service.hold("memory")
    service.hold("gpu")
    check(service.sampling, "service: held, it reads")
    until("the readings", () => service.cpu === -1 && service.memory === 25 && service.card !== null, afterFirst)
  }

  function afterFirst() {
    check(service.memory === 25 && service.memoryWords === "7.8 of 31 GB in use", "service: memory read")
    check(service.card.name === "card1" && service.otherCards.length === 1 && service.otherCards[0].off, "service: the card found, the other one off")
    // A second sample of /proc/stat and of the card's file, which has not
    // changed since: 50% busy, and the card busy all the time.
    change("printf 'cpu  200 0 200 1000 0 0 0 0 0 0\\n' >proc/stat",
      () => until("cpu and graphics", () => service.cpu === 50 && service.graphics === 100, afterSecond))
  }

  function afterSecond() {
    check(true, "service: the processor 50% and the graphics card 100% from two readings")
    var cpuNow = test.cpuChanges, gpuNow = test.graphicsChanges
    // Nothing new for the next few ticks: nothing set again.
    waitMs(600, () => {
      check(test.graphicsChanges === gpuNow, "service: a reading that did not change is not set again")
      service.lock = lock
      lock.locked = true
      check(!service.sampling, "service: locked, it does not read")
      change("printf 'cpu  1000 0 1000 1000 0 0 0 0 0 0\\n' >proc/stat; echo 99999999 >drm/p1/card1/gt/gt0/rc6_residency_ms", () => waitMs(500, afterLock))
    })
  }

  function afterLock() {
    check(service.cpu === 50 && service.graphics === 100, "service: nothing changed while it was locked")
    lock.locked = false
    check(service.sampling, "service: unlocked, it reads again")
    // The first reading after a pause only starts a measure; the card then
    // sleeps through a stretch, so the number is 0%.
    waitMs(400, () => change("echo 999999999999 >drm/p1/card1/gt/gt0/rc6_residency_ms", () =>
      until("graphics after the pause", () => service.graphics === 0, () => {
      check(true, "service: a card asleep throughout is 0% (clamped)")
      service.release("cpu")
      check(service.cpu === -1 && service.sampling, "service: a part released is gone, the others read on")
      service.release("memory")
      service.release("gpu")
      check(!service.sampling && service.graphics === -1, "service: all released, it stops")
      console.log("DONE")
      Qt.quit()
    })))
  }

  function waitMs(ms, then) {
    var left = ms
    pollMaker.createObject(test, { what: "time", condition: () => (left -= 50) <= 0, then: then })
  }
}
