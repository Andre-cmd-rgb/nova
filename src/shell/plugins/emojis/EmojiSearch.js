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

// Whether <needle> begins a word somewhere in <k>: "cat" does in "grinning
// cat" and "cat face", not in "intoxicated" or "complicated".
function startsWord(k, needle) {
  for (var at = k.indexOf(needle); at !== -1; at = k.indexOf(needle, at + 1)) {
    var before = k.charAt(at - 1)
    if (at === 0 || (before.toLowerCase() === before.toUpperCase() && !/[0-9]/.test(before))) return true
  }
  return false
}

// The emoji that match <query>, at most <limit>: first those with a word that
// begins with it, then those with it inside a word, each in the list's order,
// so "cat" shows the cats before the woozy face (intoxicated). All of them, up
// to the limit, for an empty query.
function search(emojis, query, limit) {
  var needle = words(String(query || "").trim())
  var starts = []
  var inside = []
  for (var i = 0; i < emojis.length && starts.length < limit; i++) {
    var k = emojis[i].k
    if (!needle || startsWord(k, needle)) starts.push(emojis[i].e)
    else if (k.indexOf(needle) !== -1) inside.push(emojis[i].e)
  }
  return starts.concat(inside).slice(0, limit)
}
