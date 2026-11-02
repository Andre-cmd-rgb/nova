// The emoji picker's search. emojis.json is a list of { e: an emoji, k: the
// words a search matches }; what is typed is looked for anywhere in "k".

// The list, ready to search: "k" lower-cased once, not at every key. A file
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
    if (item && item.e) emojis.push({ e: item.e, k: String(item.k || "").toLowerCase() })
  }
  return emojis
}

// The emoji that match <query>, in the list's order, at most <limit>: all of
// them, up to the limit, for an empty one.
function search(emojis, query, limit) {
  var needle = String(query || "").trim().toLowerCase()
  var found = []
  for (var i = 0; i < emojis.length && found.length < limit; i++)
    if (!needle || emojis[i].k.indexOf(needle) !== -1) found.push(emojis[i].e)
  return found
}
