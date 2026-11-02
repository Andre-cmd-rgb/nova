import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import "../NotificationLogic.js" as NotificationLogic

// One screen's toasts, newest at the top, in its top right corner below the
// bar or beside it. The window covers the screen and never changes size, so
// the compositor never stretches an old frame as toasts come and go; it takes
// no keys, and the pointer only over the toasts.
PanelWindow {
  id: window

  required property var notifications

  // The bar's room, on the edge it is on: its size as shown, or as set when
  // it is hidden or not there, and the gap.
  readonly property var shell: notifications.shell
  readonly property string barPosition: shell && shell.barConfig ? String(shell.barConfig.position || "top") : "top"
  readonly property int barSize: shell && shell.bar && !shell.bar.barHidden ? Math.max(0, shell.bar.barSize)
    : barPosition === "left" || barPosition === "right" ? Style.bar.sizeVertical : Style.bar.sizeHorizontal
  readonly property int clearance: barSize + Style.gapsOut
  readonly property var inset: NotificationLogic.margins(barPosition, clearance, Style.gapsOut)

  visible: notifications.toasts.count > 0
  WlrLayershell.namespace: "nova-notifications"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
  exclusionMode: ExclusionMode.Ignore
  color: "transparent"
  anchors { top: true; bottom: true; left: true; right: true }
  mask: Region { item: column }

  ColumnLayout {
    id: column
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.topMargin: window.inset.top
    anchors.rightMargin: window.inset.right
    spacing: Style.space(8)

    Repeater {
      model: window.notifications.toasts

      // A toast and its lifetime. It counts down in one timer for what is
      // left, stopped while the pointer is on the toast on any screen, and
      // starts over when its sender changes what it says.
      delegate: Item {
        id: toast

        required property int index
        required property string app
        required property string appIcon
        required property string summary
        required property string body
        required property string image
        required property string glyph
        required property int urgency
        required property double expireTimeout
        required property double timestamp
        required property int originalId

        readonly property string stem: NotificationLogic.stem(toast)
        readonly property real lifetime: NotificationLogic.lifetime(urgency, expireTimeout)
        readonly property bool ticking: lifetime > 0 && !window.notifications.held[stem]
        // The share of the lifetime left, and when the timer last started.
        property real remaining: 1.0
        property real since: 0
        // A toast that goes with the pointer on it lets go of it.
        property bool pointed: false

        Layout.preferredWidth: card.implicitWidth
        Layout.alignment: Qt.AlignRight
        implicitHeight: card.implicitHeight

        function pause() {
          if (!expiry.running) return
          expiry.stop()
          if (lifetime > 0) remaining = Math.max(0, remaining - (Date.now() - since) / lifetime)
        }

        function run() {
          expiry.stop()
          if (!ticking) return
          since = Date.now()
          expiry.interval = Math.max(1, Math.round(remaining * lifetime))
          expiry.start()
        }

        function again() {
          remaining = 1.0
          run()
        }

        onTickingChanged: ticking ? run() : pause()
        onLifetimeChanged: {
          pause()
          run()
        }
        onSummaryChanged: again()
        onBodyChanged: again()
        onImageChanged: again()
        Component.onCompleted: run()
        Component.onDestruction: if (pointed) window.notifications.hold(stem, false)

        Timer {
          id: expiry
          onTriggered: {
            toast.remaining = 0
            window.notifications.expire(toast.index)
          }
        }

        ToastCard {
          id: card
          anchors.right: parent.right
          app: toast.app
          appIcon: toast.appIcon
          summary: toast.summary
          body: toast.body
          image: toast.image
          glyph: toast.glyph
          cornerRadius: Style.cornerRadius
          fontFamily: window.shell && window.shell.bar ? window.shell.bar.fontFamily : ""
          onHoveredChanged: {
            toast.pointed = hovered
            window.notifications.hold(toast.stem, hovered)
          }
          onClicked: window.notifications.invoke(toast.index)
          onDismissed: window.notifications.dismiss(toast.index)
        }
      }
    }
  }
}
