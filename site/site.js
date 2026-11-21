// The site's theme: the page takes the theme's colors (style.css), and on the
// landing page the picture shows the same windows in it. The theme picked there
// is kept, for the docs' pages and the next visit: a line in each page's <head>
// puts it on <html> before anything is drawn, and this follows it with the rest.
const names = {
  "adaptive": "the adaptive theme",
  "tokyo-night": "Tokyo Night",
  "catppuccin-latte": "Catppuccin Latte",
  "gruvbox": "Gruvbox",
}
const root = document.documentElement
const shot = document.getElementById("theme-shot")
const buttons = document.querySelectorAll(".picker button")
const themeColor = document.querySelector('meta[name="theme-color"]')
const picture = theme => `images/corner-${theme}.jpg`
const alt = theme => `A terminal and Settings in ${names[theme]}`

function show(theme) {
  root.dataset.theme = theme
  for (const button of buttons) button.setAttribute("aria-pressed", String(button.dataset.theme === theme))
  themeColor.content = getComputedStyle(root).getPropertyValue("--bg").trim()
}

function pick(theme) {
  show(theme)
  try { localStorage.setItem("nova-theme", theme) } catch {}
  shot.classList.add("swapping")
  const next = new Image()
  next.onload = () => {
    shot.src = next.src
    shot.alt = alt(theme)
    shot.classList.remove("swapping")
  }
  next.src = picture(theme)
}

const kept = Object.hasOwn(names, root.dataset.theme) ? root.dataset.theme : "adaptive"
show(kept)
if (shot) {
  if (kept !== "adaptive") {
    shot.src = picture(kept)
    shot.alt = alt(kept)
  }
  // Fetched ahead, so a pick changes the picture at once.
  for (const theme of Object.keys(names)) new Image().src = picture(theme)
  for (const button of buttons) button.addEventListener("click", () => pick(button.dataset.theme))
}
