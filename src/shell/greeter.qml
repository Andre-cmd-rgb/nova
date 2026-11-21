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
  id: greeter

  readonly property string user: Quickshell.env("NOVA_GREETER_USER") || ""
  readonly property string themeDir: Quickshell.env("NOVA_THEME_DIR") || "/var/lib/nova/greeter"
  readonly property string readyFile: Quickshell.env("NOVA_GREETER_READY") || ""

  // The field as typed; the password handed over, kept until greetd asks
  // for it; whether a login is under way, and why the last one failed.
  property string typed: ""
  property string held: ""
  property bool checking: false
  property string failure: user ? "" : "No user to log in"
  // PAM's own reason for a failure ("account locked"), which is shown in
  // place of the greeter's when there is one.
  property string pamSaid: ""

  // A login with <password>, unless one is under way, greetd is busy or
  // there is no account to log in to.
  function logIn(password) {
    if (checking || !user || Greetd.state !== GreetdState.Inactive) return
    held = password
    pamSaid = ""
    failure = ""
    checking = true
    Greetd.createSession(user)
  }

  // The login under way ends, with <why> unless PAM said why itself.
  function refuse(why) {
    held = ""
    checking = false
    failure = pamSaid || why
    if (Greetd.state !== GreetdState.Inactive) Greetd.cancelSession()
  }

  Connections {
    target: Greetd

    function onAuthMessage(message, error, responseRequired, echoResponse) {
      if (error) greeter.pamSaid = message
      if (!responseRequired) return
      // The password is the greeter's only answer. A second question, for a
      // password expired or a one-time code, is for the console to ask.
      if (greeter.held === "") {
        greeter.refuse(message || "Log in on the console")
        return
      }
      Greetd.respond(greeter.held)
      greeter.held = ""
    }

    function onAuthFailure(message) {
      greeter.refuse("Wrong password")
    }

    function onError(error) {
      greeter.refuse("Login failed")
    }

    // NOVA_LOGIN=password tells the session that greetd checked a password,
    // so it starts unlocked and counts this as the boot's first unlock;
    // nova-session-start keeps uwsm's own words off the console.
    function onReadyToLaunch() {
      Greetd.launch(["/usr/lib/nova/bin/nova-session-start"], ["NOVA_LOGIN=password"], true)
    }
  }

  // On each output, a window over everything that takes the keyboard.
  Variants {
    model: Quickshell.screens

    PanelWindow {
      required property ShellScreen modelData

      screen: modelData
      anchors { left: true; right: true; top: true; bottom: true }
      exclusionMode: ExclusionMode.Ignore
      // Black under the view, as Hyprland's own screen before it: the view
      // draws nothing until its picture is ready, then fades it in.
      color: "black"
      WlrLayershell.namespace: "nova-greeter"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

      LockView {
        anchors.fill: parent
        backdrop: greeter.themeDir + "/backdrop.ppm"
        picture: greeter.themeDir + "/background"
        fadeIn: true
        takesInput: greeter.user !== ""
        typed: greeter.typed
        checking: greeter.checking
        failure: greeter.failure
        onEdited: text => greeter.typed = text
        onSubmitted: text => greeter.logIn(text)
        onFailureSeen: greeter.failure = ""
      }
    }
  }

  Component.onCompleted: {
    if (readyFile) Quickshell.execDetached(["touch", readyFile])
  }
}
