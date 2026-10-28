function validAddress(address) {
  if (/^[0-9]{1,3}(\.[0-9]{1,3}){3}$/.test(address)) {
    // No leading zeros, which inet_pton, and so NetworkManager, refuses.
    return address.split(".").every(function (part) { return Number(part) <= 255 && !/^0[0-9]/.test(part) })
  }
  if (!/^[0-9a-f:]+$/i.test(address) || address.indexOf(":") < 0) return false
  if (address.indexOf(":::") >= 0 || address.replace("::", "").indexOf("::") >= 0) return false
  if (/^:[^:]/.test(address) || /[^:]:$/.test(address)) return false
  var groups = address.split(":").filter(function (part) { return part.length > 0 })
  if (!groups.every(function (part) { return part.length <= 4 })) return false
  return address.indexOf("::") >= 0 ? groups.length <= 7 : groups.length === 8
}

function servers(text) {
  var list = text.trim().split(/[\s,]+/)
  return list.length >= 1 && list.length <= 4 && list.every(validAddress) ? list : []
}
