// What hyprsunset's answer means. Below 6000 K the screen counts as tinted,
// as nova-toggle-nightlight counts it.
var IDENTITY_TEMPERATURE = 6000

// The first number in `hyprctl hyprsunset temperature`'s answer, or null.
function temperatureFromOutput(output) {
  var number = String(output == null ? "" : output).match(/[0-9]+/)
  return number ? Number(number[0]) : null
}

function isNightlight(temperature) {
  return temperature != null && temperature < IDENTITY_TEMPERATURE
}

if (typeof module !== "undefined") {
  module.exports = {
    IDENTITY_TEMPERATURE: IDENTITY_TEMPERATURE,
    temperatureFromOutput: temperatureFromOutput,
    isNightlight: isNightlight
  }
}
