import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland
import qs.Commons as Commons

// Nova's lock screen. Wayland's ext-session-lock holds the session and puts
// LockView on every screen; the password opens it through PAM's
// nova-lock-password and, once the boot's first unlock is done, a finger
// can too, through nova-lock-fingerprint.
//
// What hangs on the lock is looked after here as well: an autologin session
// locks before anything shows, a lock left by a shell that crashed is taken
// back, removable drives mount only in a session somebody has unlocked, and
// the screens go dark 5 s after the last key under the lock.
Item {
  id: service

  readonly property string user: Quickshell.env("USER") || Quickshell.env("LOGNAME")
  // greetd's session sets NOVA_LOGIN=password when the greeter has checked a
  // password. Any other start, autologin above all, had nobody sign in.
  readonly property bool autologin: Quickshell.env("NOVA_LOGIN") !== "password"

  // The lock as this shell wants it; session holds the compositor's side.
  property bool wanted: false
  // Waiting for the screens to settle, or for one to show on.
  property bool waiting: false
  // Set while unlock() lets go of the compositor's lock.
  property bool unlocking: false
  readonly property bool locked: wanted || session.locked || session.secure
  readonly property bool authenticating: password.checking || fingerprint.scanning
  property bool previewing: false

  // The last thing that happened, for `nova-shell lock status`.
  property string lastEvent: "init"
  property string lastEventAt: ""

  function note(event) {
    lastEvent = event
    lastEventAt = new Date().toISOString()
    console.log("nova lock " + lastEventAt + " " + event)
  }

  // Screens the lock can show on: one still coming up has no name or size.
  function realScreenCount() {
    return Array.prototype.filter.call(Quickshell.screens || [], function(screen) {
      return screen && screen.name && screen.width > 0 && screen.height > 0
    }).length
  }

  // ---------------------------------------------------------------- locking

  // A lock starts with an empty field and the screens dark in 5 s, and the
  // compositor is asked once the screens have settled. Without the
  // password's PAM file nothing could open it, so none is taken.
  function lockSession() {
    if (!password.pamReady) {
      note("lock-denied: missing-pam")
      return false
    }
    forgetAttempts()
    wanted = true
    blankTimer.arm()
    note("lock-requested")
    waitForScreens()
    Qt.callLater(function() {
      backdrop.run()
      fingerprint.recheck()
    })
    return true
  }

  // Screens come and go around a lid or a dock. The compositor is asked
  // 500 ms after the lock starts, and then only once there is a real screen,
  // looked for every 100 ms and whenever the screens change.
  function waitForScreens() {
    waiting = true
    if (!settling.running) note("lock-pending: screen-stabilizing")
    settling.restart()
    if (!polling.running) polling.start()
  }

  function askCompositor() {
    if (!wanted || session.locked || session.secure || settling.running) return
    if (realScreenCount() > 0) {
      stopWaiting()
      session.locked = true
      return
    }
    if (!waiting || lastEvent !== "lock-pending: no-real-screen") note("lock-pending: no-real-screen")
    waiting = true
    if (!polling.running) polling.start()
  }

  function stopWaiting() {
    waiting = false
    settling.stop()
    polling.stop()
  }

  // What every end of a lock does: nothing left to wait for, to check or
  // to blank.
  function release() {
    wanted = false
    stopWaiting()
    forgetAttempts()
    blankTimer.stop()
  }

  // The compositor's lock goes first. WlSessionLock then reads unlocked but
  // announces only secure=false, which would leave `locked` true and the
  // next lock taken for one already up; `wanted` changing after it makes
  // `locked` look again.
  function unlock() {
    if (!locked) return
    unlocking = true
    session.locked = false
    unlocking = false
    release()
    note("unlocked")
    wake()
  }

  // The compositor ended the lock itself: Hyprland's forced unlock, from a
  // TTY past a broken lock screen, or a lock it refused. The session is open
  // then, so the lock is let go as an unlock would, and whoever needs one
  // (the sleep lock, say) asks again.
  function lockLost() {
    if (!wanted || session.locked || session.secure) return
    note("lock-lost: ended by the compositor")
    release()
    wake()
  }

  // An end of the lock that was not ours. Quickshell lets go of its side
  // only after the signal, so that is looked at a turn later.
  function noticeEnd() {
    if (wanted && !unlocking) Qt.callLater(service.lockLost)
  }

  function forgetAttempts() {
    password.clear()
    fingerprint.stop()
  }

  // ---------------------------------------------------------------- the screens

  // A key or a touch under the lock: the screens come on, and the 5 s to dark
  // start again.
  function wake() {
    waker.run()
    if (wanted) blankTimer.arm()
  }

  Timer {
    id: blankTimer
    interval: 5000
    property double armedAt: 0

    function arm() {
      armedAt = Date.now()
      restart()
    }

    onTriggered: {
      // Run out while the machine slept, it would blank a screen just woken
      // under the user; the wall clock shows the gap, and it starts again.
      if (Date.now() - armedAt > interval + 2000) arm()
      // A password being checked keeps the screen on; the fingerprint's PAM
      // runs all through the lock, so it does not.
      else if (service.wanted && !password.checking) blanker.run()
    }
  }

  Timer {
    id: settling
    interval: 500
    onTriggered: service.askCompositor()
  }

  Timer {
    id: polling
    interval: 100
    repeat: true
    onTriggered: service.askCompositor()
  }

  Connections {
    target: Quickshell
    function onScreensChanged() {
      service.askCompositor()
      // A screen still coming up has no workspace yet, so the stranded lock
      // question starts its count again.
      strandedRetry.rearm()
      boot.askStranded()
    }
  }

  WlSessionLock {
    id: session
    locked: false

    onSecureStateChanged: {
      service.note("secure=" + secure)
      if (!secure) {
        service.noticeEnd()
        return
      }
      service.stopWaiting()
      fingerprint.scan()
      // Whichever lock comes first in a boot (the autologin one, a stranded
      // lock taken back, one over IPC) ends the boot submap.
      if (boot.holding || !boot.unlockedOnce) boot.leaveSubmap()
    }

    // Quickshell 0.3.2 announces only a lock taken; an end comes as
    // secure=false.
    onLockStateChanged: {
      service.note("session-locked=" + locked)
      if (locked) service.stopWaiting()
      else service.noticeEnd()
    }

    WlSessionLockSurface {
      color: Commons.Color.background

      LockView {
        anchors.fill: parent
        backgroundPath: backdrop.path
        backgroundVersion: backdrop.version
        loadBackground: service.locked
        fingerprintConfigured: fingerprint.enrolled && boot.unlockedOnce
        inputEnabled: service.wanted
        authenticatingPassword: password.checking
        failureMessage: password.failure
        passwordText: password.typed
        onPasswordTextEdited: function(text) { password.typed = text }
        onSubmitPassword: function(text) { password.submit(text) }
        onClearFailureRequested: password.failure = ""
        onWakeRequested: service.wake()
      }
    }
  }

  // The lock screen as it looks, for `nova-shell lock preview`, over
  // everything until a click.
  PanelWindow {
    visible: service.previewing
    color: "transparent"
    anchors { top: true; right: true; bottom: true; left: true }
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "nova-lock-preview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    LockView {
      anchors.fill: parent
      backgroundPath: backdrop.path
      backgroundVersion: backdrop.version
      loadBackground: service.previewing
      fingerprintConfigured: fingerprint.enrolled
      inputEnabled: false
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: service.previewing = false
    }
  }

  // ---------------------------------------------------------------- password

  // What the field holds, what PAM is being given, and how the last try went.
  QtObject {
    id: password

    // Whether /etc/pam.d/nova-lock-password is there.
    property bool pamReady: false
    property string typed: ""
    property string given: ""
    property bool checking: false
    property string failure: ""
    property int failures: 0

    function clear() {
      typed = ""
      given = ""
      failure = ""
      failures = 0
      checking = false
      watchdog.stop()
      if (passwordPam.active) passwordPam.abort()
    }

    function submit(text) {
      var value = String(text || "")
      if (!service.wanted || checking || !value) return
      service.wake()
      given = value
      failure = ""
      checking = true
      if (passwordPam.start()) {
        watchdog.restart()
        Qt.callLater(answer)
      } else {
        fail()
      }
    }

    // PAM's prompt, answered with the password while one is being checked.
    function answer() {
      if (checking && passwordPam.active && passwordPam.responseRequired) passwordPam.respond(given)
    }

    // An attempt a reset or the watchdog has settled is over already.
    function checked(result) {
      if (!checking) return
      watchdog.stop()
      checking = false
      given = ""
      if (!service.wanted) return
      if (result === PamResult.Success) {
        if (!boot.unlockedOnce) boot.firstUnlock()
        service.unlock()
      } else {
        fail()
      }
    }

    function fail() {
      if (!service.wanted) return
      watchdog.stop()
      checking = false
      typed = ""
      given = ""
      failures += 1
      failure = "Authentication failed (" + failures + ")"
      service.wake()
    }

    // The screens stay on while a password is checked.
    onCheckingChanged: {
      if (!service.wanted) return
      if (checking) blankTimer.stop()
      else blankTimer.arm()
    }

    // No lock before PAM is known good. A stranded-lock answer from before
    // may be stale (the failsafe can be cleared from a TTY), so the question
    // is asked again.
    onPamReadyChanged: {
      if (!pamReady) return
      boot.lockForAutologin()
      boot.stranded = false
      boot.answered = false
      strandedRetry.rearm()
      boot.askStranded()
    }
  }

  PamContext {
    id: passwordPam
    config: "nova-lock-password"
    user: service.user

    onResponseRequiredChanged: password.answer()
    onPamMessage: password.answer()
    // An error is followed by completed(PamResult.Error): every outcome ends
    // here.
    onCompleted: function(result) { password.checked(result) }
  }

  // A module that never answers (a stuck keyring daemon, say) would leave
  // the field at "Checking…" for the rest of the lock, and abort() emits
  // nothing, so the attempt is failed here.
  Timer {
    id: watchdog
    interval: 20000
    onTriggered: {
      if (!password.checking) return
      service.note("password: PAM did not answer")
      if (passwordPam.active) passwordPam.abort()
      password.fail()
    }
  }

  // ---------------------------------------------------------------- fingerprint

  QtObject {
    id: fingerprint

    // Its PAM file is there and fprintd has a finger enrolled for this user.
    property bool enrolled: false
    property bool scanning: false
    property double startedAt: 0
    property int quickFailures: 0

    function recheck() {
      enrolment.run()
    }

    // Only under a lock the compositor holds, and after the boot's first
    // unlock: that one takes the password, which opens the keyring too.
    function scan() {
      if (!service.wanted || !session.secure || !enrolled || !boot.unlockedOnce) return
      if (fingerprintPam.active || scanning) return
      scanning = true
      startedAt = Date.now()
      if (!fingerprintPam.start()) scanning = false
    }

    function scanned(result) {
      scanning = false
      if (!service.wanted) return
      if (result === PamResult.Success) service.unlock()
      else scanAgain()
    }

    // A finger that does not match takes seconds to say so; pam_fprintd fails
    // at once while the reader is gone or fprintd is down, just after a
    // resume say. Failures that quick wait longer each time, from 250 ms to
    // 30 s.
    function scanAgain() {
      if (!service.wanted || !enrolled) return
      quickFailures = Date.now() - startedAt < 1000 ? quickFailures + 1 : 0
      rescan.interval = Math.min(250 * Math.pow(2, quickFailures), 30000)
      rescan.restart()
    }

    // abort() says nothing, so the scan is marked over here; a finger
    // enrolled again under the same lock then starts without the old wait.
    function stop() {
      rescan.stop()
      if (fingerprintPam.active) fingerprintPam.abort()
      scanning = false
      quickFailures = 0
    }
  }

  PamContext {
    id: fingerprintPam
    config: "nova-lock-fingerprint"
    user: service.user

    onCompleted: function(result) { fingerprint.scanned(result) }
  }

  Timer {
    id: rescan
    interval: 250
    onTriggered: fingerprint.scan()
  }

  // A command run once at a time: asked again while it runs, it is not
  // started twice.
  component Command: Process {
    function run() {
      if (!running) running = true
    }
  }

  // The lock shows the desktop's background, read through its link; a new
  // file at the same path counts as new.
  Command {
    id: backdrop
    property string path: ""
    property int version: 0
    command: ["readlink", "-f", Commons.Color.stateHome + "/nova/current/background"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var target = String(text || "").trim()
        if (target === backdrop.path) return
        backdrop.path = target
        backdrop.version += 1
      }
    }
  }

  Command {
    id: enrolment
    command: ["bash", "-c", "[[ -f /etc/pam.d/nova-lock-fingerprint ]] && command -v fprintd-list >/dev/null && fprintd-list \"$USER\" 2>/dev/null | grep -qE '^ *- #[0-9]+: '"]
    onExited: function(exitCode) {
      fingerprint.enrolled = exitCode === 0
      if (!fingerprint.enrolled) fingerprint.stop()
      else if (service.wanted) fingerprint.scan()
    }
  }

  // ---------------------------------------------------------------- the boot

  QtObject {
    id: boot

    // The boot's first unlock takes the password, so it opens the keyring
    // too; a password login at the greeter was that unlock. The runtime
    // directory keeps it for a shell started again.
    property bool unlockedOnce: !service.autologin
    property bool known: false
    // The autologin lock, until it is secure and the boot submap can go.
    property bool holding: false
    // A lock a crashed shell left behind, and whether that is answered yet.
    property bool stranded: false
    property bool answered: false

    function lockForAutologin() {
      if (!service.autologin || !known || unlockedOnce || !password.pamReady || service.locked) return
      service.note("lock-autologin")
      holding = service.lockSession()
    }

    // Hyprland starts an autologin session in a submap with no binds, so no
    // key works before the lock is up; once it is secure, Hyprland allows
    // only the binds marked for the lock screen.
    function leaveSubmap() {
      holding = false
      Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.submap(\"reset\")"])
    }

    // nova-session-first-unlock notes it and starts nova-unlocked.target. The
    // password stays inside PAM: pam_gnome_keyring in nova-lock-password has
    // opened the login keyring with it already.
    function firstUnlock() {
      unlockedOnce = true
      firstUnlockRun.run()
    }

    // ext-session-lock outlives its client and a shell started again holds
    // no lock, so a session locked this early may be an orphan behind
    // Hyprland's failsafe screen. It may also be another shell's live lock,
    // which Hyprland would let this one take over and strand on exit, so
    // the helper answers "cannot tell" while another locker runs or no output
    // is up, and is asked until it can.
    function askStranded() {
      if (answered || strandedCheck.running) return
      // A lock this shell took is nobody's orphan.
      if (service.locked) answered = true
      else strandedCheck.running = true
    }

    function takeBack() {
      if (!stranded || service.locked || !password.pamReady) return
      stranded = false
      service.note("lock-stranded: recovering")
      service.lockSession()
    }
  }

  Process {
    id: strandedCheck
    // bash's parent is this shell, the pid the helper leaves out: a shell
    // that crashed starts again in the same process.
    command: ["bash", "-c", "nova-hyprland-session-lock-stranded \"$PPID\""]
    onExited: function(exitCode) {
      // 2: it cannot tell yet.
      if (exitCode === 2) return
      // A lock taken while the helper ran is this shell's own.
      boot.stranded = exitCode === 0 && !service.locked
      boot.takeBack()
      // Answered only once a stranded lock is taken back, so the moment
      // between never reads as an open session.
      boot.answered = true
    }
  }

  Command {
    id: firstUnlockRun
    command: ["nova-session-first-unlock"]
    onExited: function(exitCode) {
      if (exitCode !== 0) service.note("first-unlock: helper exited " + exitCode)
    }
  }

  FileView {
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/nova/unlocked-once"
    printErrors: false
    onLoaded: {
      boot.unlockedOnce = true
      boot.known = true
    }
    onLoadFailed: {
      boot.known = true
      boot.lockForAutologin()
    }
  }

  // Removable drives mount only in a session somebody has unlocked: never
  // under the lock, not before the boot's first unlock, and not while a lock
  // a crashed shell may have left is unanswered. One nova-automount runs at
  // a time; a change while it runs is applied after.
  Process {
    id: automount
    readonly property bool allowed: !service.locked && boot.unlockedOnce && boot.answered
    // What the run under way was asked.
    property bool asked: false

    function apply() {
      if (running) return
      asked = allowed
      command = ["nova-automount", allowed ? "on" : "off"]
      running = true
    }

    onAllowedChanged: apply()
    onExited: if (asked !== allowed) apply()
  }

  Command {
    id: waker
    command: ["nova-system-wake"]
  }

  Command {
    id: blanker
    command: ["bash", "-c", "nova-brightness-keyboard off; nova-brightness-display off"]
  }

  // The stranded-lock question, every 500 ms and 20 times at most while the
  // compositor settles; screens coming back start the count again.
  Timer {
    id: strandedRetry
    interval: 500
    repeat: true
    property int left: 20
    running: !boot.answered && left > 0

    function rearm() {
      if (!boot.answered) left = 20
    }

    onTriggered: {
      left -= 1
      boot.askStranded()
    }
  }

  FileView {
    path: "/etc/pam.d/nova-lock-password"
    watchChanges: true
    printErrors: false
    onLoaded: password.pamReady = true
    onLoadFailed: password.pamReady = false
    onFileChanged: reload()
  }

  Component.onCompleted: {
    backdrop.run()
    fingerprint.recheck()
    boot.askStranded()
    automount.apply()
  }

  IpcHandler {
    target: "lock"

    function lock(): string {
      if (!password.pamReady) return "missing-pam"
      if (!service.locked) service.lockSession()
      return "ok"
    }

    function isLocked(): string {
      return service.locked ? "true" : "false"
    }

    // Read by nova-session-guard: "secure" once the compositor confirms the
    // lock, "unlocked" after a real unlock, "starting" until one of those.
    function state(): string {
      if (session.secure) return "secure"
      return !service.locked && boot.unlockedOnce ? "unlocked" : "starting"
    }

    function status(): string {
      return JSON.stringify({
        locked: service.locked,
        requested: service.wanted,
        pending: service.waiting,
        sessionLocked: session.locked,
        secure: session.secure,
        realScreens: service.realScreenCount(),
        passwordPam: password.pamReady,
        fingerprint: fingerprint.enrolled,
        unlockedOnce: boot.unlockedOnce,
        authenticating: service.authenticating,
        lastEvent: service.lastEvent,
        lastEventAt: service.lastEventAt
      })
    }

    function preview(): string {
      backdrop.run()
      fingerprint.recheck()
      service.previewing = true
      return "ok"
    }

    function hidePreview(): string {
      service.previewing = false
      return "ok"
    }
  }
}
