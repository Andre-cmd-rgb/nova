.pragma library

// The night light's schedule, apart from its QML: when the sun rises and
// sets, and the last time the schedule turned the night light on or off.

// The warmth a night light has unless one is chosen, and the range Settings
// offers, in kelvin. hyprsunset's daylight is 6500 K, and below 6000 K the
// screen counts as warmed (nova-toggle-nightlight).
var NIGHT = 4000
var WARMEST = 2500
var COOLEST = 5500

// A warmth from shell.json, or the night's for anything else.
function warmth(value) {
  const kelvin = Math.round(Number(value))
  return kelvin >= WARMEST && kelvin <= COOLEST ? kelvin : NIGHT
}

// When the sun rises and sets on the day <day> falls on (ms, the local
// day) at <latitude> and <longitude> in degrees, north and east positive:
// { rise, set } in ms, or null on a day it does not rise or set. The
// sunrise equation, as Wikipedia has it, within a minute or two of an
// almanac.
function sun(day, latitude, longitude) {
  const rad = Math.PI / 180
  const date = new Date(day)
  // Days since J2000 (noon, 1 January 2000, UTC) of the solar noon nearest
  // this day's noon on the clock.
  const noon = new Date(date.getFullYear(), date.getMonth(), date.getDate(), 12).getTime() / 86400000 - 10957.5
  const solarNoon = Math.round(noon + longitude / 360) - longitude / 360
  const anomaly = (357.5291 + 0.98560028 * solarNoon) % 360
  const centre = 1.9148 * Math.sin(anomaly * rad) + 0.02 * Math.sin(2 * anomaly * rad) + 0.0003 * Math.sin(3 * anomaly * rad)
  const ecliptic = (anomaly + centre + 180 + 102.9372) % 360
  const transit = solarNoon + 0.0053 * Math.sin(anomaly * rad) - 0.0069 * Math.sin(2 * ecliptic * rad)
  const declination = Math.asin(Math.sin(ecliptic * rad) * Math.sin(23.4397 * rad))
  const hour = (Math.sin(-0.833 * rad) - Math.sin(latitude * rad) * Math.sin(declination))
    / (Math.cos(latitude * rad) * Math.cos(declination))
  if (!(hour >= -1 && hour <= 1)) return null
  const half = Math.acos(hour) / (2 * Math.PI)
  return {
    rise: Math.round((transit - half + 10957.5) * 86400000),
    set: Math.round((transit + half + 10957.5) * 86400000)
  }
}

// The night light's last turn at or before <now> (ms) by the sun at
// <latitude> and <longitude>: on at sunset, off at sunrise, as { on, since }
// with the time of the turn; null with neither yesterday nor today.
function lastTurn(now, latitude, longitude) {
  const today = new Date(now)
  let last = null
  for (const back of [1, 0]) {
    const times = sun(new Date(today.getFullYear(), today.getMonth(), today.getDate() - back, 12).getTime(), latitude, longitude)
    if (!times) continue
    for (const turn of [{ on: false, since: times.rise }, { on: true, since: times.set }]) {
      if (turn.since <= now && (!last || turn.since > last.since)) last = turn
    }
  }
  return last
}

// The time (ms) of the night light's next turn after <now> by the sun at
// <latitude> and <longitude>, sunrise or sunset, today or in the two days
// after: what a Timer is aimed at. Null where the sun neither rises nor sets
// in that time.
function nextTurn(now, latitude, longitude) {
  const today = new Date(now)
  let next = null
  for (const ahead of [0, 1, 2]) {
    const times = sun(new Date(today.getFullYear(), today.getMonth(), today.getDate() + ahead, 12).getTime(), latitude, longitude)
    if (!times) continue
    for (const time of [times.rise, times.set]) {
      if (time > now && (next === null || time < next)) next = time
    }
  }
  return next
}
