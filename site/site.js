// The site's few moving parts, each only where its page has it: the theme
// picker, the docs' search, the tabs, the copy buttons, the list of a page's
// headings following the reading, and the hero's sky. Every page reads and
// works without this; it adds to it.
"use strict"

const root = document.documentElement
const reduced = matchMedia("(prefers-reduced-motion: reduce)")
const base = document.body.dataset.root || ""

// ------------------------------------------------------------------ themes

// A theme is on <html data-theme>, put there before the page is drawn by a
// line in its <head>, from the one picked last; themes.css holds the colors.
const themeColor = document.querySelector('meta[name="theme-color"]')
const radios = () => document.querySelectorAll('[role="radio"][data-theme]')
const known = new Set(Array.from(document.querySelectorAll(".theme-list [data-theme]"), button => button.dataset.theme))
const current = () => known.has(root.dataset.theme) ? root.dataset.theme : "adaptive"
const listeners = []

function show(theme) {
  root.dataset.theme = theme
  for (const radio of radios()) {
    const on = radio.dataset.theme === theme
    radio.setAttribute("aria-checked", String(on))
    radio.tabIndex = on ? 0 : -1
  }
  for (const shot of document.querySelectorAll(".shot[data-theme]")) shot.setAttribute("aria-pressed", String(shot.dataset.theme === theme))
  for (const word of document.querySelectorAll(".t-theme")) word.textContent = theme
  const label = (document.querySelector(`.theme-list [data-theme="${theme}"]`) || {}).textContent
  for (const said of document.querySelectorAll(".theme-said")) {
    said.textContent = theme === "adaptive" ? "This page wears Nova's adaptive theme, taken from the picture above."
      : `This page wears ${(label || theme).trim()}, one of Nova's themes.`
  }
  if (themeColor) themeColor.content = getComputedStyle(root).getPropertyValue("--bg").trim()
  for (const listener of listeners) listener(theme)
}

// Picks a theme, kept for the next page and visit. With View Transitions, the
// new colors spread from what was clicked.
function pick(theme, from) {
  if (!known.has(theme)) return
  try { localStorage.setItem("nova-theme", theme) } catch (blocked) { }
  if (theme === current()) return show(theme)
  if (!document.startViewTransition || reduced.matches) return show(theme)
  const box = from && from.getBoundingClientRect()
  const transition = document.startViewTransition(() => show(theme))
  if (!box || !box.width) return
  const x = box.left + box.width / 2
  const y = box.top + box.height / 2
  const end = Math.hypot(Math.max(x, innerWidth - x), Math.max(y, innerHeight - y))
  transition.ready.then(() => root.animate(
    { clipPath: [`circle(0px at ${x}px ${y}px)`, `circle(${end}px at ${x}px ${y}px)`] },
    { duration: 520, easing: "cubic-bezier(.3,.7,.2,1)", pseudoElement: "::view-transition-new(root)" }
  )).catch(() => { })
}

show(current())
matchMedia("(prefers-color-scheme: light)").addEventListener("change", () => show(current()))

// A radio group: a click picks, and the arrows move along it and pick, as
// radio buttons do; Tab enters at the one picked.
document.addEventListener("click", event => {
  const radio = event.target.closest('[role="radio"][data-theme], .shot[data-theme]')
  if (radio) pick(radio.dataset.theme, radio)
})
document.addEventListener("keydown", event => {
  const radio = event.target.closest && event.target.closest('[role="radio"][data-theme]')
  if (!radio) return
  const group = Array.from(radio.parentElement.querySelectorAll('[role="radio"]'))
  const step = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 }[event.key]
  let next = null
  if (step) next = group[(group.indexOf(radio) + step + group.length) % group.length]
  else if (event.key === "Home") next = group[0]
  else if (event.key === "End") next = group[group.length - 1]
  if (!next) return
  event.preventDefault()
  next.focus()
  pick(next.dataset.theme, next)
})

// The header's picker opens below its button and closes on Escape, on a
// click elsewhere, or on a theme clicked.
const opener = document.querySelector(".theme-open")
const list = document.getElementById("theme-list")
if (opener && list) {
  const open = yes => {
    list.classList.toggle("open", yes)
    opener.setAttribute("aria-expanded", String(yes))
    if (yes) (list.querySelector('[aria-checked="true"]') || list.querySelector("button")).focus()
  }
  opener.addEventListener("click", () => open(!list.classList.contains("open")))
  list.addEventListener("click", event => { if (event.target.closest("button")) { open(false); opener.focus() } })
  list.addEventListener("keydown", event => {
    if (event.key === "Escape") { open(false); opener.focus() }
    if (event.key === "Enter") { event.preventDefault(); open(false); opener.focus() }
  })
  document.addEventListener("click", event => {
    if (list.classList.contains("open") && !event.target.closest(".theme-picker")) open(false)
  })
  list.addEventListener("focusout", event => {
    if (!list.contains(event.relatedTarget) && event.relatedTarget !== opener && event.relatedTarget) open(false)
  })
}

// ------------------------------------------------------------------ search

// The docs' search: "/" or Ctrl+K, or the header's link, which leads to the
// docs' index without this. The index, every section of every page, is
// fetched the first time.
const searchLink = document.querySelector(".search-open")
let dialog = null
let entries = null
let found = []
let lit = 0

const escape = text => text.replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c])
const pattern = term => term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
const marked = (text, terms) => {
  const wanted = terms.filter(term => term.length > 1).map(pattern)
  if (!wanted.length) return escape(text)
  return text.split(new RegExp("(" + wanted.join("|") + ")", "gi"))
    .map((part, i) => i % 2 ? `<mark>${escape(part)}</mark>` : escape(part)).join("")
}

// What the words find, best first: a heading with them before a page's
// title with them before a text with them; all of them, or none.
function search(query) {
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean)
  if (!terms.length || !entries) return []
  const scored = []
  for (const entry of entries) {
    const heading = entry.h.toLowerCase(), page = entry.p.toLowerCase(), text = entry.x.toLowerCase()
    let score = 0
    for (const term of terms) {
      const times = text.split(term).length - 1
      const s = (heading.includes(term) ? 12 + (new RegExp("(^|\\W)" + pattern(term)).test(heading) ? 6 : 0) : 0)
        + (page.includes(term) ? 4 : 0) + Math.min(times, 6)
      if (!s) { score = 0; break }
      score += s
    }
    // The docs' index only lists the pages: its sections go after theirs.
    if (score) scored.push({ entry, score: entry.u === "docs/" || entry.u.startsWith("docs/#") ? score / 3 : score })
  }
  return scored.sort((a, b) => b.score - a.score).slice(0, 24).map(({ entry }) => entry)
}

// A few words of the section around the first word searched.
function excerpt(text, terms) {
  const at = terms.length ? text.toLowerCase().indexOf(terms[0]) : -1
  const from = Math.max(0, at - 40)
  return (from > 0 ? "…" : "") + text.slice(from, from + 150)
}

function drawResults(query) {
  const results = dialog.querySelector("ul")
  const input = dialog.querySelector("input")
  const terms = query.toLowerCase().split(/\s+/).filter(Boolean)
  found = search(query)
  lit = 0
  results.innerHTML = ""
  if (!entries) {
    results.innerHTML = '<li class="none">Loading the index…</li>'
    return
  }
  if (!found.length) {
    if (query.trim()) results.innerHTML = `<li class="none">Nothing found for “${escape(query.trim())}”</li>`
    input.removeAttribute("aria-activedescendant")
    return
  }
  found.forEach((entry, i) => {
    const item = document.createElement("li")
    item.id = "found-" + i
    item.setAttribute("role", "option")
    item.innerHTML = `<a href="${escape(base + entry.u)}" tabindex="-1"><small>${escape(entry.p)}</small>${marked(entry.h, terms)}<span>${marked(excerpt(entry.x, terms), terms)}</span></a>`
    item.addEventListener("mousemove", () => light(i))
    results.append(item)
  })
  light(0)
}

function light(i) {
  const items = dialog.querySelectorAll("li[role=option]")
  if (!items.length) return
  lit = (i + items.length) % items.length
  items.forEach((item, n) => item.setAttribute("aria-selected", String(n === lit)))
  dialog.querySelector("input").setAttribute("aria-activedescendant", items[lit].id)
  items[lit].scrollIntoView({ block: "nearest" })
}

function openSearch() {
  if (!dialog) {
    dialog = document.createElement("dialog")
    dialog.className = "search"
    dialog.setAttribute("aria-label", "Search the documentation")
    dialog.innerHTML = '<form method="dialog" role="search"><input type="search" role="combobox" aria-expanded="true" aria-controls="found" aria-autocomplete="list" aria-label="Search the documentation" placeholder="Search the docs" autocomplete="off" spellcheck="false"><kbd>Esc</kbd></form>'
      + '<ul id="found" role="listbox" aria-label="Found"></ul><p class="keys fine">↑ ↓ move · Return opens · Esc closes</p>'
    document.body.append(dialog)
    const input = dialog.querySelector("input")
    input.addEventListener("input", () => drawResults(input.value))
    input.addEventListener("keydown", event => {
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault()
        light(lit + (event.key === "ArrowDown" ? 1 : -1))
      } else if (event.key === "Enter") {
        event.preventDefault()
        if (found[lit]) location.href = base + found[lit].u
      }
    })
    dialog.addEventListener("click", event => {
      if (event.target === dialog) dialog.close()
      const link = event.target.closest("a")
      if (link) dialog.close()
    })
  }
  dialog.showModal()
  const input = dialog.querySelector("input")
  input.select()
  if (!entries) {
    drawResults("")
    fetch(base + "docs/search-index.json")
      .then(response => response.json())
      .then(list => { entries = list; drawResults(input.value) })
      .catch(() => { dialog.querySelector("ul").innerHTML = '<li class="none">The index could not be loaded. The <a href="' + escape(base) + 'docs/">docs</a> are here.</li>' })
  } else {
    drawResults(input.value)
  }
}

if (searchLink) {
  searchLink.setAttribute("role", "button")
  searchLink.setAttribute("aria-haspopup", "dialog")
  searchLink.addEventListener("click", event => { event.preventDefault(); openSearch() })
  document.addEventListener("keydown", event => {
    const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName) || document.activeElement.isContentEditable
    if ((event.key === "k" || event.key === "K") && (event.ctrlKey || event.metaKey)) {
      event.preventDefault()
      openSearch()
    } else if (event.key === "/" && !typing && !event.ctrlKey && !event.metaKey && !event.altKey) {
      event.preventDefault()
      openSearch()
    }
  })
}

// -------------------------------------------------------------------- tabs

// A row of tabs over its panels: a click or the arrows choose one.
for (const tabs of document.querySelectorAll("[data-tabs]")) {
  const buttons = Array.from(tabs.querySelectorAll('[role="tab"]'))
  const choose = (chosen, focus) => {
    for (const button of buttons) {
      const on = button === chosen
      button.setAttribute("aria-selected", String(on))
      button.tabIndex = on ? 0 : -1
      document.getElementById(button.getAttribute("aria-controls")).hidden = !on
    }
    if (focus) chosen.focus()
  }
  choose(buttons.find(button => button.getAttribute("aria-selected") === "true") || buttons[0], false)
  tabs.addEventListener("click", event => {
    const button = event.target.closest('[role="tab"]')
    if (button) choose(button, false)
  })
  tabs.addEventListener("keydown", event => {
    const at = buttons.indexOf(event.target)
    if (at < 0) return
    const next = { ArrowRight: at + 1, ArrowLeft: at - 1, Home: 0, End: buttons.length - 1 }[event.key]
    if (next === undefined) return
    event.preventDefault()
    choose(buttons[(next + buttons.length) % buttons.length], true)
  })
}

// ------------------------------------------------------------ copy buttons

for (const pre of document.querySelectorAll("pre")) {
  const text = (pre.querySelector("code") || pre).textContent.replace(/\n$/, "")
  const button = document.createElement("button")
  button.type = "button"
  button.className = "copy-code"
  button.textContent = "Copy"
  button.addEventListener("click", () => {
    navigator.clipboard.writeText(text).then(() => {
      button.textContent = "Copied"
      button.classList.add("done")
      setTimeout(() => { button.textContent = "Copy"; button.classList.remove("done") }, 1600)
    }, () => { button.textContent = "Select and copy" })
  })
  pre.append(button)
}

// ------------------------------------------------- the headings followed

// The heading read now, lit in the list beside the page.
const tocLinks = Array.from(document.querySelectorAll(".toc a"))
if (tocLinks.length) {
  const targets = tocLinks.map(link => document.getElementById(decodeURIComponent(link.hash.slice(1))))
  let queued = false
  const follow = () => {
    queued = false
    let at = 0
    targets.forEach((target, i) => { if (target && target.getBoundingClientRect().top < 140) at = i })
    tocLinks.forEach((link, i) => link.classList.toggle("here", i === at))
  }
  addEventListener("scroll", () => { if (!queued) { queued = true; requestAnimationFrame(follow) } }, { passive: true })
  follow()
}

// --------------------------------------------------------------- the sky

// The hero's stars, in the theme's text and accent: they twinkle, and now
// and then one falls. Still with reduced motion, and drawn only on screen.
const sky = document.querySelector(".sky")
if (sky && sky.getContext) {
  const pen = sky.getContext("2d")
  let stars = [], ink = "#fff", glow = "#fff", falling = null, running = false, visible = true, width = 0, height = 0
  const colors = () => {
    const style = getComputedStyle(root)
    ink = style.getPropertyValue("--fg").trim() || ink
    glow = style.getPropertyValue("--accent").trim() || glow
  }
  const size = () => {
    const ratio = Math.min(devicePixelRatio || 1, 2)
    width = sky.clientWidth
    height = sky.clientHeight
    sky.width = Math.round(width * ratio)
    sky.height = Math.round(height * ratio)
    pen.setTransform(ratio, 0, 0, ratio, 0, 0)
    const count = Math.min(240, Math.round(width * height / 7000))
    let seed = 7
    const random = () => (seed = (seed * 16807) % 2147483647) / 2147483647
    stars = Array.from({ length: count }, () => ({
      x: random(), y: random() * random(), r: 0.4 + random() * 1.1,
      phase: random() * 6.3, speed: 0.4 + random() * 1.2, accent: random() < 0.1
    }))
  }
  const draw = time => {
    pen.clearRect(0, 0, width, height)
    const t = time / 1000
    for (const star of stars) {
      pen.globalAlpha = reduced.matches ? 0.55 : 0.2 + 0.6 * (0.5 + 0.5 * Math.sin(t * star.speed + star.phase))
      pen.fillStyle = star.accent ? glow : ink
      pen.beginPath()
      pen.arc(star.x * width, star.y * height, star.r, 0, 6.283)
      pen.fill()
    }
    if (!reduced.matches) {
      if (!falling && Math.random() < 0.004) falling = { x: Math.random() * width * 0.8, y: Math.random() * height * 0.3, born: t }
      if (falling) {
        const age = t - falling.born
        const x = falling.x + age * 420, y = falling.y + age * 170
        const gradient = pen.createLinearGradient(x - 90, y - 36, x, y)
        gradient.addColorStop(0, "transparent")
        gradient.addColorStop(1, glow)
        pen.globalAlpha = Math.max(0, 1 - age / 0.9)
        pen.strokeStyle = gradient
        pen.lineWidth = 1.5
        pen.beginPath()
        pen.moveTo(x - 90, y - 36)
        pen.lineTo(x, y)
        pen.stroke()
        if (age > 0.9) falling = null
      }
    }
    pen.globalAlpha = 1
  }
  const frame = time => {
    draw(time)
    if (running) requestAnimationFrame(frame)
  }
  const run = () => {
    const should = visible && !reduced.matches && !document.hidden
    if (should && !running) { running = true; requestAnimationFrame(frame) }
    if (!should) { running = false; draw(performance.now()) }
  }
  colors()
  new ResizeObserver(() => { size(); draw(performance.now()) }).observe(sky)
  new IntersectionObserver(([seen]) => { visible = seen.isIntersecting; run() }).observe(sky)
  document.addEventListener("visibilitychange", run)
  reduced.addEventListener("change", run)
  listeners.push(() => { colors(); if (!running) draw(performance.now()) })
}

window.NovaSite = { pick, current, onTheme: listener => listeners.push(listener) }
