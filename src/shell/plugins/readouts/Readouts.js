.pragma library

// The arithmetic of the bar's CPU, Graphics and Memory readouts, apart from
// the service so that the tests reach it with text from /proc and sysfs.

// The first line of /proc/stat ("cpu  user nice system idle iowait irq
// softirq steal ...") as the time the processor was busy and the time that
// passed, both in the jiffies the kernel counts. Waiting for the disk
// (iowait) counts as idle time, not busy time. Guest time is left out of the
// sum because the kernel has already counted it in user time. Null for text
// that has no such line.
function parseCpu(text) {
  var line = String(text || "").split("\n", 1)[0]
  var fields = line.trim().split(/\s+/)
  if (fields[0] !== "cpu" || fields.length < 5) return null
  var n = fields.slice(1, 9).map(function (f) { return Number(f) || 0 })
  while (n.length < 8) n.push(0)
  var idle = n[3] + n[4]
  var total = n.reduce(function (sum, value) { return sum + value }, 0)
  return { busy: total - idle, total: total }
}

// How much of the time between two parseCpu samples the processor was busy,
// as a whole percentage; -1 while there is no earlier sample or no time has
// passed.
function cpuPercent(before, now) {
  if (!before || !now) return -1
  var total = now.total - before.total
  if (!(total > 0)) return -1
  return clamp(Math.round(100 * (now.busy - before.busy) / total))
}

// /proc/meminfo's MemTotal and MemAvailable, in kB; null when either is
// missing. MemAvailable, not MemFree: the cache the kernel gives back when
// a program asks is not memory in use.
function parseMemory(text) {
  var total = -1, available = -1
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.indexOf("MemTotal:") === 0) total = parseInt(line.slice(9), 10)
    else if (line.indexOf("MemAvailable:") === 0) available = parseInt(line.slice(13), 10)
    if (total >= 0 && available >= 0) break
  }
  if (!(total > 0) || !(available >= 0)) return null
  return { totalKb: total, usedKb: Math.max(0, total - available) }
}

// The share of memory in use as a whole percentage; -1 for no reading.
function memoryPercent(memory) {
  return memory ? clamp(Math.round(100 * memory.usedKb / memory.totalKb)) : -1
}

// Gigabytes, as the memory is sold (1 GB = 1024 MB), with one decimal below
// ten and none above: "7.4", "31".
function gigabytes(kb) {
  var gb = kb / 1048576
  return gb < 10 ? gb.toFixed(1) : String(Math.round(gb))
}

// "7.4 of 31 GB in use"; "" for no reading.
function memoryWords(memory) {
  if (!memory) return ""
  return gigabytes(memory.usedKb) + " of " + gigabytes(memory.totalKb) + " GB in use"
}

// ---- the graphics card ----------------------------------------------------

// The makers of the drivers whose busy share Nova reads (see bin/drm-cards).
var readable = { i915: "Intel", xe: "Intel", amdgpu: "AMD" }

// The maker of a card by its driver's name, for the tooltip; "" for one
// Nova does not know.
function maker(driver) {
  if (readable[driver]) return readable[driver]
  if (driver === "nvidia" || driver === "nouveau" || driver === "nova_core") return "NVIDIA"
  return ""
}

// The lines of bin/drm-cards as cards. A line is tab-separated: the card's
// name (card1), its driver, its runtime power state (active, suspended, or
// empty), "1" when it is the card the firmware started on, "1" when a
// screen is connected to it, "idle" or "busy", and the file to read. The
// last four are empty for a card that is not read.
function parseCards(text) {
  var cards = []
  String(text || "").split("\n").forEach(function (line) {
    var f = line.split("\t")
    if (f.length < 3 || f[0] === "") return
    cards.push({ name: f[0], driver: f[1], runtime: f[2], bootVga: f[3] === "1", connected: f[4] === "1",
      kind: f[5] || "", file: f[6] || "" })
  })
  return cards
}

// The card that draws the desktop: one whose driver Nova reads and that has
// a file to read, awake, with a screen connected to it; failing that, the
// one the firmware started on. Null when there is none, and the Graphics
// readout then says so.
function chooseCard(cards) {
  var usable = cards.filter(function (c) { return c.file !== "" && c.runtime !== "suspended" })
  var driving = usable.filter(function (c) { return c.connected })
  if (driving.length > 0) return driving[0]
  var first = usable.filter(function (c) { return c.bootVga })
  return first.length > 0 ? first[0] : null
}

// The cards that are not the chosen one, as the tooltip tells them.
function otherCards(cards, chosen) {
  return cards.filter(function (c) { return !chosen || c.name !== chosen.name }).map(function (c) {
    return { name: c.name, maker: maker(c.driver), off: c.runtime === "suspended" }
  })
}

// How busy a card was between two readings of its file. An "idle" file
// holds the milliseconds the card has slept in all, so over <elapsedMs> of
// the wall clock it was busy for the rest; a "busy" file holds the
// percentage itself. -1 while there is no earlier reading, or no time
// passed.
function gpuPercent(kind, before, now, elapsedMs) {
  if (kind === "busy") return isFinite(now) ? clamp(Math.round(now)) : -1
  if (!isFinite(before) || !isFinite(now) || !(elapsedMs > 0)) return -1
  return clamp(Math.round(100 - 100 * (now - before) / elapsedMs))
}

// The number in a sysfs file's text, NaN for none.
function number(text) {
  var value = parseInt(String(text || "").trim(), 10)
  return isNaN(value) ? NaN : value
}

// The tooltip of the Graphics readout: what is busy, and what the other
// cards are doing.
function graphicsWords(chosen, percent, others) {
  var lines = []
  if (chosen) {
    var name = maker(chosen.driver)
    lines.push((name !== "" ? name + " graphics" : "Graphics") + (percent >= 0 ? ": " + percent + "% in use" : ""))
  } else {
    lines.push("Graphics: no reading on this computer")
  }
  others.forEach(function (c) {
    lines.push((c.maker !== "" ? c.maker + " graphics card" : "Graphics card") + ": " + (c.off ? "off" : "on"))
  })
  return lines.join("\n")
}

function clamp(value) {
  return Math.max(0, Math.min(100, value))
}
