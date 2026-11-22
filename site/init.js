// Before the page is drawn: mark that scripts run, and put back the theme and
// the photo picked on an earlier visit. A file of the site's own, loaded
// without defer from each page's <head>, and not inline: a content-security
// policy of script-src 'self' takes it as it is.
document.documentElement.classList.add("js")
try {
  var t = localStorage.getItem("nova-theme")
  if (t) document.documentElement.dataset.theme = t
  var w = localStorage.getItem("nova-wallpaper")
  if (w) document.documentElement.dataset.wallpaper = w
} catch (e) {}
