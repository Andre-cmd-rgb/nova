// The emoji picker's search. emojis.json is a list of { e: an emoji, k: the
// words a search matches }; what is typed is looked for anywhere in "k".

// Words as the search compares them: lower-cased, with "_", and "-" between
// letters, read as spaces. GitHub's names for emoji join words with "_"
// (heart_eyes) where Unicode's join them with "-" (heart-eyes) or a space, so
// either way of typing finds the emoji.
function words(text) {
  return String(text || "").toLowerCase().replace(/(\w)-(?=\w)/g, "$1 ").replace(/_/g, " ")
}

// The list, ready to search: "k" made words once, not at every key. A file
// that does not parse is an empty list.
function parse(text) {
  var list
  try {
    list = JSON.parse(String(text || ""))
  } catch (e) {
    return []
  }
  if (!Array.isArray(list)) return []
  var emojis = []
  for (var i = 0; i < list.length; i++) {
    var item = list[i]
    if (item && item.e) emojis.push({ e: item.e, k: words(item.k) })
  }
  return emojis
}

// The emoji that match <query>, in the list's order, at most <limit>: all of
// them, up to the limit, for an empty one.
function search(emojis, query, limit) {
  var needle = words(String(query || "").trim())
  var found = []
  for (var i = 0; i < emojis.length && found.length < limit; i++)
    if (!needle || emojis[i].k.indexOf(needle) !== -1) found.push(emojis[i].e)
  return found
}
