.pragma library
// The weather panel's rules, kept apart from its window and its fetches: the
// place nova-weather-location keeps, what the two weather services answer,
// the units, and the glyphs.
//
// wttr.in finds the place from this computer's address when none is set,
// and gives the weather now and the days ahead. Open-Meteo answers sooner,
// for a place's coordinates, and knows night from day. Both answers are read
// into one shape: the weather now as { tempC, tempF, feelsC, feelsF,
// windKmh, windMph, humidity, code, meteo, night }, where code is the
// service's own condition code and meteo says whose; a day ahead as
// { date, highC, lowC, highF, lowF, glyph }.

function trimmed(value) {
  return String(value || "").replace(/^\s+|\s+$/g, "")
}

// --------------------------------------------------------------- the place

// weather.json, as nova-weather-location writes it: { name, latitude,
// longitude }, the coordinates kept only as a pair. Missing or unreadable is
// no place set, and the weather is for the address's town.
function readPlace(text) {
  var none = { name: "", latitude: null, longitude: null }
  try {
    var data = JSON.parse(String(text || ""))
    if (!data || typeof data !== "object") return none
    var latitude = parseFloat(data.latitude)
    var longitude = parseFloat(data.longitude)
    var pair = !isNaN(latitude) && !isNaN(longitude)
    return {
      name: typeof data.name === "string" ? trimmed(data.name) : "",
      latitude: pair ? latitude : null,
      longitude: pair ? longitude : null
    }
  } catch (unreadable) {
    return none
  }
}

function hasCoordinates(place) {
  return !isNaN(parseFloat(String(place.latitude))) && !isNaN(parseFloat(String(place.longitude)))
}

// What wttr.in is asked for: the coordinates, else the name (a weather.json
// written by hand may have only that), else nothing, for the address's town.
function wttrQuery(place) {
  var latitude = parseFloat(String(place.latitude))
  var longitude = parseFloat(String(place.longitude))
  if (!isNaN(latitude) && !isNaN(longitude)) return latitude + "," + longitude
  var name = trimmed(place.name)
  return name === "" ? "" : encodeURIComponent(name)
}

// Where Open-Meteo is asked about: the place set, else the area wttr.in
// found, as { latitude, longitude }; null without a pair of numbers.
function meteoPoint(place, area) {
  var latitude = parseFloat(String(place.latitude))
  var longitude = parseFloat(String(place.longitude))
  if (isNaN(latitude) || isNaN(longitude)) {
    if (!area) return null
    latitude = parseFloat(String(area.latitude || ""))
    longitude = parseFloat(String(area.longitude || ""))
  }
  return isNaN(latitude) || isNaN(longitude) ? null : { latitude: latitude, longitude: longitude }
}

// The town wttr.in places the address in, from its "%l": "Town, Region"
// gives the town. A place it has no name for it gives as "lat,lon", which
// stays whole, as nova-weather-location keeps it. null for no answer.
var COORDINATES = /^-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?$/

function detectedTown(text) {
  var line = String(text || "").trim()
  if (line === "") return null
  return COORDINATES.test(line) ? line : line.split(",")[0]
}

// Open-Meteo's places for a search, as the suggestions under the field:
// { name, description, latitude, longitude }, the description being the
// region and country. Those without a name or coordinates are left out.
function suggestions(text) {
  try {
    var results = JSON.parse(String(text || "{}")).results
    if (!results || !results.length) return []
    var found = []
    for (var i = 0; i < results.length; i++) {
      var result = results[i]
      if (!result || !result.name || result.latitude === undefined || result.longitude === undefined) continue
      found.push({
        name: String(result.name),
        description: [result.admin1, result.country].filter(function(part) { return !!part }).join(", "),
        latitude: result.latitude,
        longitude: result.longitude
      })
    }
    return found
  } catch (unreadable) {
    return []
  }
}

// The place Enter sets: the suggestion picked, else the name typed without
// coordinates; nothing typed sets no place.
function chosenPlace(text, choices, index) {
  var name = trimmed(text)
  if (name === "") return { name: "", latitude: null, longitude: null }
  var list = choices || []
  var picked = list[Math.max(0, Math.min(parseInt(index, 10) || 0, list.length - 1))]
  return picked || { name: name, latitude: null, longitude: null }
}

// ------------------------------------------------------------- the requests

function wttrUrl(query) {
  return "https://wttr.in/" + query + "?format=j1"
}

function meteoUrl(point) {
  return "https://api.open-meteo.com/v1/forecast"
    + "?latitude=" + encodeURIComponent(String(point.latitude))
    + "&longitude=" + encodeURIComponent(String(point.longitude))
    + "&daily=weather_code,temperature_2m_max,temperature_2m_min"
    + "&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"
    + "&forecast_days=4"
    + "&timezone=auto"
}

function searchUrl(query) {
  return "https://geocoding-api.open-meteo.com/v1/search?name=" + encodeURIComponent(query) + "&count=5&language=en&format=json"
}

// ------------------------------------------------------------- the weather

// A reading as a whole number, as text; "" for none.
function rounded(value) {
  if (value === undefined || value === null || value === "") return ""
  var number = parseFloat(String(value))
  return isNaN(number) ? "" : String(Math.round(number))
}

function fahrenheit(celsius) {
  if (celsius === undefined || celsius === null || celsius === "") return ""
  var number = parseFloat(String(celsius))
  return isNaN(number) ? "" : number * 9 / 5 + 32
}

// wttr.in's weather now, its readings as it gives them.
function wttrNow(report) {
  var now = report && report.current_condition && report.current_condition[0]
  if (!now) return null
  return {
    tempC: now.temp_C,
    tempF: now.temp_F,
    feelsC: now.FeelsLikeC,
    feelsF: now.FeelsLikeF,
    windKmh: now.windspeedKmph,
    windMph: now.windspeedMiles,
    humidity: now.humidity,
    code: now.weatherCode,
    meteo: false,
    night: false
  }
}

// Open-Meteo's weather now, in Celsius and km/h, rounded and turned.
function meteoNow(report) {
  var now = report && report.current ? report.current : null
  if (!now || now.temperature_2m === undefined || now.temperature_2m === null) return null
  return {
    tempC: rounded(now.temperature_2m),
    tempF: rounded(fahrenheit(now.temperature_2m)),
    feelsC: rounded(now.apparent_temperature),
    feelsF: rounded(fahrenheit(now.apparent_temperature)),
    windKmh: rounded(now.wind_speed_10m),
    windMph: rounded(now.wind_speed_10m * 0.621371),
    humidity: rounded(now.relative_humidity_2m),
    code: now.weather_code,
    meteo: true,
    night: Number(now.is_day) === 0
  }
}

// The weather now as the panel writes it: the temperature's number, then
// the feel, the wind and the humidity with their units.
function nowText(now, imperial) {
  if (!now) return { temp: "", feels: "", wind: "", humidity: "" }
  return {
    temp: String(imperial ? now.tempF : now.tempC),
    feels: withUnit(imperial ? now.feelsF : now.feelsC, imperial),
    wind: imperial ? now.windMph + " mph" : now.windKmh + " km/h",
    humidity: now.humidity + "%"
  }
}

function withUnit(value, imperial) {
  if (value === undefined || value === null || value === "") return ""
  return value + "°" + (imperial ? "F" : "C")
}

// A day's high or low, its unit left to the heading.
function degrees(value) {
  if (value === undefined || value === null || value === "") return ""
  return value + "°"
}

// The bar's glyph for the weather now; `otherwise` when there is none.
function nowGlyph(now, otherwise) {
  if (!now || now.code === undefined || now.code === null) return otherwise || ""
  return now.meteo ? meteoGlyph(now.code, now.night) : wttrGlyph(now.code, false)
}

// Whether a day is after today; both as "yyyy-MM-dd".
function ahead(date, today) {
  if (!date) return false
  return String(date).slice(0, 10) > String(today || "")
}

// The next three days. Open-Meteo's when it has them, else wttr.in's.
function forecastDays(wttr, meteo, today) {
  var days = meteoDays(meteo, today)
  return days.length > 0 ? days : wttrDays(wttr, today)
}

function meteoDays(report, today) {
  var daily = report && report.daily ? report.daily : null
  if (!daily || !daily.time) return []
  var days = []
  for (var i = 0; i < daily.time.length && days.length < 3; i++) {
    if (!ahead(daily.time[i], today)) continue
    var high = daily.temperature_2m_max ? daily.temperature_2m_max[i] : ""
    var low = daily.temperature_2m_min ? daily.temperature_2m_min[i] : ""
    var code = daily.weather_code ? daily.weather_code[i] : null
    days.push({
      date: daily.time[i],
      highC: rounded(high),
      lowC: rounded(low),
      highF: rounded(fahrenheit(high)),
      lowF: rounded(fahrenheit(low)),
      glyph: code === undefined || code === null ? "" : meteoGlyph(code, false)
    })
  }
  return days
}

// wttr.in's days, their readings as it gives them; a day's glyph is that of
// its hour nearest noon.
function wttrDays(report, today) {
  var all = report && report.weather ? report.weather : []
  var days = []
  for (var i = 0; i < all.length && days.length < 3; i++) {
    var day = all[i]
    if (!ahead(day.date, today)) continue
    days.push({
      date: day.date,
      highC: day.maxtempC,
      lowC: day.mintempC,
      highF: day.maxtempF,
      lowF: day.mintempF,
      glyph: noonGlyph(day.hourly)
    })
  }
  return days
}

function noonGlyph(hours) {
  if (!hours || hours.length === 0) return ""
  var noon = hours[0]
  var nearest = 9999
  for (var i = 0; i < hours.length; i++) {
    var away = Math.abs(parseInt(String(hours[i].time || "0"), 10) - 1200)
    if (away < nearest) {
      nearest = away
      noon = hours[i]
    }
  }
  return wttrGlyph(noon.weatherCode, false)
}

// A day's name, at noon of its date: `format` names it, else English does.
function dayName(date, format) {
  if (!date) return ""
  var noon = new Date(date + "T12:00:00")
  if (isNaN(noon.getTime())) return ""
  if (format) return format(noon)
  return ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][noon.getDay()]
}

// --------------------------------------------------------------- the units

// Fahrenheit and miles where the unit setting says imperial, else where the
// country of the weather's place uses them, else where the locale does.
function imperial(unit, locale, country) {
  var chosen = trimmed(unit).toLowerCase()
  if (chosen === "imperial") return true
  if (chosen === "metric") return false
  var byCountry = countryImperial(country)
  return byCountry !== null ? byCountry : localeImperial(locale)
}

// Whether a country uses Fahrenheit, by its name as wttr.in gives it; null
// for no country.
function countryImperial(name) {
  var country = trimmed(name).replace(/[._-]+/g, " ").toLowerCase()
  if (!country) return null
  return ["us", "usa", "united states", "united states of america", "liberia", "myanmar", "burma"].indexOf(country) !== -1
}

function localeImperial(locale) {
  var name = String(locale || "").replace(".", "_")
  return /^en[_-]US($|[_.-])/.test(name) || /^en[_-]LR($|[_.-])/.test(name) || /^my($|[_.-])/.test(name)
}

// -------------------------------------------------------------- the glyphs

// A service's condition code as a number: none is 0.
function codeOf(code) {
  return parseInt(String(code || "0"), 10)
}

// wttr.in's codes as nova-weather-icon draws them, by day and by night; a
// code not listed is drawn as cloud.
var CLOUD = ""
var WTTR_GLYPHS = {}
;[
  [[113], "", ""],                                                             // clear
  [[116], "", ""],                                                             // partly cloudy
  [[119, 122], CLOUD, CLOUD],                                                    // cloudy, overcast
  [[143, 248, 260], "", ""],                                                   // mist, fog
  [[176, 263, 353], "", ""],                                                   // a little rain
  [[179, 227, 230, 323, 326, 368], "", ""],                                    // a little snow, blowing snow
  [[182, 185, 281, 284, 311, 314, 317, 320, 350, 362, 365, 374, 377], "", ""], // sleet, freezing rain, ice
  [[200, 386, 389, 392, 395], "", ""],                                         // thunder
  [[266, 293, 296, 299, 302, 305, 308, 356, 359], "", ""],                     // rain
  [[329, 332, 335, 338, 371], "", ""]                                          // snow
].forEach(function(entry) {
  entry[0].forEach(function(code) { WTTR_GLYPHS[code] = { day: entry[1], night: entry[2] } })
})

function wttrGlyph(code, night) {
  var glyphs = WTTR_GLYPHS[codeOf(code)]
  if (!glyphs) return CLOUD
  return night ? glyphs.night : glyphs.day
}

// Open-Meteo's (WMO) codes, drawn as the wttr.in code nearest them; one not
// listed as cloudy.
var METEO_AS_WTTR = {
  0: 113,
  1: 116, 2: 116,
  3: 119,
  45: 143, 48: 143,
  51: 266, 53: 266, 55: 266, 56: 266, 57: 266, 61: 266,
  63: 308, 65: 308, 66: 308, 67: 308, 80: 308, 81: 308, 82: 308,
  71: 338, 73: 338, 75: 338, 77: 338, 85: 338, 86: 338,
  95: 389, 96: 389, 99: 389
}

function meteoGlyph(code, night) {
  var wttr = METEO_AS_WTTR[codeOf(code)]
  return wttrGlyph(wttr === undefined ? 119 : wttr, night)
}
