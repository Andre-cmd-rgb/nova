// The login greeter: the lock screen's view on every output, driving greetd.
// nova-greeter-session runs it as the `greeter` user on a minimal Hyprland,
// with the theme mirror in NOVA_THEME_DIR and the account in NOVA_GREETER_USER.
// It touches NOVA_GREETER_READY once its windows exist, and exits 0 only after
// greetd has accepted the session it launched.

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
  property string pendingPassword: ""
  property bool authenticating: false
  property string failureMessage: root.user ? "" : "No user to log in"
  property int failedAttempts: 0
  // PAM's own explanation of a failure ("account locked"), shown instead of
  // the generic message when there is one.
  property string pamError: ""

  function submit(password) {
    if (authenticating || !user || Greetd.state !== GreetdState.Inactive) return
    pendingPassword = password
    pamError = ""
    failureMessage = ""
    authenticating = true
    Greetd.createSession(user)
  }

  function fail(message) {
    pendingPassword = ""
    authenticating = false
    failedAttempts += 1
    failureMessage = pamError || message
    if (Greetd.state !== GreetdState.Inactive) Greetd.cancelSession()
  }

  Connections {
    target: Greetd

    function onAuthMessage(message, error, responseRequired, echoResponse) {
      if (error) root.pamError = message
      if (!responseRequired) return
      // The password is the only answer the greeter has. A second prompt (an
      // expired password, a one-time code) is for the console login.
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

    // NOVA_LOGIN=password tells the session that greetd checked a password,
    // so it starts unlocked and counts this as the first unlock.
    function onReadyToLaunch() {
      Greetd.launch(["uwsm", "start", "-e", "-D", "Hyprland", "hyprland.desktop"], ["NOVA_LOGIN=password"], true)
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property ShellScreen modelData

      screen: modelData
      anchors { top: true; bottom: true; left: true; right: true }
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
        failedAttempts: root.failedAttempts
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
