.pragma library

// The rules of Settings' Keyboard & Mouse page, apart from its QML: xkb's
// layouts by name, the chosen ones as they are added, moved and taken out,
// and the words for the switch and the pointer's speed.

// xkb's layouts and their variants, from its list of them (evdev.lst), each
// { value, name }: "de" or "de:nodeadkeys", and "German (no dead keys)", by
// name. The list has a section a kind, headed "! layout", "! variant" and so
// on, and a line an entry: a layout's code and its name, or a variant's code,
// its layout's and its name ("  nodeadkeys      de: German (no dead keys)").
function layouts(listing) {
  const found = []
  let section = ""
  for (const line of String(listing || "").split("\n")) {
    const heading = /^! (\S+)/.exec(line)
    if (heading) {
      section = heading[1]
      continue
    }
    const entry = section === "layout" ? /^\s+(\S+)\s+(.*\S)/.exec(line)
      : section === "variant" ? /^\s+(\S+)\s+(\S+):\s+(.*\S)/.exec(line)
      : null
    if (!entry) continue
    if (section === "layout") found.push({ value: entry[1], name: entry[2] })
    else found.push({ value: entry[2] + ":" + entry[1], name: entry[3] })
  }
  return found.sort((a, b) => a.name.localeCompare(b.name))
}

// <value>'s name among <known>, or the value itself where xkb has none.
function nameOf(known, value) {
  const entry = (known || []).find(k => k.value === value)
  return entry ? entry.name : String(value || "")
}

// The layouts of <known> that <typed> finds, by a word of their name or by
// their code, but those <chosen> already; every one for nothing typed.
function matching(known, typed, chosen) {
  const words = String(typed || "").toLowerCase().split(/\s+/).filter(w => w !== "")
  return (known || []).filter(k => {
    if ((chosen || []).indexOf(k.value) >= 0) return false
    const name = k.name.toLowerCase()
    const code = k.value.toLowerCase()
    return words.every(w => name.indexOf(w) >= 0 || code === w || code.startsWith(w + ":"))
  })
}

// <list> with its entry at <index> moved <step> places, or taken out with a
// step of 0; the list as it was where the entry cannot go.
function moved(list, index, step) {
  const next = (list || []).slice()
  if (index < 0 || index >= next.length) return next
  const entry = next.splice(index, 1)[0]
  if (step === 0) return next
  const to = index + step
  if (to < 0 || to > next.length) return list.slice()
  next.splice(to, 0, entry)
  return next
}

// <list> as Hyprland takes it (keyboard.lua's chosen): with a layout of
// <nonLatin> first, the US among them moved ahead of it, else a US put
// there; so that the page shows at once what it will have.
function ahead(list, nonLatin) {
  const next = (list || []).slice()
  if (next.length === 0 || (nonLatin || []).indexOf(next[0].split(":")[0]) < 0) return next
  const us = next.findIndex(value => value.split(":")[0] === "us")
  const first = us < 0 ? "us" : next.splice(us, 1)[0]
  return [first].concat(next)
}

// How many more layouts <list> takes, as ahead() has it: xkb takes four.
function room(list, nonLatin) {
  return 4 - ahead(list, nonLatin).length
}

// The keys that go to the next layout, as nova input names them. One set by
// hand in input.lua that is none of them is shown as such.
function switches(current) {
  const offered = [
    { value: "alts", label: "Left Alt + Right Alt" },
    { value: "alt-shift", label: "Alt+Shift" },
    { value: "ctrl-shift", label: "Ctrl+Shift" },
    { value: "none", label: "None" }
  ]
  return current === "other" ? offered.concat([{ value: "other", label: "Set in input.lua" }]) : offered
}

// The pointer's speed, -1 to 1, in words.
function speedText(speed) {
  const value = Math.round(Number(speed) * 10) / 10
  if (!value) return "Normal"
  return value < 0 ? "Slower" : "Faster"
}
