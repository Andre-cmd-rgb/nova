// The image picker's list: the images a request brings, what each is called,
// and which of them a filter keeps.

// A path's file name, and that without its extension: "/w/tokyo-night.png"
// is "tokyo-night.png", named "tokyo-night" and captioned "Tokyo Night".
function fileOf(path) {
  return String(path || "").split("/").pop()
}

function nameOf(path) {
  return fileOf(path).replace(/\.[^.]+$/, "")
}

function captionOf(path) {
  return nameOf(path).replace(/[-_]+/g, " ").replace(/\b\w/g, letter => letter.toUpperCase())
}

// The images in <text>, a line each: the image's path and, after a tab, its
// thumbnail's, or the image's own path for one without. Of images with the
// same file name, in two folders, the first is kept. Each carries its caption,
// and its name and caption lower-cased for the filter.
function parse(text) {
  const files = new Set()
  const firstOfItsName = ([path]) => !!path && !files.has(fileOf(path)) && !!files.add(fileOf(path))
  return String(text || "").split("\n").map(line => line.split("\t")).filter(firstOfItsName).map(([path, thumbnail]) => {
    const caption = captionOf(path)
    return { path, thumbnail: thumbnail || path, caption, name: nameOf(path).toLowerCase(), words: caption.toLowerCase() }
  })
}

// Whether <filter> keeps <image>: what is typed, lower-cased, found in its
// name or its caption, so "lake at" finds lake_at_dawn.png. Everything is
// kept with nothing typed.
function keeps(image, filter) {
  const typed = String(filter || "").toLowerCase()
  return image.name.includes(typed) || image.words.includes(typed)
}

// Each image's place among those <filter> keeps, -1 for one it drops, all in
// one pass.
function positions(images, filter) {
  let kept = 0
  return images.map(image => keeps(image, filter) ? kept++ : -1)
}

// The first image <filter> keeps, -1 if none.
function firstKept(images, filter) {
  return images.findIndex(image => keeps(image, filter))
}

// Where the image at <path> is in <images>; the first for one not there.
function indexOf(images, path) {
  return Math.max(0, images.findIndex(image => image.path === path))
}
