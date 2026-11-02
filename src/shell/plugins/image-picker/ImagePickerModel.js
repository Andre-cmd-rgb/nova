// The image picker's list: the images a request brings, what each is called,
// and which of them a filter keeps.

// "/w/tokyo-night.png" is named "tokyo-night" and captioned "Tokyo Night".
function nameOf(path) {
  return String(path || "").split("/").pop().replace(/\.[^/.]+$/, "")
}

function captionOf(path) {
  return nameOf(path).replace(/[-_]+/g, " ").replace(/\b\w/g, function (letter) { return letter.toUpperCase() })
}

// The images in <text>, a line each: the image's path and, after a tab, its
// thumbnail's, or the image's own path for one without. Of images with the
// same file name, in two folders, the first is kept. Each carries its caption,
// and its name and caption lower-cased for the filter.
function parse(text) {
  var images = []
  var seen = {}
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var columns = lines[i].split("\t")
    var path = columns[0]
    if (!path) continue
    var fileName = path.split("/").pop()
    if (seen[fileName] === true) continue
    seen[fileName] = true
    var caption = captionOf(path)
    images.push({
      path: path,
      thumbnail: columns[1] || path,
      caption: caption,
      name: nameOf(path).toLowerCase(),
      words: caption.toLowerCase()
    })
  }
  return images
}

// Whether <filter> keeps <image>: what is typed, lower-cased, found in its
// name or its caption, so "lake at" finds lake_at_dawn.png. Everything is
// kept with nothing typed.
function keeps(image, filter) {
  var needle = String(filter || "").toLowerCase()
  return !needle || image.name.indexOf(needle) !== -1 || image.words.indexOf(needle) !== -1
}

// Each image's place among those <filter> keeps, -1 for one it drops, all in
// one pass.
function positions(images, filter) {
  var places = []
  var next = 0
  for (var i = 0; i < images.length; i++)
    places.push(keeps(images[i], filter) ? next++ : -1)
  return places
}

// The first image <filter> keeps, -1 if none.
function firstKept(images, filter) {
  for (var i = 0; i < images.length; i++)
    if (keeps(images[i], filter)) return i
  return -1
}

// Where the image at <path> is in <images>; the first for one not there.
function indexOf(images, path) {
  for (var i = 0; i < images.length; i++)
    if (images[i].path === path) return i
  return 0
}
