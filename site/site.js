// The theme picker: the page takes the theme's colors (style.css) and the
// picture shows the same windows in it.
const names = {
  "adaptive": "the adaptive theme",
  "tokyo-night": "Tokyo Night",
  "catppuccin-latte": "Catppuccin Latte",
  "gruvbox": "Gruvbox",
}
const shot = document.getElementById("theme-shot")
const buttons = document.querySelectorAll(".picker button")
const themeColor = document.querySelector('meta[name="theme-color"]')

// Fetched ahead, so a pick changes the picture at once.
for (const theme of Object.keys(names)) new Image().src = `images/corner-${theme}.jpg`

function pick(theme) {
  document.documentElement.dataset.theme = theme
  for (const button of buttons) button.setAttribute("aria-pressed", String(button.dataset.theme === theme))
  themeColor.content = getComputedStyle(document.documentElement).getPropertyValue("--bg").trim()
  shot.classList.add("swapping")
  const next = new Image()
  next.onload = () => {
    shot.src = next.src
    shot.alt = `A terminal and Settings in ${names[theme]}`
    shot.classList.remove("swapping")
  }
  next.src = `images/corner-${theme}.jpg`
}

for (const button of buttons) button.addEventListener("click", () => pick(button.dataset.theme))
