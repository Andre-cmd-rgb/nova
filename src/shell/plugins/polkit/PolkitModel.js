// Whether a PAM file has the fingerprint reader in its auth stack: a line
// for pam_fprintd, on "auth" or "-auth" (skipped when the module is not
// installed). A gate before it, such as Nova's lid check, changes nothing.
function fingerprintInPam(text) {
  return String(text || "").split("\n").some(function (line) {
    line = line.trim()
    return /^-?auth\s/.test(line) && line.indexOf("pam_fprintd.so") !== -1
  })
}

// What the dialog says the request is for. pkexec's "Authentication is
// needed to run `cmd' as the super user" becomes "Authorize running 'cmd'";
// any other message is shown as it is.
function requestLabel(message) {
  var text = String(message || "")
  var command = /^Authentication is (?:needed|required) to run [`']([^`']+)[`'] as /i.exec(text)
  return command ? "Authorize running '" + command[1] + "'" : text
}
