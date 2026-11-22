// The site's moving parts, each only where its page has it: the photos and
// themes of the landing page, the theme picker, the docs' search, the tabs,
// the copy buttons, what eases in as it comes into view, and the headings
// followed beside a doc. Every page reads and works without this; it adds to it.
"use strict"

const root = document.documentElement
const reduced = matchMedia("(prefers-reduced-motion: reduce)")
const lightScheme = matchMedia("(prefers-color-scheme: light)")
const base = document.body.dataset.root || ""

// ------------------------------------------------------- photos and themes

const themeColor = document.querySelector('meta[name="theme-color"]')
const radios = () => document.querySelectorAll('[role="radio"][data-theme]')
const known = new Set(Array.from(document.querySelectorAll(".theme-list [data-theme]"), button => button.dataset.theme))
const current = () => known.has(root.dataset.theme) ? root.dataset.theme : "adaptive"
const listeners = []

// The photos: links to Nova's desktop over each, made the buttons of a radio
// group. The first is the one the page opens on.
const walls = Array.from(document.querySelectorAll(".wall[data-wallpaper]"))
const wallOf = new Map(walls.map(wall => [wall.dataset.wallpaper, wall]))
const opening = walls.length ? walls[0].dataset.wallpaper : ""
const wallGroup = document.querySelector(".walls")
if (wallGroup) wallGroup.setAttribute("role", "radiogroup")
for (const wall of walls) wall.setAttribute("role", "radio")
const picked = () => wallOf.has(root.dataset.wallpaper) ? root.dataset.wallpaper : opening

// The theme pictures: links to the whole screenshot, made toggle buttons.
const shots = Array.from(document.querySelectorAll(".shot[data-for]"))
for (const shot of shots) shot.setAttribute("role", "button")
const shotOf = new Map(shots.map(shot => [shot.dataset.for, shot]))

// A picture shown in place of another: the next is loaded in a layer on top,
// and faded in once it has come. The layer is the <img> or <picture> given.
function fade(layer, src, { webp, alt } = {}) {
  if (!layer) return
  const box = layer.parentElement
  const now = box.querySelector(".layer.on") || layer
  const img = el => el.tagName === "IMG" ? el : el.querySelector("img")
  if (img(now).getAttribute("src") === src) return
  let next = Array.from(box.querySelectorAll(".layer")).find(el => el !== now)
  if (!next) {
    next = now.cloneNode(true)
    next.classList.remove("on")
    for (const el of [next, ...next.querySelectorAll("*")]) { el.removeAttribute("id"); el.removeAttribute("fetchpriority") }
  }
  // On top of the one it replaces, so that the two cross.
  box.append(next)
  const nextImg = img(next)
  const source = next.querySelector("source")
  if (source) { if (webp) source.srcset = webp; else source.remove() }
  nextImg.loading = "eager"
  nextImg.alt = ""
  const swap = () => {
    if (img(next).getAttribute("src") !== src) return
    next.classList.add("on")
    now.classList.remove("on")
    if (alt !== undefined) { nextImg.alt = alt; img(now).alt = "" }
  }
  nextImg.onload = swap
  nextImg.src = src
  if (nextImg.complete && nextImg.naturalWidth) swap()
}

// The palette of the photo picked, as `nova theme palette` gave it: the
// opening photo's light one where the visitor's system is light.
function paletteOf(wall) {
  const own = wall.dataset.wallpaper === opening && lightScheme.matches && wall.dataset.paletteLight
  return (own || wall.dataset.palette || "").split(" ")
}

// Nova's desktop over the photo: in the adaptive theme's light mode over the
// opening photo where the visitor's system is light, as the page then is.
// Its description says first what is open on it.
function desktopOf(wall) {
  const lit = wall.dataset.wallpaper === opening && lightScheme.matches && wall.dataset.light
  const scene = wall.dataset.scene.charAt(0).toLowerCase() + wall.dataset.scene.slice(1)
  const open = wall.dataset.open || "Nova's desktop"
  return {
    src: lit || wall.getAttribute("href"),
    alt: `${open.charAt(0).toUpperCase() + open.slice(1)}, on Nova's desktop in the adaptive theme${lit ? "'s light mode" : ""}, over a photo of ${scene}, with the bar along the top`
  }
}

const heroPhoto = document.querySelector(".hero-photo .layer")
const stageShot = document.querySelector(".stage-screen .layer")
const stageGlow = document.querySelector(".glow .layer")
const themeShot = document.getElementById("theme-shot")
const palettes = Array.from(document.querySelectorAll(".palette"))
// One list of swatches, filled from the photo picked.
const palette = palettes[0]
for (const extra of palettes.slice(1)) extra.remove()

function showWallpaper() {
  const wall = wallOf.get(picked())
  if (!wall) return
  const adaptive = current() === "adaptive"
  for (const each of walls) {
    const on = each === wall
    each.setAttribute("aria-checked", String(on && adaptive))
    each.tabIndex = on ? 0 : -1
  }
  const desktop = desktopOf(wall)
  fade(heroPhoto, wall.dataset.wallJpg, { webp: wall.dataset.wallWebp })
  fade(stageGlow, wall.dataset.thumb)
  fade(stageShot, desktop.src, { alt: desktop.alt })
  // The big picture of the themes follows, where it shows the adaptive theme.
  if (themeShown === "adaptive") showThemeShot("adaptive")
  if (palette) {
    const colors = paletteOf(wall)
    palette.querySelectorAll("li").forEach((item, i) => {
      if (!colors[i]) return
      item.style.setProperty("--c", colors[i])
      const value = item.querySelector("code")
      if (value) value.textContent = colors[i]
    })
  }
  for (const said of document.querySelectorAll(".wall-said")) said.textContent = wall.dataset.label
}

// The big picture of the themes: Nova in the theme picked, where there is one
// (the adaptive theme over the photo picked); else it stays as it is.
let themeShown = ""
function showThemeShot(theme) {
  const shot = shotOf.get(theme)
  if (!shot || !themeShot) return
  themeShown = theme
  for (const each of shots) each.setAttribute("aria-pressed", String(each === shot))
  const wall = theme === "adaptive" && wallOf.get(picked())
  const desktop = wall ? desktopOf(wall) : {
    src: shot.getAttribute("href"),
    alt: `Nova in the ${shot.dataset.label} theme: a terminal and Settings at Appearance over a photo, with the bar along the top`
  }
  fade(themeShot, desktop.src, { alt: desktop.alt })
  for (const said of document.querySelectorAll(".shot-said")) said.textContent = shot.dataset.label
}

function show(theme) {
  root.dataset.theme = theme
  for (const radio of radios()) {
    const on = radio.dataset.theme === theme
    radio.setAttribute("aria-checked", String(on))
    radio.tabIndex = on ? 0 : -1
  }
  const label = (document.querySelector(`.theme-list [data-theme="${theme}"]`) || {}).textContent || theme
  for (const said of document.querySelectorAll(".theme-said")) {
    said.textContent = theme === "adaptive"
      ? "Nova's adaptive theme takes its colors from your background, for the bar, the terminal and the apps at once. This page wears it too."
      : `This page wears ${label.trim()}, one of Nova's fixed themes. A photo puts it back in the adaptive theme.`
  }
  showWallpaper()
  if (themeColor) themeColor.content = getComputedStyle(root).getPropertyValue("--bg").trim() || themeColor.content
  for (const listener of listeners) listener(theme)
}

// The new colors spread from what was clicked, where the browser can.
function spread(from, change) {
  if (!document.startViewTransition || reduced.matches) return change()
  const box = from && from.getBoundingClientRect()
  const transition = document.startViewTransition(change)
  if (!box || !box.width) return
  const x = box.left + box.width / 2, y = box.top + box.height / 2
  const end = Math.hypot(Math.max(x, innerWidth - x), Math.max(y, innerHeight - y))
  transition.ready.then(() => root.animate(
    { clipPath: [`circle(0px at ${x}px ${y}px)`, `circle(${end}px at ${x}px ${y}px)`] },
    { duration: 620, easing: "cubic-bezier(.3,.7,.2,1)", pseudoElement: "::view-transition-new(root)" }
  )).catch(() => { })
}

// A theme picked, kept for the next page and visit. A fixed theme leaves the
// photo where it is: the adaptive theme picked again takes its colors again.
function pick(theme, from) {
  if (!known.has(theme)) return
  try { localStorage.setItem("nova-theme", theme) } catch (blocked) { }
  showThemeShot(theme)
  if (theme === current()) return show(theme)
  spread(from, () => show(theme))
}

// A photo picked: Nova over it, in the adaptive theme, and the page in its
// colors.
function pickWallpaper(name, from) {
  if (!wallOf.has(name)) return
  try {
    localStorage.setItem("nova-theme", "adaptive")
    localStorage.setItem("nova-wallpaper", name)
  } catch (blocked) { }
  if (current() === "adaptive" && picked() === name) return show("adaptive")
  spread(from, () => { root.dataset.wallpaper = name; show("adaptive") })
}

show(current())
for (const shot of shots) {
  const on = !!themeShot && shot.getAttribute("href") === themeShot.getAttribute("src")
  shot.setAttribute("aria-pressed", String(on))
  if (on) themeShown = shot.dataset.for
}
if (current() !== "adaptive") showThemeShot(current())
lightScheme.addEventListener("change", () => show(current()))

// A photo or a theme chosen, by a click or from the keyboard.
function choose(el) {
  if (el.matches(".wall[data-wallpaper]")) return pickWallpaper(el.dataset.wallpaper, el)
  if (el.dataset.theme) return pick(el.dataset.theme, el)
}

document.addEventListener("click", event => {
  const wall = event.target.closest(".wall[data-wallpaper]")
  if (wall) { event.preventDefault(); return choose(wall) }
  const shot = event.target.closest(".shot[data-for]")
  if (shot) { event.preventDefault(); return pick(shot.dataset.for, shot) }
  const radio = event.target.closest('[role="radio"][data-theme]')
  if (radio) choose(radio)
})

// The arrows move along a group of radios, as in any radio group, choosing
// as they go (with no click, which in the header's picker would close it);
// Space and Return pick a photo or a theme picture, as on a button.
document.addEventListener("keydown", event => {
  const target = event.target.closest ? event.target : null
  if (!target) return
  const toggle = target.closest(".wall[data-wallpaper], .shot[data-for]")
  if (toggle && (event.key === " " || event.key === "Enter")) {
    event.preventDefault()
    return toggle.click()
  }
  const radio = target.closest('[role="radio"]')
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
  choose(next)
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

// On the landing page the header stands on the photo until the page moves.
if (document.body.classList.contains("landing")) {
  let queued = false
  const mark = () => { queued = false; root.classList.toggle("scrolled", scrollY > 24) }
  addEventListener("scroll", () => { if (!queued) { queued = true; requestAnimationFrame(mark) } }, { passive: true })
  mark()
}

// -------------------------------------------- what eases in as it comes in

const reveals = Array.from(document.querySelectorAll(".reveal"))
if (reveals.length && !reduced.matches && typeof IntersectionObserver !== "undefined") {
  const io = new IntersectionObserver(entries => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue
      entry.target.classList.remove("reveal-wait")
      io.unobserve(entry.target)
    }
  }, { rootMargin: "0px 0px -6% 0px" })
  for (const el of reveals) {
    if (el.getBoundingClientRect().top > innerHeight) {
      el.classList.add("reveal-wait")
      io.observe(el)
    }
  }
  // A jump to an anchor shows what it lands on at once.
  addEventListener("hashchange", () => {
    for (const el of reveals) if (el.getBoundingClientRect().top < innerHeight) el.classList.remove("reveal-wait")
  })
}

// ------------------------------------------------------------------ search

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
    if (score) scored.push({ entry, score: entry.u === "docs/" || entry.u.startsWith("docs/#") ? score / 3 : score })
  }
  return scored.sort((a, b) => b.score - a.score).slice(0, 24).map(({ entry }) => entry)
}

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

window.NovaSite = { pick, pickWallpaper, current, onTheme: listener => listeners.push(listener) }
