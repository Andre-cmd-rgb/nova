// The landing page's Super+Space: Nova's menu run on its own code and
// entries (menu-model.js, which tools/build-site makes from MenuModel.js,
// Calculator.js and menu.jsonc), as on a laptop on battery, with Wi-Fi and
// Bluetooth. The keys are the menu's (src/shell/plugins/menu/Menu.qml).
// Nothing runs: a row taken says what Nova would do.
"use strict"

;(() => {
  const card = document.getElementById("menu-card")
  if (!card || typeof NovaMenu === "undefined" || typeof NovaCalculator === "undefined") return
  const input = document.getElementById("menu-input")
  const list = document.getElementById("menu-list")
  const empty = card.querySelector(".menu-empty")
  const closed = document.querySelector(".menu-closed")
  const said = closed.querySelector(".menu-said")
  const reopen = closed.querySelector(".menu-reopen")
  const escape = text => String(text).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c])
  const quote = text => "'" + String(text).replace(/'/g, "'\\''") + "'"

  // ------------------------------------------------------ the laptop it is

  // What this laptop lacks of what menu.jsonc's when: asks about: a modem,
  // the text recognition (tesseract-data-eng, an optional package), a
  // recording running, and the GPU switch of the one model that has it.
  const lacks = [/wwan/, /tesseract/, /gpu-screen-recorder/, /thinkpad-p1-gen4i/]

  // The apps a new install lists, in the menu's order (by name): the desktop
  // entries of the nova package's dependencies (packaging/nova/PKGBUILD) and
  // Nova's own, less those NoDisplay or data/defaults/launcher.hides hides
  // (AirDrop's is NoDisplay); Supernova, the browser an install has unless
  // Firefox was asked for, and VS Code, which an install online builds
  // (docs/install.md). Each entry's Name, GenericName (the line under it) and
  // Keywords, as its desktop file has them.
  const apps = [
    { id: "nova-app-store", name: "App Center", line: "Apps", keywords: ["install", "remove", "software", "store", "apps", "flathub", "flatpak", "package"] },
    { id: "btop", name: "btop++", line: "System Monitor", keywords: ["system", "process", "task"] },
    { id: "nova-calculator", name: "Calculator", line: "", keywords: ["calc", "calculate", "math", "sum", "convert", "units", "scientific"] },
    { id: "org.gnome.Nautilus", name: "Files", line: "", keywords: ["folder", "manager", "explore", "disk", "filesystem", "nautilus"] },
    { id: "foot", name: "Foot", line: "Terminal", keywords: ["shell", "prompt", "command", "commandline"] },
    { id: "org.gnome.Loupe", name: "Image Viewer", line: "", keywords: ["Picture", "Graphics", "Loupe"] },
    { id: "limine-snapper-restore", name: "Limine-snapper-restore", line: "", keywords: ["snapshot", "restore", "rollback", "recovery", "backup", "btrfs", "subvolume", "snapper", "limine", "boot", "bootloader"] },
    { id: "mpv", name: "mpv Media Player", line: "Multimedia player", keywords: ["mpv", "media", "player", "video", "audio", "tv"] },
    { id: "supernova", name: "Supernova", line: "Web Browser", keywords: ["web", "browser", "internet"] },
    { id: "com.microsoft.VSCode", name: "Visual Studio Code", line: "Text Editor", keywords: ["vscode"] }
  ]
  const library = {
    sortedEntries: () => apps.map(entry => ({ entry: Object.assign({ icon: "", keywords: [] }, entry) })),
    entrySubtext: entry => entry.line,
    entryName: entry => entry.name
  }
  // The two bash providers, as they print: the value set now, then the values.
  const powerModes = "power-saver\npower-saver\nbalanced\nperformance"
  const fonts = "Noto Sans Mono\nJetBrainsMono Nerd Font\nJetBrainsMono Nerd Font Mono\nJetBrainsMonoNL Nerd Font\nJetBrainsMonoNL Nerd Font Mono\nNoto Sans Mono"

  let catalog = NovaMenu.catalogOf(NovaMenu.readMenuFile(NovaMenuFile), new Map())
  catalog = NovaMenu.withApps(catalog, NovaMenu.appItems(library))
  for (const [menu, printed, set] of [["power", powerModes, "nova-power-profile set"], ["style.font", fonts, "nova-font-set"]]) {
    if (catalog.items.has(menu)) catalog = NovaMenu.withFilled(catalog, menu, NovaMenu.providerItems(menu, printed, "", value => set + " " + quote(value)))
  }
  const answers = NovaMenu.noAnswers()
  for (const item of catalog.items.values()) {
    if (item.when) answers.when.set(item.id, !lacks.some(lack => lack.test(item.when)))
    if (item.checked) answers.checked.set(item.id, false)
  }

  // ------------------------------------------------------------- the sums

  // qalc's answers to the conversions the page suggests, as it printed them
  // with Calculator.command()'s words (libqalculate 5); anything else is
  // worked out here, for + − × ÷ ^ % and brackets, and printed qalc's way.
  const recorded = new Map([
    ["5 km to -miles", "5 kilometers ≈ 3.106855961 mi"],
    ["72 °F to -°C", "72 °F ≈ 22.22222222 °C"],
    ["1 GB to -MiB", "1 gigabyte ≈ 953.6743164 MiB"],
    ["100 km/h to -mph", "100 kilometers/hour ≈ 62.13711922 mph"],
    ["180 lb to -kg", "180 pounds = 81.6466266 kg"],
    ["6 ft to -m", "6 feet = 1.8288 m"],
    ["1 inch to -cm", "1 inch = 2.54 cm"],
    ["1 h to -min", "1 hour = 60 min"],
    ["sqrt(2)", "sqrt(2) ≈ 1.414213562"]
  ])

  // An arithmetic expression's value, or null for one it cannot read.
  function evaluate(text) {
    const tokens = text.replace(/−/g, "-").replace(/×/g, "*").replace(/÷/g, "/").match(/\d*\.?\d+(?:e[-+]?\d+)?|[-+*/^%()]|\S/gi) || []
    let at = 0
    const peek = () => tokens[at]
    const sum = () => {
      let value = product()
      while (peek() === "+" || peek() === "-") value = tokens[at++] === "+" ? value + product() : value - product()
      return value
    }
    const product = () => {
      let value = unary()
      while (peek() === "*" || peek() === "/") value = tokens[at++] === "*" ? value * unary() : value / unary()
      return value
    }
    const unary = () => peek() === "-" ? (at++, -unary()) : peek() === "+" ? (at++, unary()) : power()
    const power = () => {
      const value = percent()
      return peek() === "^" ? (at++, Math.pow(value, unary())) : value
    }
    const percent = () => {
      let value = atom()
      while (peek() === "%") { at++; value /= 100 }
      return value
    }
    const atom = () => {
      const token = tokens[at++]
      if (token === "(") {
        const value = sum()
        if (tokens[at++] !== ")") throw new Error("bracket")
        return value
      }
      if (/^\d*\.?\d+(e[-+]?\d+)?$/i.test(token || "")) return parseFloat(token)
      throw new Error("token")
    }
    try {
      const value = sum()
      return at === tokens.length && Number.isFinite(value) ? value : null
    } catch (unreadable) {
      return null
    }
  }

  // A number as qalc prints it: whole ones in full, the rest to ten digits,
  // with qalc's minus and E.
  function printed(value) {
    let text
    if (Number.isInteger(value) && Math.abs(value) < 2 ** 53) text = String(value)
    else if (value !== 0 && (Math.abs(value) >= 1e15 || Math.abs(value) < 1e-6)) text = value.toPrecision(10).replace(/e\+?/, "E")
    else text = value.toPrecision(10)
    return text.replace(/-/g, "−")
  }

  function qalc(expression) {
    if (recorded.has(expression)) return recorded.get(expression)
    const value = evaluate(expression)
    return value === null ? "error: the page works out arithmetic only" : expression + " = " + printed(value)
  }

  let lastAnswer = null
  function answerFor(typed) {
    const expression = NovaCalculator.expression(typed)
    lastAnswer = expression ? NovaCalculator.answer(qalc(expression), expression) : null
    return lastAnswer
  }

  // ----------------------------------------------------------- the glyphs

  // The menu's glyphs are a Nerd Font's; these are drawn for the page.
  const icons = {
    grid: "M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z",
    camera: "M4 8h3l2-3h6l2 3h3v11H4zM12 16.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7z",
    toggle: "M8 7h8a5 5 0 0 1 0 10H8A5 5 0 0 1 8 7zM16 14.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5z",
    palette: "M12 3a9 9 0 1 0 0 18c1.1 0 1.6-.9 1.2-1.8-.5-1.1.3-2.2 1.5-2.2H17a4 4 0 0 0 4-4c0-5.5-4-10-9-10zM7.5 11h.01M10 7h.01M14.5 7h.01",
    bolt: "M13 3 5 14h6l-1 7 8-11h-6z",
    gear: "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9 7 7M17 17l2.1 2.1M4.9 19.1 7 17M17 7l2.1-2.1",
    bag: "M5 8h14l-1 12H6zM9 8V6a3 3 0 0 1 6 0v2",
    refresh: "M20 11A8 8 0 0 0 5.7 6.1L4 8M4 4v4h4M4 13a8 8 0 0 0 14.3 4.9L20 16M20 20v-4h-4",
    power: "M12 3v8M7 6.3a7 7 0 1 0 10 0",
    crop: "M4 8V4h4M16 4h4v4M20 16v4h-4M8 20H4v-4",
    record: "M12 20a8 8 0 1 0 0-16 8 8 0 0 0 0 16zM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z",
    stop: "M7 7h10v10H7z",
    mic: "M12 3a3 3 0 0 1 3 3v5a3 3 0 0 1-6 0V6a3 3 0 0 1 3-3zM6 11a6 6 0 0 0 12 0M12 17v4",
    text: "M5 6h14M12 6v13M9 19h6",
    drop: "M12 3c4 5 6 8 6 11a6 6 0 0 1-12 0c0-3 2-6 6-11z",
    smile: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM8.5 14a4.5 4.5 0 0 0 7 0M9 9.5h.01M15 9.5h.01",
    coffee: "M5 9h11v5a5 5 0 0 1-5 5h-1a5 5 0 0 1-5-5zM16 11h1.5a2.5 2.5 0 0 1 0 5H16M8 3v3M12 3v3",
    belloff: "M6 16v-5a6 6 0 0 1 10.3-4.2M18 11v5l2 2H6M10 20a2 2 0 0 0 4 0M4 4l16 16",
    bell: "M6 16v-5a6 6 0 0 1 12 0v5l2 2H4zM10 20a2 2 0 0 0 4 0",
    moon: "M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z",
    airdrop: "M12 13a1 1 0 1 0 0-2 1 1 0 0 0 0 2zM8.5 15.5a5 5 0 0 1 0-7M15.5 8.5a5 5 0 0 1 0 7M5.6 18.4a9 9 0 0 1 0-12.8M18.4 5.6a9 9 0 0 1 0 12.8",
    clock: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 7v5l3 2",
    bar: "M3 5h18v4H3zM3 13h18M3 17h12",
    gaps: "M4 4h7v16H4zM13 4h7v7h-7zM13 13h7v7h-7z",
    laptop: "M5 6h14v9H5zM3 18h18",
    touchpad: "M4 5h16v14H4zM4 15h16M12 15v4",
    chip: "M7 7h10v10H7zM10 3v4M14 3v4M10 17v4M14 17v4M3 10h4M3 14h4M17 10h4M17 14h4",
    image: "M4 5h16v14H4zM4 16l5-5 4 4 2-2 5 5M15.5 9.5h.01",
    font: "M5 19 11 5h2l6 14M7.5 14h9",
    wifi: "M2 9a15 15 0 0 1 20 0M5 12.5a10 10 0 0 1 14 0M8.5 16a5 5 0 0 1 7 0M12 19.5h.01",
    bluetooth: "M7 7l10 10-5 4V3l5 4L7 17",
    signal: "M5 19v-3M10 19v-7M15 19V8M20 19V4",
    speaker: "M4 9h4l5-4v14l-5-4H4zM16 9a4 4 0 0 1 0 6M19 6a8 8 0 0 1 0 12",
    display: "M3 5h18v11H3zM8 20h8M12 16v4",
    keyboard: "M3 7h18v10H3zM7 11h.01M11 11h.01M15 11h.01M7 14h10",
    printer: "M7 9V4h10v5M7 16H5V9h14v7h-2M7 13h10v7H7z",
    battery: "M3 8h15v8H3zM21 11v2M6 11v2",
    gauge: "M4 17a8 8 0 1 1 16 0M12 17l4-6",
    lock: "M6 11h12v9H6zM8.5 11V8a3.5 3.5 0 0 1 7 0v3",
    info: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 11v5M12 8h.01",
    key: "M8 15a4 4 0 1 1 3.5-6H21v3h-2v2h-3v-2h-4.5A4 4 0 0 1 8 15z",
    globe: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18",
    logout: "M10 4H5v16h5M14 8l4 4-4 4M18 12H9",
    restart: "M4 12a8 8 0 1 0 2.3-5.7L4 8.6M4 4v4.6h4.6",
    snow: "M12 3v18M4.2 7.5l15.6 9M4.2 16.5l15.6-9",
    lifebuoy: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM12 16a4 4 0 1 0 0-8 4 4 0 0 0 0 8zM5.6 5.6l3.6 3.6M14.8 14.8l3.6 3.6M18.4 5.6l-3.6 3.6M9.2 14.8l-3.6 3.6",
    spark: "M12 3v18M3 12h18M8 8l8 8M16 8l-8 8",
    check: "M5 12.5l4.5 4.5L19 7",
    calc: "M6 3h12v18H6zM9 7h6M9 12h.01M12 12h.01M15 12h.01M9 16h.01M12 16h.01M15 16h.01",
    dot: "M12 13a1 1 0 1 0 0-2 1 1 0 0 0 0 2z"
  }
  const iconOf = {
    apps: "grid", capture: "camera", toggle: "toggle", style: "palette", power: "bolt", settings: "gear", store: "bag", update: "refresh", system: "power",
    "capture.screenshot": "crop", "capture.screenrecord": "record", "capture.screenrecord.stop": "stop", "capture.screenrecord.desktop-audio": "speaker",
    "capture.screenrecord.microphone": "mic", "capture.text": "text", "capture.color": "drop", "capture.emoji": "smile",
    "toggle.caffeine": "coffee", "toggle.notifications": "belloff", "toggle.nightlight": "moon", "toggle.airdrop": "airdrop", "toggle.screentime": "clock",
    "toggle.bar": "bar", "toggle.window-gaps": "gaps", "toggle.laptop-display": "laptop", "toggle.touchpad": "touchpad", "toggle.discrete-gpu": "chip",
    "style.theme": "palette", "style.background": "image", "style.font": "font", "style.bar": "bar",
    "update.nova": "spark", "update.firmware": "chip", "update.restart": "restart", "update.restart.shell": "bar", "update.restart.audio": "speaker",
    "update.restart.wifi": "wifi", "update.restart.bluetooth": "bluetooth", "update.timezone": "globe", "update.password": "key",
    "system.lock": "lock", "system.suspend": "moon", "system.hibernate": "snow", "system.logout": "logout", "system.reboot": "restart",
    "system.recovery": "lifebuoy", "system.shutdown": "power",
    "settings.wifi": "wifi", "settings.bluetooth": "bluetooth", "settings.mobile-data": "signal", "settings.airdrop": "airdrop",
    "settings.notifications": "bell", "settings.sound": "speaker", "settings.displays": "display", "settings.keyboard": "keyboard",
    "settings.printers": "printer", "settings.battery": "battery", "settings.performance": "gauge", "settings.screentime": "clock",
    "settings.appearance": "palette", "settings.bar": "bar", "settings.lock": "lock", "settings.apps": "grid", "settings.updates": "refresh",
    "settings.about": "info", "settings.dictation": "mic"
  }
  // An entry's glyph: its own, or the nearest menu's above it.
  function icon(row) {
    if (row.kind === "answer") return icons.calc
    if (row.glyph === "✓") return icons.check
    for (let id = row.key; id; id = id.includes(".") ? id.slice(0, id.lastIndexOf(".")) : "") {
      if (iconOf[id]) return icons[iconOf[id]]
    }
    return icons.dot
  }

  // --------------------------------------------------------------- the menu

  const themes = () => Array.from(document.querySelectorAll(".theme-list [data-theme]"), button => ({ theme: button.dataset.theme, label: button.textContent.trim() }))
  let here = "root", walked = [], typed = "", cursor = 0, rows = [], choosing = false, typedBefore = ""

  function title() {
    if (choosing) return "Theme"
    const shown = catalog.items.get(here)
    return shown ? shown.title || shown.label : "Go"
  }

  // The rows: the theme picker's, what a search finds, or the menu shown,
  // with a sum's answer first in the root (Menu.qml's relist).
  function relist() {
    if (choosing) {
      const wanted = typed.trim().toLowerCase()
      rows = themes().filter(t => !wanted || t.label.toLowerCase().includes(wanted) || t.theme.includes(wanted))
        .map(t => ({ key: "theme." + t.theme, kind: "choice", glyph: "", label: t.label, line: "", command: "", section: "", theme: t.theme }))
    } else {
      rows = typed.trim() ? NovaMenu.searchRows(catalog, here, typed, answers) : NovaMenu.menuRows(catalog, here, answers, typed !== "")
      if (here === "root") rows = NovaMenu.answerRows(answerFor(typed)).concat(rows)
    }
    cursor = Math.max(0, Math.min(cursor, rows.length - 1))
    draw()
  }

  const size = { row: 46, tall: 56, gap: 4, divider: 17, peek: Math.round(46 * 0.55) }
  // The room for the rows, as MenuWindow.qml gives it: up to 70% of the
  // 1200-pixel screen of the pictures, at these rows' scale; once something
  // is typed or a menu walked into, no more than the rows the card had then
  // (its pin), so that a longer list scrolls, a row cut short at its foot.
  const screenRoom = Math.round(1200 * 0.7 * size.row / 50)
  let cap = -1, shown = 0
  const pin = () => { if (cap < 0) cap = shown }

  function draw() {
    input.placeholder = title() + "…"
    if (input.value !== typed) input.value = typed
    list.innerHTML = ""
    rows.forEach((row, i) => {
      const item = document.createElement("li")
      item.id = "menu-row-" + i
      item.setAttribute("role", "option")
      if (row.line) item.classList.add("tall")
      if (row.section && (i === 0 || rows[i - 1].section !== row.section)) item.classList.add("divided")
      const glyph = row.kind === "app"
        ? `<span class="app-icon" aria-hidden="true">${escape(row.label.charAt(0).toUpperCase())}</span>`
        : row.kind === "choice"
          ? `<span class="swatch theme-dot" aria-hidden="true" style="${escape(document.querySelector(`.theme-list [data-theme="${row.theme}"] .swatch`).getAttribute("style"))}"></span>`
          : `<svg class="glyph" viewBox="0 0 24 24" aria-hidden="true"><path d="${icon(row)}"/></svg>`
      item.innerHTML = glyph + `<span class="text"><span class="label">${escape(row.label)}</span>`
        + (row.line ? `<span class="line">${escape(row.line)}</span>` : "") + "</span>"
        + (row.kind === "menu" ? '<span class="chevron" aria-hidden="true">›</span>' : "")
      item.addEventListener("mousemove", () => { if (cursor !== i) { cursor = i; light() } })
      item.addEventListener("click", () => { cursor = i; take(i); input.focus({ preventScroll: true }) })
      list.append(item)
    })
    empty.hidden = rows.length > 0
    empty.textContent = typed ? `No matches for “${typed}”` : "Nothing here yet"
    list.hidden = rows.length === 0
    shown = rows.length ? NovaMenu.listHeight(rows, cap >= 0 ? Math.min(cap, screenRoom) : screenRoom, size) : size.row
    list.style.height = rows.length ? shown + "px" : ""
    light()
  }

  function light() {
    const items = list.children
    for (let i = 0; i < items.length; i++) items[i].setAttribute("aria-selected", String(i === cursor))
    if (items[cursor]) {
      input.setAttribute("aria-activedescendant", items[cursor].id)
      const item = items[cursor]
      if (item.offsetTop < list.scrollTop) list.scrollTop = item.offsetTop
      else if (item.offsetTop + item.offsetHeight > list.scrollTop + list.clientHeight) list.scrollTop = item.offsetTop + item.offsetHeight - list.clientHeight
    } else {
      input.removeAttribute("aria-activedescendant")
    }
  }

  // A row at a time wraps round the ends; a page stops at them.
  function move(step) {
    if (!rows.length) return
    cursor = Math.abs(step) === 1 ? (cursor + step + rows.length) % rows.length : Math.max(0, Math.min(rows.length - 1, cursor + step))
    light()
  }

  function filter(text) {
    pin()
    typed = text
    cursor = 0
    relist()
  }

  function go(id, remember) {
    pin()
    const into = catalog.items.has(id) ? id : "root"
    if (remember && into !== here) walked = walked.concat([here])
    here = into
    typed = ""
    cursor = 0
    relist()
  }

  // Back out of the theme picker to where it was opened from (the menu, or
  // what was typed), at its Theme row; out of a menu to the one before.
  function back() {
    if (choosing) {
      choosing = false
      typed = typedBefore
      cursor = 0
      relist()
      cursor = Math.max(0, rows.findIndex(row => /^nova-theme pick$/.test(row.command || "")))
      return light()
    }
    if (here === "root") return
    if (walked.length) {
      const before = walked[walked.length - 1]
      walked = walked.slice(0, -1)
      go(before, false)
    } else {
      const shown = catalog.items.get(here)
      go(shown && shown.parent ? shown.parent : "root", false)
    }
  }

  // Does what the row is for; what Nova would run is said instead.
  function take(index) {
    const row = rows[index]
    if (!row) return
    if (choosing) {
      if (window.NovaSite) window.NovaSite.pick(row.theme, card)
      return dismiss(`The theme picker set ${escape(row.label)}, as <code>nova theme set ${escape(row.theme)}</code> does, and this page with it.`)
    }
    if (row.kind === "menu") return go(row.key, true)
    if (row.kind === "answer") {
      const copied = lastAnswer ? lastAnswer.copy : row.label
      if (navigator.clipboard) navigator.clipboard.writeText(copied).catch(() => { })
      return dismiss(`Copied ${escape(copied)}, as Nova copies an answer.`)
    }
    if (row.kind === "app") return dismiss(`Nova would open ${escape(row.label)}.`)
    if (/^nova-theme pick$/.test(row.command)) return pickTheme()
    dismiss(`Nova would run <code>${escape(row.command)}</code>.`)
  }

  // Style › Theme runs the theme picker: here, a list of the site's themes.
  function pickTheme() {
    choosing = true
    typedBefore = typed
    typed = ""
    cursor = Math.max(0, themes().findIndex(t => t.theme === (window.NovaSite ? window.NovaSite.current() : "")))
    relist()
  }

  function dismiss(message) {
    const hadFocus = card.contains(document.activeElement)
    card.hidden = true
    closed.hidden = false
    said.innerHTML = message || "The menu closed."
    if (hadFocus) reopen.focus({ preventScroll: true })
  }

  function open(focus) {
    cap = -1
    choosing = false
    here = "root"
    walked = []
    typed = ""
    cursor = 0
    closed.hidden = true
    card.hidden = false
    relist()
    if (focus) input.focus({ preventScroll: true })
  }

  // Escape clears what is typed, or closes; Backspace and Left go back when
  // nothing is typed; Up, Down, Page Up and Page Down move; Return and Right
  // do what the row is for, Ctrl+Return opens a sum in the Calculator, and
  // Delete on an app asks to uninstall it.
  input.addEventListener("keydown", event => {
    const key = event.key
    const steps = { ArrowUp: -1, ArrowDown: 1, PageUp: -6, PageDown: 6 }
    const atEnd = input.selectionStart === input.value.length && input.selectionEnd === input.value.length
    let done = true
    if (key === "Escape") typed ? filter("") : dismiss()
    else if ((key === "Backspace" || key === "ArrowLeft") && !typed) back()
    else if (key in steps) move(steps[key])
    else if (key === "Enter" && (event.ctrlKey || event.metaKey)) {
      if (rows[cursor] && rows[cursor].kind === "answer") dismiss(`Nova would open ${escape(typed.trim())} in the Calculator, to go on with it there.`)
    } else if (key === "Enter" || (key === "ArrowRight" && atEnd)) take(cursor)
    else if (key === "Delete" && rows[cursor] && rows[cursor].kind === "app") dismiss(`Nova would ask whether to uninstall ${escape(rows[cursor].label)}.`)
    else done = false
    if (done) event.preventDefault()
  })
  input.addEventListener("input", () => filter(input.value))
  reopen.addEventListener("click", () => open(true))
  for (const word of document.querySelectorAll(".try-word")) {
    word.addEventListener("click", () => {
      open(false)
      filter(word.dataset.try)
      input.focus({ preventScroll: true })
    })
  }
  if (window.NovaSite) window.NovaSite.onTheme(() => { if (choosing && !card.hidden) relist() })

  open(false)
})()
