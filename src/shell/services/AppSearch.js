.pragma library

// How the menu's app search matches and ranks desktop entries.
//
// A query is cut into words at whitespace, and an entry matches when each
// word is found in its name, id, generic name, comment or keywords; a word
// of up to five letters may instead be found in the entry's initials (see
// entryAcronym). A match is then ranked by where the whole query is found:
// at the start of the name, at the start of the id, inside the name, inside
// the id, anywhere in that text, in the initials, and last when only its
// words are found apart; a shorter name or id, or an earlier place, ranks
// higher within each.

function entryName(entry) {
  return entry ? String(entry.name || entry.id || "") : ""
}

function entrySubtext(entry) {
  return entry ? String(entry.genericName || "") : ""
}

function entrySortKey(entry) {
  return entryName(entry).toLowerCase()
}

// The keywords as one string. They come from Qt as a list that may not be
// a true array; anything that cannot be joined counts as none.
function keywordText(entry) {
  try {
    var keywords = entry && entry.keywords
    return keywords && typeof keywords.join === "function" ? keywords.join(" ") : ""
  } catch (error) {
    return ""
  }
}

// Everything a query word may be found in, lowercased.
function entrySearchText(entry) {
  if (!entry) return ""
  var fields = [entry.name, entry.genericName, entry.comment, keywordText(entry), entry.id]
  return fields.join(" ").toLowerCase()
}

// The text lowercased with camelCase humps, dots, colons, slashes and dashes
// turned into spaces: "org.gnome.TextEditor" reads "org gnome text editor".
function wordText(value) {
  var text = String(value || "")
  return text.replace(/([a-z\d])(?=[A-Z])/g, "$1 ").replace(/[-._:/\\]+/g, " ").toLowerCase()
}

// The letter and digit runs of wordText.
function words(value) {
  return wordText(value).split(/[^a-z\d]+/).filter(function(word) { return word.length > 0 })
}

// The first letter of each word of the name, generic name, keywords and id,
// in that order: for "Visual Studio Code" they begin "vsc".
function entryAcronym(entry) {
  var parts = words([entry && entry.name, entry && entry.genericName, keywordText(entry), entry && entry.id].join(" "))
  var initials = ""
  for (var i = 0; i < parts.length; i++) initials += parts[i].charAt(0)
  return initials
}

// What a query is held against, worked out once per entry; the initials
// only when a word needs them.
function searchFacts(entry) {
  var acronym = null
  return {
    name: entryName(entry).toLowerCase(),
    id: String((entry && entry.id) || "").toLowerCase(),
    text: entrySearchText(entry),
    acronym: function() {
      if (acronym === null) acronym = entryAcronym(entry)
      return acronym
    }
  }
}

function factsMatch(facts, term) {
  if (term.length === 0) return true
  if (facts.name.indexOf(term) >= 0 || facts.id.indexOf(term) >= 0 || facts.text.indexOf(term) >= 0) return true
  return term.length <= 5 && facts.acronym().indexOf(term) >= 0
}

function factsMatchAll(facts, query) {
  var terms = String(query || "").trim().toLowerCase().split(/\s+/)
  return terms.every(function(term) { return factsMatch(facts, term) })
}

// Whether the lowercase word <term> is found in the entry.
function termMatches(entry, term) {
  return !term || factsMatch(searchFacts(entry), term)
}

// Whether every word of <query> is found in the entry.
function allTermsMatch(entry, query) {
  return factsMatchAll(searchFacts(entry), query)
}

// The rank of the entry for <query>: higher is better, 0 for no query and
// -1 when it does not match.
function fuzzyScore(entry, query) {
  query = String(query || "").trim().toLowerCase()
  if (query.length === 0) return 0
  var facts = searchFacts(entry)
  if (!factsMatchAll(facts, query)) return -1

  var inName = facts.name.indexOf(query)
  var inId = facts.id.indexOf(query)
  if (inName === 0) return 10000 - facts.name.length
  if (inId === 0) return 9500 - facts.id.length
  if (inName > 0) return 8000 - inName * 10 - facts.name.length
  if (inId > 0) return 7600 - inId * 10 - facts.id.length

  var inText = facts.text.indexOf(query)
  if (inText >= 0) return 6000 - inText

  var acronym = facts.acronym()
  var inAcronym = acronym.indexOf(query)
  if (inAcronym === 0) return 5000 - acronym.length
  if (inAcronym > 0) return 4600 - inAcronym * 10 - acronym.length

  return 4000 - facts.name.length
}

// The entries to list for <query>, best first, as rows of { entry, score,
// key, name } (key and name are both the lowercase name): those that match,
// leaving out NoDisplay ones, nameless ones and any <isHidden> says to
// hide. With no query, or among equal scores, by name; two of one name by
// their desktop IDs, as the order the entries come in changes from one start
// of the shell to the next.
function sortedEntries(values, query, isHidden) {
  var searching = String(query || "").trim()
  var rows = []
  for (var i = 0; i < values.length; i++) {
    var entry = values[i]
    var name = entry && !entry.noDisplay && !(isHidden && isHidden(entry)) ? entryName(entry) : ""
    var score = name ? fuzzyScore(entry, searching) : -1
    if (score >= 0) rows.push({ entry: entry, score: score, key: name.toLowerCase(), name: name.toLowerCase() })
  }
  return rows.sort(function(a, b) {
    if (searching && a.score !== b.score) return b.score - a.score
    if (a.key !== b.key) return a.key < b.key ? -1 : 1
    var first = String(a.entry.id || ""), second = String(b.entry.id || "")
    return first < second ? -1 : first > second ? 1 : 0
  })
}
