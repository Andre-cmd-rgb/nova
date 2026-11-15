.pragma library

// The rules of Wi-Fi's page in Settings below the networks (WifiLinkView),
// kept apart from the window: what nova-network-status --verbose and
// nova-network-band print, and the band's choices and the line under them.

// ---- nova-network-status --verbose: a "key<TAB>value" line each

// iw writes the bytes of an SSID that are not plain ASCII as \xHH. Those
// that make UTF-8 are read back as the text they spell; a control byte stays
// written out, and a name that is not UTF-8 at all is left as iw wrote it.
function ssidText(written) {
  const raw = String(written || "")
  // A \xHH of a byte that is not a control one becomes %HH, for
  // decodeURIComponent to read as UTF-8; all else is escaped as it stands.
  const escaped = raw.replace(/\\x([0-9A-Fa-f]{2})|[\s\S]/g, (token, hex) => {
    const code = hex === undefined ? -1 : Number("0x" + hex)
    return code >= 32 && code !== 127 ? "%" + hex : encodeURIComponent(token)
  })
  try {
    return decodeURIComponent(escaped)
  } catch (notText) {
    return raw
  }
}

// The fields of a reading, by key. Values are trimmed, but for the SSID,
// whose spaces are its own.
function readFields(text) {
  var fields = {}
  String(text || "").split("\n").forEach(function(line) {
    var tab = line.indexOf("\t")
    if (tab === -1) return
    var key = line.substring(0, tab)
    var value = line.substring(tab + 1)
    fields[key] = key === "ssid" ? ssidText(value) : value.trim()
  })
  return fields
}

// ---- nova-network-band: band, available and selected lines

function readBands(text) {
  var fields = readFields(text)
  return {
    band: fields.band || "",
    selected: fields.selected || "auto",
    available: String(fields.available || "").split(" ").filter(function(band) { return band !== "" })
  }
}

// "5 GHz", or nothing for no band.
function bandLabel(band) {
  return band ? band + " GHz" : ""
}

// Settings' choices for <bands> (readBands): Automatic, then each band the
// network answers on, and the one pinned even where it no longer answers.
function bandChoices(bands) {
  var offered = bands.available.slice()
  if (bands.selected !== "auto" && offered.indexOf(bands.selected) < 0) offered.push(bands.selected)
  return [{ label: "Automatic", value: "auto" }].concat(offered.map(function(band) {
    return { label: bandLabel(band), value: band }
  }))
}

// The line under them: the band the radio is on, and whether it stays there.
function bandNote(bands) {
  var now = bandLabel(bands.band)
  if (bands.selected !== "auto") return "Kept on " + bandLabel(bands.selected) + " for this network. Choosing a band reconnects."
  return now === "" ? "Wi-Fi picks the band." : "On " + now + " now. Wi-Fi picks the band; choosing one reconnects."
}
