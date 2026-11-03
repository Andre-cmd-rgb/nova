// The login screen: the lock screen's view on every output, logging in
// through greetd. nova-greeter-session runs it as the `greeter` user on a
// Hyprland of its own, with the theme's copy in NOVA_THEME_DIR and the
// account to log in to in NOVA_GREETER_USER. It touches NOVA_GREETER_READY
// once its windows exist, and exits with 0 only once greetd has taken the
// session it launched.

import QtQuick
import Quickshell
import Quickshell.Services.Greetd
import Quickshell.Wayland

import qs.Commons as Commons

import "plugins/lock"

ShellRoot {
  id: root

  readonly property string user: Quickshell.env("NOVA_GREETER_USER") || ""
  readonly property string themeDir: Quickshell.env("NOVA_THEME_DIR") || "/var/lib/nova/greeter"
  readonly property string readyFile: Quickshell.env("NOVA_GREETER_READY") || ""

  property string passwordText: ""
  // The password sent, held until greetd asks for it.
  property string pendingPassword: ""
  property bool authenticating: false
  property string failureMessage: user ? "" : "No user to log in"
  property int failedAttempts: 0
  // PAM's own reason for a failure ("account locked"), shown in place of
  // the greeter's when it gave one.
  property string pamError: ""

  // Starts a login with <password>, unless one is under way, greetd is busy
  // or there is no account.
  function submit(password) {
    if (authenticating || !user || Greetd.state !== GreetdState.Inactive) return
    pendingPassword = password
    pamError = ""
    failureMessage = ""
    authenticating = true
    Greetd.createSession(user)
  }

  // Ends the login under way, showing <message> unless PAM gave a reason.
  function fail(message) {
    pendingPassword = ""
    authenticating = false
    failedAttempts++
    failureMessage = pamError || message
    if (Greetd.state !== GreetdState.Inactive) Greetd.cancelSession()
  }

  Connections {
    target: Greetd

    function onAuthMessage(message, error, responseRequired, echoResponse) {
      if (error) root.pamError = message
      if (!responseRequired) return
      // The password is the one answer the greeter has. A second question,
      // for an expired password or a one-time code, is the console's to ask.
      if (root.pendingPassword === "") {
        root.fail(message || "Log in on the console")
        return
      }
      Greetd.respond(root.pendingPassword)
      root.pendingPassword = ""
    }

    function onAuthFailure(message) {
      root.fail("Wrong password")
    }

    function onError(error) {
      root.fail("Login failed")
    }

    // NOVA_LOGIN=password tells the session that greetd has checked a
    // password, so that it starts unlocked and takes this for its first
    // unlock; UWSM_SILENT_START=1 keeps uwsm's start-up report off the
    // console.
    function onReadyToLaunch() {
      Greetd.launch(["uwsm", "start", "-e", "-D", "Hyprland", "hyprland.desktop"], ["NOVA_LOGIN=password", "UWSM_SILENT_START=1"], true)
    }
  }

  // A full-screen window over everything on each output, taking the
  // keyboard.
  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property ShellScreen modelData

      screen: modelData
      anchors {
        top: true
        bottom: true
        left: true
        right: true
      }
      exclusionMode: ExclusionMode.Ignore
      color: Commons.Color.background
      WlrLayershell.namespace: "nova-greeter"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

      LockView {
        anchors.fill: parent
        backgroundPath: root.themeDir + "/background"
        authenticatingPassword: root.authenticating
        failureMessage: root.failureMessage
        inputEnabled: root.user !== ""
        passwordText: root.passwordText
        onPasswordTextEdited: function(password) { root.passwordText = password }
        onSubmitPassword: function(password) { root.submit(password) }
        onClearFailureRequested: root.failureMessage = ""
      }
    }
  }

  Component.onCompleted: {
    if (readyFile) Quickshell.execDetached(["touch", readyFile])
  }
}
