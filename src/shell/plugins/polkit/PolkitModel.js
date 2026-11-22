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
  return String(message || "").replace(/^Authentication is (?:needed|required) to run [`']([^`']+)[`'] as [\s\S]*$/i, "Authorize running '$1'")
}

// The account whose password a request asks for, as polkit names it: the
// identity the flow has chosen, a user's name; "" for none, or for a group's,
// which names no one account.
function accountName(identity) {
  if (!identity || identity.isGroup) return ""
  const shown = String(identity.displayName || "").trim()
  if (shown !== "") return shown
  const named = /^unix-user:(.+)$/.exec(String(identity.string || ""))
  return named ? named[1] : ""
}

// What the empty password field says: whose password, where polkit says.
function passwordPrompt(account) {
  return account ? "Password for " + account : "Enter password"
}
