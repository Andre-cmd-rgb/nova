import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland
import qs.Commons as Commons

// Nova's session lock: Wayland's ext-session-lock, with LockView on every
// screen, opened by the password (PAM's nova-lock-password) or, once the
// boot's first unlock is done, a fingerprint (nova-lock-fingerprint).
//
// Around the lock it also answers for the session: an autologin session
// locks before anything shows, a lock a crashed shell left behind is taken
// back, removable drives mount only once somebody has unlocked, and the
// screen goes dark 5 s after the last key under the lock.
Item {
  id: root

  readonly property string userName: Quickshell.env("USER") || Quickshell.env("LOGNAME")
  readonly property string backgroundLink: Commons.Color.stateHome + "/nova/current/background"
  // greetd's session says NOVA_LOGIN=password once the greeter has checked a
  // password. Any other start, autologin above all, has had nobody
  // authenticate, so the session locks before anything else shows.
  readonly property bool autologin: Quickshell.env("NOVA_LOGIN") !== "password"
  // In the runtime directory, so a shell started again knows the boot's
  // first unlock is done.
  readonly property string unlockedOnceFile: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/unlocked-once"

  // The lock as this shell asked for it, and as the compositor holds it.
  property bool lockRequested: false
  property bool pendingSessionLock: false
  readonly property bool locked: lockRequested || sessionLock.locked || sessionLock.secure

  property bool passwordPamConfigured: false
  property bool fingerprintConfigured: false
  property bool authenticatingPassword: false
  property bool fingerprintAuthenticating: false
  readonly property bool authenticating: authenticatingPassword || fingerprintAuthenticating
  // What is typed, the password being checked, and why the last one failed.
  property string enteredPassword: ""
  property string pendingPassword: ""
  property string failureMessage: ""
  property int failedAttempts: 0
  property double fingerprintStartedAt: 0
  property int fingerprintQuickFailures: 0

  // The boot's first unlock takes the password, which unlocks the keyring
  // too; the fingerprint is offered only after it. A password login at the
  // greeter was that first unlock.
  property bool unlockedOnce: !autologin
  property bool unlockedOnceKnown: false
  // The autologin lock, until it is secure and the boot submap can go.
  property bool bootLock: false

  // A lock a crashed shell left behind, and whether that has been asked yet.
  property bool strandedLock: false
  property bool strandedLockResolved: false

  property bool previewVisible: false
  property string backgroundPath: ""
  property int backgroundVersion: 0
  property string lastEvent: "init"
  property string lastEventAt: ""

  // Removable drives mount only in a session somebody has unlocked: never
  // under the lock, not before the boot's first unlock, and not while a lock
  // a crashed shell may have left is still unanswered.
  readonly property bool automountAllowed: !locked && unlockedOnce && strandedLockResolved

  function logEvent(event) {
    lastEvent = event
    lastEventAt = new Date().toISOString()
    console.log("nova lock " + lastEventAt + " " + event)
  }

  // Screens with a name and a size: one still coming up has neither, and
  // the lock waits for a screen it can show on.
  function realScreenCount() {
    var screens = Quickshell.screens || []
    var count = 0
    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i]
      if (screen && screen.name && screen.width > 0 && screen.height > 0) count++
    }
    return count
  }

  // A new lock: the field empty, the screen dark in 5 s, the compositor
  // asked once the screens have settled. Without the password's PAM file
  // nothing could open it, so there is none.
  function beginLock() {
    if (!passwordPamConfigured) {
      logEvent("lock-denied: missing-pam")
      return false
    }
    resetAuthentication()
    lockRequested = true
    armBlank()
    logEvent("lock-requested")
    queueSessionLock()
    Qt.callLater(function() {
      root.refreshBackground()
      root.refreshFingerprint()
    })
    return true
  }

  // Screens come and go around a lid or a dock: the compositor is asked once
  // they have been still for 500 ms, and then only with a real one, looked
  // for every 100 ms.
  function queueSessionLock() {
    pendingSessionLock = true
    if (!settleTimer.running) logEvent("lock-pending: screen-stabilizing")
    settleTimer.restart()
    if (!retryTimer.running) retryTimer.start()
  }

  function requestSessionLock() {
    if (!lockRequested || sessionLock.locked || sessionLock.secure || settleTimer.running) return
    if (realScreenCount() === 0) {
      if (!pendingSessionLock || lastEvent !== "lock-pending: no-real-screen") logEvent("lock-pending: no-real-screen")
      pendingSessionLock = true
      if (!retryTimer.running) retryTimer.start()
      return
    }
    stopPending()
    sessionLock.locked = true
  }

  // The lock is up, or no longer wanted: nothing more to wait for.
  function stopPending() {
    pendingSessionLock = false
    settleTimer.stop()
    retryTimer.stop()
  }

  function finishUnlock() {
    if (!locked) return
    // The compositor's lock goes first. WlSessionLock then reads unlocked
    // but announces only secure=false, so `locked` would keep its true, and
    // the next lock be taken for one already up; lockRequested changing
    // after it makes `locked` look again.
    sessionLock.locked = false
    lockRequested = false
    stopPending()
    resetAuthentication()
    blankTimer.stop()
    logEvent("unlocked")
    wake()
  }

  // Back to an empty field, with no check under way and no failure shown.
  function resetAuthentication() {
    enteredPassword = ""
    pendingPassword = ""
    failureMessage = ""
    failedAttempts = 0
    authenticatingPassword = false
    fingerprintAuthenticating = false
    fingerprintQuickFailures = 0
    fingerprintRetry.stop()
    passwordWatchdog.stop()
    if (passwordPam.active) passwordPam.abort()
    if (fingerprintPam.active) fingerprintPam.abort()
  }

  function submitPassword(value) {
    var password = String(value || "")
    if (!lockRequested || authenticatingPassword || !password) return
    wake()
    pendingPassword = password
    failureMessage = ""
    authenticatingPassword = true
    if (!passwordPam.start()) {
      failPassword()
      return
    }
    passwordWatchdog.restart()
    Qt.callLater(answerPasswordPrompt)
  }

  function answerPasswordPrompt() {
    if (authenticatingPassword && passwordPam.active && passwordPam.responseRequired) passwordPam.respond(pendingPassword)
  }

  // PAM's verdict. An attempt that a reset or the watchdog has settled is
  // over already.
  function passwordChecked(result) {
    if (!authenticatingPassword) return
    passwordWatchdog.stop()
    authenticatingPassword = false
    pendingPassword = ""
    if (!lockRequested) return
    if (result !== PamResult.Success) {
      failPassword()
      return
    }
    if (!unlockedOnce) completeFirstUnlock()
    finishUnlock()
  }

  function failPassword() {
    if (!lockRequested) return
    passwordWatchdog.stop()
    authenticatingPassword = false
    enteredPassword = ""
    pendingPassword = ""
    failedAttempts += 1
    failureMessage = "Authentication failed (" + failedAttempts + ")"
    wake()
  }

  function startFingerprint() {
    if (!lockRequested || !sessionLock.secure || !fingerprintConfigured || !unlockedOnce) return
    if (fingerprintPam.active || fingerprintAuthenticating) return
    fingerprintAuthenticating = true
    fingerprintStartedAt = Date.now()
    if (!fingerprintPam.start()) fingerprintAuthenticating = false
  }

  function fingerprintChecked(result) {
    fingerprintAuthenticating = false
    if (!lockRequested) return
    if (result === PamResult.Success) finishUnlock()
    else retryFingerprint()
  }

  // A finger that does not match takes seconds to say so. pam_fprintd fails
  // at once while the reader is gone or fprintd is down (just after resume,
  // say), so failures that quick wait longer each time, from 250 ms to 30 s.
  function retryFingerprint() {
    if (!lockRequested || !fingerprintConfigured) return
    fingerprintQuickFailures = Date.now() - fingerprintStartedAt < 1000 ? fingerprintQuickFailures + 1 : 0
    fingerprintRetry.interval = Math.min(250 * Math.pow(2, fingerprintQuickFailures), 30000)
    fingerprintRetry.restart()
  }

  // ext-session-lock outlives its client, and a shell started again holds no
  // lock, so a session locked this early may be an orphan behind Hyprland's
  // failsafe screen. It may also be another shell's live lock, which
  // Hyprland would let this one take over and strand on exit, so the helper
  // answers "cannot tell" while another locker runs, or while no output is
  // up; it is asked until the answer means something.
  function checkStrandedLock() {
    if (strandedLockResolved || strandedLockCheck.running) return
    // A lock this shell took is nobody's orphan.
    if (locked) {
      strandedLockResolved = true
      return
    }
    strandedLockCheck.running = true
  }

  function recoverStrandedLock() {
    if (!strandedLock || locked || !passwordPamConfigured) return
    strandedLock = false
    logEvent("lock-stranded: recovering")
    beginLock()
  }

  function lockForAutologin() {
    if (!autologin || !unlockedOnceKnown || unlockedOnce || !passwordPamConfigured || locked) return
    logEvent("lock-autologin")
    bootLock = beginLock()
  }

  // Hyprland starts an autologin session in a submap with no binds, so no
  // key works before the lock is up; once it is secure, Hyprland itself
  // allows only the binds marked for the lock screen.
  function leaveBootSubmap() {
    bootLock = false
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.submap(\"reset\")"])
  }

  function completeFirstUnlock() {
    unlockedOnce = true
    firstUnlock.running = true
  }

  // One nova-automount at a time; a change while it runs is applied after.
  function applyAutomount() {
    if (automount.running) return
    automount.allowed = automountAllowed
    automount.command = ["nova-automount", automountAllowed ? "on" : "off"]
    automount.running = true
  }

  function refreshBackground() {
    if (!readBackground.running) readBackground.running = true
  }

  function refreshFingerprint() {
    if (!fingerprintCheck.running) fingerprintCheck.running = true
  }

  // Any key or touch under the lock: the screen comes on, and the 5 s to dark
  // start again.
  function wake() {
    if (!waker.running) waker.running = true
    if (lockRequested) armBlank()
  }

  function armBlank() {
    blankTimer.armedAt = Date.now()
    blankTimer.restart()
  }

  function blank() {
    if (!blanker.running) blanker.running = true
  }

  WlSessionLock {
    id: sessionLock
    locked: false

    onSecureStateChanged: {
      root.logEvent("secure=" + secure)
      if (!secure) return
      root.stopPending()
      root.startFingerprint()
      // The boot's first lock may not be the autologin one (a stranded lock
      // taken back, one over IPC); whichever it is ends the boot submap.
      if (root.bootLock || !root.unlockedOnce) root.leaveBootSubmap()
    }

    onLockStateChanged: {
      root.logEvent("session-locked=" + locked)
      if (locked) {
        root.stopPending()
      } else if (root.lockRequested) {
        // The compositor ended the lock without an unlock from here.
        root.lockRequested = false
        root.stopPending()
        root.resetAuthentication()
        root.wake()
      }
    }

    WlSessionLockSurface {
      color: Commons.Color.background

      LockView {
        anchors.fill: parent
        backgroundPath: root.backgroundPath
        backgroundVersion: root.backgroundVersion
        fingerprintConfigured: root.fingerprintConfigured && root.unlockedOnce
        authenticatingPassword: root.authenticatingPassword
        failureMessage: root.failureMessage
        inputEnabled: root.lockRequested
        loadBackground: root.locked
        passwordText: root.enteredPassword
        onPasswordTextEdited: function(password) { root.enteredPassword = password }
        onSubmitPassword: function(password) { root.submitPassword(password) }
        onClearFailureRequested: root.failureMessage = ""
        onWakeRequested: root.wake()
      }
    }
  }

  // The lock screen as it looks, over everything, for `nova-shell lock
  // preview`; a click puts it away.
  PanelWindow {
    visible: root.previewVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "nova-lock-preview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    LockView {
      anchors.fill: parent
      backgroundPath: root.backgroundPath
      backgroundVersion: root.backgroundVersion
      fingerprintConfigured: root.fingerprintConfigured
      authenticatingPassword: false
      failureMessage: ""
      inputEnabled: false
      loadBackground: root.previewVisible
      passwordText: ""
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: root.previewVisible = false
    }
  }

  PamContext {
    id: passwordPam
    config: "nova-lock-password"
    user: root.userName

    onResponseRequiredChanged: root.answerPasswordPrompt()
    onPamMessage: root.answerPasswordPrompt()
    // An error is followed by completed(PamResult.Error), so every outcome
    // comes through here.
    onCompleted: function(result) { root.passwordChecked(result) }
  }

  // A PAM module that never answers (a stuck keyring daemon, say) would
  // leave the field at "Checking…" for the rest of the lock. abort() emits
  // nothing, so the attempt is failed here.
  Timer {
    id: passwordWatchdog
    interval: 20000
    onTriggered: {
      if (!root.authenticatingPassword) return
      root.logEvent("password: PAM did not answer")
      if (passwordPam.active) passwordPam.abort()
      root.failPassword()
    }
  }

  PamContext {
    id: fingerprintPam
    config: "nova-lock-fingerprint"
    user: root.userName

    onCompleted: function(result) { root.fingerprintChecked(result) }
  }

  Timer {
    id: fingerprintRetry
    interval: 250
    onTriggered: root.startFingerprint()
  }

  // The background the lock shows is the desktop's, read through its link.
  Process {
    id: readBackground
    command: ["readlink", "-f", root.backgroundLink]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var path = String(text || "").trim()
        if (path === root.backgroundPath) return
        root.backgroundPath = path
        root.backgroundVersion += 1
      }
    }
  }

  // A fingerprint counts once its PAM file is there and fprintd has one
  // enrolled for this user.
  Process {
    id: fingerprintCheck
    command: ["bash", "-c", "[[ -f /etc/pam.d/nova-lock-fingerprint ]] && command -v fprintd-list >/dev/null && fprintd-list \"$USER\" 2>/dev/null | grep -qE '^ *- #[0-9]+: '"]
    onExited: function(exitCode) {
      root.fingerprintConfigured = exitCode === 0
      if (root.fingerprintConfigured) {
        if (root.lockRequested) root.startFingerprint()
        return
      }
      // abort() says nothing, so the scan is marked over here; one enrolled
      // again under the same lock can then start.
      fingerprintRetry.stop()
      if (fingerprintPam.active) fingerprintPam.abort()
      root.fingerprintAuthenticating = false
    }
  }

  Process {
    id: strandedLockCheck
    // bash's parent is this shell, and the pid the helper is to skip: a shell
    // that crashed starts again in the same process.
    command: ["bash", "-c", "nova-hyprland-session-lock-stranded \"$PPID\""]
    onExited: function(exitCode) {
      // 2: cannot tell yet.
      if (exitCode === 2) return
      // A lock taken while the helper ran is this shell's own.
      root.strandedLock = exitCode === 0 && !root.locked
      root.recoverStrandedLock()
      // Answered only once a stranded lock is taken back, so the moment
      // between never reads as an unlocked session.
      root.strandedLockResolved = true
    }
  }

  // Notes the first unlock and starts nova-unlocked.target. The password
  // stays inside PAM: pam_gnome_keyring in nova-lock-password has unlocked
  // the login keyring with it already.
  Process {
    id: firstUnlock
    command: ["nova-session-first-unlock"]
    onExited: function(exitCode) {
      if (exitCode !== 0) root.logEvent("first-unlock: helper exited " + exitCode)
    }
  }

  FileView {
    path: root.unlockedOnceFile
    printErrors: false
    onLoaded: {
      root.unlockedOnce = true
      root.unlockedOnceKnown = true
    }
    onLoadFailed: {
      root.unlockedOnceKnown = true
      root.lockForAutologin()
    }
  }

  Process {
    id: automount
    // What the call under way says.
    property bool allowed: false
    onExited: if (allowed !== root.automountAllowed) root.applyAutomount()
  }

  onAutomountAllowedChanged: applyAutomount()

  Process {
    id: waker
    command: ["nova-system-wake"]
  }

  Process {
    id: blanker
    command: ["bash", "-c", "nova-brightness-keyboard off; nova-brightness-display off"]
  }

  Timer {
    id: blankTimer
    interval: 5000
    property double armedAt: 0
    onTriggered: {
      // Run out while the machine slept, it would blank the screen just
      // woken under the user; the wall clock shows the gap, so it starts over.
      if (Date.now() - armedAt > interval + 2000) {
        root.armBlank()
        return
      }
      // A password being checked keeps the screen on. The fingerprint's PAM
      // runs for the whole lock, so it does not.
      if (root.lockRequested && !root.authenticatingPassword) root.blank()
    }
  }

  Timer {
    id: settleTimer
    interval: 500
    onTriggered: root.requestSessionLock()
  }

  Timer {
    id: retryTimer
    interval: 100
    repeat: true
    onTriggered: root.requestSessionLock()
  }

  // The stranded-lock question, every 500 ms, 20 times at most while the
  // compositor settles; screens coming back start the count again.
  Timer {
    id: strandedLockRetry
    interval: 500
    repeat: true
    property int remaining: 20
    running: !root.strandedLockResolved && remaining > 0

    function rearm() {
      if (!root.strandedLockResolved) remaining = 20
    }

    onTriggered: {
      remaining -= 1
      root.checkStrandedLock()
    }
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      root.requestSessionLock()
      // A screen still coming up has no workspace, so cannot answer yet.
      strandedLockRetry.rearm()
      root.checkStrandedLock()
    }
  }

  onAuthenticatingPasswordChanged: {
    if (!lockRequested) return
    if (authenticatingPassword) blankTimer.stop()
    else armBlank()
  }

  FileView {
    path: "/etc/pam.d/nova-lock-password"
    watchChanges: true
    printErrors: false
    onLoaded: root.passwordPamConfigured = true
    onLoadFailed: root.passwordPamConfigured = false
    onFileChanged: reload()
  }

  // No lock before PAM is known good. A stranded-lock answer from before
  // then may be stale (the failsafe can be cleared from a TTY), so the
  // question is asked again.
  onPasswordPamConfiguredChanged: {
    if (!passwordPamConfigured) return
    lockForAutologin()
    strandedLock = false
    strandedLockResolved = false
    strandedLockRetry.rearm()
    checkStrandedLock()
  }

  Component.onCompleted: {
    refreshBackground()
    refreshFingerprint()
    checkStrandedLock()
    applyAutomount()
  }

  IpcHandler {
    target: "lock"

    function lock(): string {
      if (!root.passwordPamConfigured) return "missing-pam"
      if (!root.locked) root.beginLock()
      return "ok"
    }

    function isLocked(): string {
      return root.locked ? "true" : "false"
    }

    // Read by nova-session-guard: "secure" once the compositor confirms the
    // lock, "unlocked" after a real unlock, "starting" until one of those.
    function state(): string {
      if (sessionLock.secure) return "secure"
      if (!root.locked && root.unlockedOnce) return "unlocked"
      return "starting"
    }

    function status(): string {
      return JSON.stringify({
        locked: root.locked,
        requested: root.lockRequested,
        pending: root.pendingSessionLock,
        sessionLocked: sessionLock.locked,
        secure: sessionLock.secure,
        realScreens: root.realScreenCount(),
        passwordPam: root.passwordPamConfigured,
        fingerprint: root.fingerprintConfigured,
        unlockedOnce: root.unlockedOnce,
        authenticating: root.authenticating,
        lastEvent: root.lastEvent,
        lastEventAt: root.lastEventAt
      })
    }

    function preview(): string {
      root.refreshBackground()
      root.refreshFingerprint()
      root.previewVisible = true
      return "ok"
    }

    function hidePreview(): string {
      root.previewVisible = false
      return "ok"
    }
  }
}
