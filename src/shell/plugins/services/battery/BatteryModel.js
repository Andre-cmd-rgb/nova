// What the shell makes of UPower's display device: the battery as a whole.

// Its charge in percent, rounded; -1 with no battery.
function batteryPercentage(device) {
  if (!device || !device.isPresent) return -1
  return Math.round(Number(device.percentage || 0) * 100)
}

function isDischarging(device, onBattery, dischargingState) {
  return Boolean(device && device.isPresent && onBattery && device.state === dischargingState)
}

// Whether to warn now: the battery is discharging at or under the threshold,
// and was not low at the last look. notifiedLowBattery is what to remember
// for the next one, so the warning comes once each time it goes low.
function shouldWarnLowBattery(device, onBattery, dischargingState, threshold, alreadyNotified) {
  var level = batteryPercentage(device)
  var low = level >= 0 && isDischarging(device, onBattery, dischargingState) && level <= threshold
  return { level: level, notify: low && !alreadyNotified, notifiedLowBattery: low }
}

if (typeof module !== "undefined") {
  module.exports = {
    batteryPercentage: batteryPercentage,
    isDischarging: isDischarging,
    shouldWarnLowBattery: shouldWarnLowBattery
  }
}
