import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// An account: added (iCloud, Google, another CalDAV server, or a
// subscription to an iCal link), then the calendars it found, each shown or
// not; or one already there, synced now or removed. The password goes to
// nova-calendar-sync on its stdin, and from there to the keyring.
Sheet {
  id: sheet

  required property var calendar

  readonly property var store: calendar.store
  // "add", "found" (what adding found), or "account".
  property string mode: "add"
  property string type: "icloud"
  property var account: null
  property var found: []
  property string error: ""
  property bool confirming: false
  readonly property bool busy: store !== null && store.adding

  cardWidth: Style.space(460)
  onCanceled: close()

  function add() {
    mode = "add"
    account = null
    error = ""
    confirming = false
    appleId.text = applePassword.text = server.text = user.text = password.text = address.text = ""
    if (store) store.checkGoogle()
    opened = true
    Qt.callLater(focusFirst)
  }

  function manage(a) {
    mode = "account"
    account = a
    error = ""
    confirming = false
    opened = true
  }

  function close() {
    if (busy) store.cancelAdding()
    applePassword.text = password.text = ""
    opened = false
  }

  function focusFirst() {
    if (type === "icloud") appleId.forceActiveFocus()
    else if (type === "caldav") server.forceActiveFocus()
    else if (type === "subscription") address.forceActiveFocus()
  }

  function submit() {
    if (busy || !store) return
    error = ""
    var request
    if (type === "icloud") request = { type: "icloud", user: appleId.text.trim(), password: applePassword.text.replace(/\s+/g, "") }
    else if (type === "caldav") request = { type: "caldav", url: server.text.trim(), user: user.text.trim(), password: password.text }
    else if (type === "google") request = { type: "google" }
    else request = { type: "subscription", url: address.text.trim() }
    if ((type === "icloud" || type === "caldav") && (!request.user || !request.password)) {
      error = type === "icloud" ? "The Apple ID and an app-specific password are needed." : "A user name and a password are needed."
      return
    }
    if ((type === "caldav" || type === "subscription") && !request.url) {
      error = "An address is needed."
      return
    }
    store.addAccount(request)
  }

  Connections {
    target: sheet.store
    function onAdded(result) {
      if (!sheet.opened) return
      applePassword.text = password.text = ""
      sheet.account = result.account || null
      sheet.found = (result.calendars || (result.calendar ? [result.calendar] : [])).map(function (c) { return c.id })
      sheet.mode = "found"
    }
    function onFailed(words) {
      if (sheet.opened) sheet.error = words
    }
  }

  Keys.onReturnPressed: if (mode === "add") submit(); else if (mode === "found") close()
  Keys.onEnterPressed: if (mode === "add") submit(); else if (mode === "found") close()

  component FieldLabel: Text {
    width: Style.space(100)
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    color: Commons.Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }

  component Field: Row {
    property alias label: fieldLabel.text
    property alias input: input
    property alias text: input.text
    property alias placeholderText: input.placeholderText
    property bool secret: false
    spacing: Style.space(8)
    FieldLabel { id: fieldLabel }
    TextField {
      id: input
      width: Style.space(270)
      echoMode: parent.secret ? TextInput.Password : TextInput.Normal
      enabled: !sheet.busy
    }
  }

  // ---- adding

  Text {
    visible: sheet.mode === "add"
    text: "Add Account"
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.heading
    font.bold: true
  }

  ButtonGroup {
    visible: sheet.mode === "add"
    options: [{ value: "icloud", label: "iCloud" }, { value: "google", label: "Google" }, { value: "caldav", label: "CalDAV" }, { value: "subscription", label: "Subscription" }]
    value: sheet.type
    tabStop: false
    onChanged: function (value) {
      if (sheet.busy) return
      sheet.type = value
      sheet.error = ""
      Qt.callLater(sheet.focusFirst)
    }
  }

  Field {
    id: appleIdRow
    visible: sheet.mode === "add" && sheet.type === "icloud"
    label: "Apple ID"
    placeholderText: "name@icloud.com"
  }
  Field {
    id: applePasswordRow
    visible: sheet.mode === "add" && sheet.type === "icloud"
    label: "Password"
    placeholderText: "App-specific password"
    secret: true
  }
  Row {
    visible: sheet.mode === "add" && sheet.type === "icloud"
    spacing: Style.space(8)
    Item { width: Style.space(100); height: 1 }
    Button {
      text: "Make an App-Specific Password"
      fontSize: Style.font.bodySmall
      foreground: Commons.Color.accent
      onClicked: Quickshell.execDetached(["xdg-open", "https://account.apple.com/account/manage"])
    }
  }

  Text {
    visible: sheet.mode === "add" && sheet.type === "google"
    width: parent.width
    text: !sheet.store || sheet.store.googleReady ? (sheet.busy ? "Continue in the browser." : "Sign in with Google in the browser.") : "Google sign-in is not set up on this computer."
    color: sheet.store && !sheet.store.googleReady ? Commons.Color.urgent : Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    wrapMode: Text.Wrap
  }

  Field {
    id: serverRow
    visible: sheet.mode === "add" && sheet.type === "caldav"
    label: "Server"
    placeholderText: "https://caldav.example.com"
  }
  Field {
    id: userRow
    visible: sheet.mode === "add" && sheet.type === "caldav"
    label: "User name"
  }
  Field {
    id: passwordRow
    visible: sheet.mode === "add" && sheet.type === "caldav"
    label: "Password"
    secret: true
  }

  Field {
    id: addressRow
    visible: sheet.mode === "add" && sheet.type === "subscription"
    label: "Address"
    placeholderText: "webcal://example.com/calendar.ics"
  }

  // ---- what adding found, or an account already there

  Text {
    visible: sheet.mode !== "add"
    width: parent.width
    text: sheet.mode === "found" && sheet.type === "subscription" ? "Subscribed" : (sheet.account ? sheet.account.name : "")
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.heading
    font.bold: true
    elide: Text.ElideRight
    textFormat: Text.PlainText
  }
  Text {
    visible: sheet.mode === "account" && sheet.account !== null
    width: parent.width
    text: sheet.account ? [sheet.account.user, sheet.account.type === "caldav" ? sheet.account.url : ""].filter(function (s) { return s && s !== sheet.account.name }).join(" · ") : ""
    color: Commons.Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideMiddle
    textFormat: Text.PlainText
  }
  Text {
    readonly property string words: sheet.account && sheet.mode === "account" && sheet.store ? sheet.store.stateWords(sheet.account.id) : ""
    visible: words !== ""
    width: parent.width
    text: words
    color: Commons.Color.urgent
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
  }

  Column {
    visible: sheet.mode !== "add"
    width: parent.width
    spacing: Style.space(2)

    Repeater {
      model: !sheet.store ? [] : sheet.store.list.filter(function (c) {
        return sheet.mode === "found" ? sheet.found.indexOf(c.id) >= 0 : sheet.account !== null && c.account === sheet.account.id
      })

      Item {
        id: row
        required property var modelData
        readonly property color hue: Commons.Color.hue(modelData.color)
        width: parent.width
        height: Style.space(30)

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius > 0 ? Style.space(4) : 0
          color: rowHover.hovered ? Style.hoverFill : "transparent"
        }
        HoverHandler { id: rowHover }
        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: sheet.store.setCalendar(row.modelData.id, "shown", !row.modelData.shown)
        }
        Rectangle {
          id: box
          x: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(16)
          height: width
          radius: Style.cornerRadius > 0 ? Style.space(4) : 0
          color: row.modelData.shown ? row.hue : "transparent"
          border.width: Style.space(2)
          border.color: row.hue
          Text {
            anchors.centerIn: parent
            visible: row.modelData.shown
            text: "󰄬"
            color: Commons.Color.background
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
        Text {
          anchors.left: box.right
          anchors.leftMargin: Style.space(10)
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          text: row.modelData.name + (row.modelData.readOnly && row.modelData.kind !== "subscription" ? "  (read-only)" : "")
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          textFormat: Text.PlainText
        }
      }
    }
  }

  Text {
    visible: sheet.error !== "" || (sheet.busy && sheet.type !== "google")
    width: parent.width
    text: sheet.error !== "" ? sheet.error : (sheet.type === "subscription" ? "Subscribing…" : "Signing in…")
    color: sheet.error !== "" ? Commons.Color.urgent : Commons.Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
    wrapMode: Text.Wrap
    textFormat: Text.PlainText
  }

  // Remove this account?
  Text {
    visible: sheet.confirming
    width: parent.width
    text: "Remove this account from this computer?"
    color: Commons.Color.foreground
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    wrapMode: Text.Wrap
  }

  Item {
    width: parent.width
    height: doneButton.implicitHeight

    Button {
      visible: sheet.mode === "account"
      anchors.left: parent.left
      text: sheet.confirming ? "Remove" : "Remove Account"
      foreground: Commons.Color.urgent
      bordered: true
      selected: sheet.confirming
      onClicked: {
        if (!sheet.confirming) {
          sheet.confirming = true
          return
        }
        sheet.store.remove(sheet.account.id)
        sheet.close()
      }
    }
    Row {
      anchors.right: parent.right
      spacing: Style.space(8)
      Button {
        visible: sheet.mode === "add" || sheet.confirming
        text: "Cancel"
        bordered: true
        onClicked: sheet.confirming ? sheet.confirming = false : sheet.close()
      }
      Button {
        visible: sheet.mode === "account" && !sheet.confirming
        text: "Sync Now"
        bordered: true
        enabled: sheet.store !== null && !sheet.store.syncing
        onClicked: sheet.store.sync()
      }
      Button {
        id: doneButton
        visible: !sheet.confirming
        enabled: sheet.mode !== "add" || (!sheet.busy && (sheet.type !== "google" || (sheet.store && sheet.store.googleReady)))
        text: sheet.mode === "add" ? (sheet.type === "subscription" ? "Subscribe" : "Sign In") : "Done"
        bordered: true
        selected: true
        onClicked: sheet.mode === "add" ? sheet.submit() : sheet.close()
      }
    }
  }

  property alias appleId: appleIdRow.input
  property alias applePassword: applePasswordRow.input
  property alias server: serverRow.input
  property alias user: userRow.input
  property alias password: passwordRow.input
  property alias address: addressRow.input
}
