import Quickshell
import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell.Services.SystemTray
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// The system tray. Pinned icons always show; the rest wait in a drawer behind
// a chevron, which slides open while the pointer is on it. A right click on
// the chevron lists every icon to pin or hide; on an icon, it opens the icon's
// menu, drawn here with its submenus.
BarWidget {
  id: root
  moduleName: "nova.tray"

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ----- icons -----

  // The ids pinned and hidden in the widget's settings.
  readonly property var pinnedIds: settings.pinned instanceof Array ? settings.pinned : []
  readonly property var hiddenIds: settings.hidden instanceof Array ? settings.hidden : []

  // Every icon shown somewhere, and those pinned, and those in the drawer.
  readonly property var allItems: {
    var items = SystemTray.items.values
    var shown = []
    for (var i = 0; i < items.length; i++) {
      if (items[i].status !== Status.Passive && !ownedByNova(items[i])) shown.push(items[i])
    }
    return shown
  }
  readonly property var pinnedItems: allItems.filter(function(item) { return placeOf(item) === "pinned" })
  readonly property var drawerItems: allItems.filter(function(item) { return placeOf(item) === "drawer" })

  // LocalSend's icon shows nothing, its menu has only Open and Quit, and a
  // click on it does nothing: Share > Receive does all of it. It cannot be
  // hidden by hand either, as it takes a new id each time it starts.
  function ownedByNova(item) {
    return [item.id, item.title, item.tooltipTitle].some(function(name) {
      return String(name || "").toLowerCase().indexOf("localsend") !== -1
    })
  }

  function placeOf(item) {
    var id = String(item.id || "")
    if (hiddenIds.indexOf(id) !== -1) return "hidden"
    if (pinnedIds.indexOf(id) !== -1) return "pinned"
    return "drawer"
  }

  // Pinning an icon shows it again if it was hidden, and hiding one unpins
  // it.
  function togglePin(id) {
    var pinned = pinnedIds.slice()
    var hidden = hiddenIds.slice()
    if (pinned.indexOf(id) !== -1) {
      pinned.splice(pinned.indexOf(id), 1)
    } else {
      pinned.push(id)
      if (hidden.indexOf(id) !== -1) hidden.splice(hidden.indexOf(id), 1)
    }
    save(pinned, hidden)
  }

  function toggleHide(id) {
    var pinned = pinnedIds.slice()
    var hidden = hiddenIds.slice()
    if (hidden.indexOf(id) !== -1) {
      hidden.splice(hidden.indexOf(id), 1)
    } else {
      hidden.push(id)
      if (pinned.indexOf(id) !== -1) pinned.splice(pinned.indexOf(id), 1)
    }
    save(pinned, hidden)
  }

  function save(pinned, hidden) {
    if (!bar || !bar.shell || typeof bar.shell.updateEntryInline !== "function") return
    var id = moduleName || "nova.tray"
    bar.shell.updateEntryInline(id, { id: id, pinned: pinned, hidden: hidden })
  }

  // ----- the drawer -----

  property bool expanded: false
  readonly property int iconExtent: Style.bar.iconSlot
  readonly property int drawerExtent: drawerItems.length * iconExtent
  // How far the drawer is open, 0 to 1, over 600 ms as Waybar's
  // tray-expander does.
  property real revealProgress: expanded ? 1 : 0
  readonly property real revealExtent: drawerExtent * revealProgress

  Behavior on revealProgress {
    NumberAnimation { duration: 600; easing.type: Easing.OutCubic }
  }

  visible: pinnedItems.length > 0 || drawerItems.length > 0
  clip: false
  implicitWidth: vertical ? barSize : trayStrip.implicitWidth
  implicitHeight: vertical ? trayStrip.implicitHeight : barSize

  Loader {
    id: trayStrip
    anchors.fill: parent
    sourceComponent: root.vertical ? sideStrip : flatStrip
  }

  Component { id: flatStrip; Strip { vertical: false } }
  Component { id: sideStrip; Strip { vertical: true } }

  // Along the bar: the chevron, the drawer it slides over, then the pinned
  // icons. The chevron starts at the drawer's far end and moves back as the
  // drawer opens.
  component Strip: Item {
    id: strip

    required property bool vertical
    readonly property int pinnedLength: vertical ? pinned.implicitHeight : pinned.implicitWidth
    readonly property int drawerLength: root.allItems.length > 0 ? (vertical ? chevron.implicitHeight : chevron.implicitWidth) + root.drawerExtent : 0
    readonly property real slide: root.drawerExtent - root.revealExtent

    implicitWidth: vertical ? root.barSize : drawerLength + pinnedLength
    implicitHeight: vertical ? drawerLength + pinnedLength : root.barSize

    // The room a closed drawer keeps is not the tray's: the pointer there
    // neither opens it nor stops a click going through.
    containmentMask: QtObject {
      function contains(point: point): bool {
        var across = strip.vertical ? point.x : point.y
        var along = strip.vertical ? point.y : point.x
        if (across < 0 || across > (strip.vertical ? strip.width : strip.height)) return false
        if (along >= strip.slide && along <= strip.drawerLength) return true
        return along >= strip.drawerLength && along <= (strip.vertical ? strip.implicitHeight : strip.implicitWidth)
      }
    }

    Item {
      width: strip.vertical ? root.barSize : strip.drawerLength
      height: strip.vertical ? strip.drawerLength : root.barSize
      visible: root.allItems.length > 0

      HoverHandler {
        onHoveredChanged: root.expanded = hovered
      }

      BarIconButton {
        id: chevron
        bar: root.bar
        width: implicitWidth
        height: implicitHeight
        x: strip.vertical ? 0 : strip.slide
        y: strip.vertical ? strip.slide : 0
        text: ""
        textRotation: strip.vertical ? 90 : 0
        onPressed: function(button) {
          if (button === Qt.RightButton) root.managePopupOpen = !root.managePopupOpen
        }
      }

      Item {
        x: strip.vertical ? 0 : chevron.width
        y: strip.vertical ? chevron.height : 0
        width: strip.vertical ? root.barSize : root.drawerExtent
        height: strip.vertical ? root.drawerExtent : root.barSize
        clip: true

        Grid {
          rows: strip.vertical ? -1 : 1
          columns: strip.vertical ? 1 : -1
          anchors.left: strip.vertical ? undefined : parent.left
          anchors.top: strip.vertical ? parent.top : undefined
          anchors.leftMargin: strip.slide
          anchors.topMargin: strip.slide
          anchors.verticalCenter: strip.vertical ? undefined : parent.verticalCenter
          anchors.horizontalCenter: strip.vertical ? parent.horizontalCenter : undefined
          layer.enabled: true

          Repeater {
            model: root.drawerItems
            TrayItem {}
          }
        }
      }
    }

    Grid {
      id: pinned
      rows: strip.vertical ? -1 : 1
      columns: strip.vertical ? 1 : -1
      anchors.left: strip.vertical ? undefined : parent.left
      anchors.top: strip.vertical ? parent.top : undefined
      anchors.leftMargin: strip.drawerLength
      anchors.topMargin: strip.drawerLength
      anchors.verticalCenter: strip.vertical ? undefined : parent.verticalCenter
      anchors.horizontalCenter: strip.vertical ? parent.horizontalCenter : undefined

      Repeater {
        model: root.pinnedItems
        TrayItem {}
      }
    }
  }

  // One icon. A click activates its app, a middle click does its second
  // action, the wheel scrolls it; a right click opens its menu, as does a
  // click on an icon that has only a menu.
  component TrayItem: Item {
    id: trayItem

    required property var modelData
    readonly property bool tooltipHovered: visible && opacity > 0 && pointer.containsMouse

    visible: modelData.status !== Status.Passive
    implicitWidth: visible ? root.iconExtent : 0
    implicitHeight: visible ? root.iconExtent : 0

    TrayIcon {
      anchors.centerIn: parent
      width: Style.space(12)
      height: Style.space(12)
      icon: trayItem.modelData.icon
    }

    MouseArea {
      id: pointer
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor

      onEntered: if (root.bar) root.bar.showTooltip(trayItem, trayItem.modelData.tooltipTitle || trayItem.modelData.title || trayItem.modelData.id || "")
      onExited: if (root.bar) root.bar.hideTooltip(trayItem)
      // A press puts the tooltip away, as on the bar's buttons: left up, it
      // sits over the menu the press opens.
      onPressed: function(mouse) {
        if (root.bar) root.bar.hideTooltip(trayItem)
        if (mouse.button === Qt.RightButton) {
          root.openTrayMenu(trayItem.modelData, trayItem, mouse)
          mouse.accepted = true
        }
      }
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) mouse.accepted = true
        else if (mouse.button === Qt.MiddleButton) trayItem.modelData.secondaryActivate()
        else if (trayItem.modelData.onlyMenu) root.openTrayMenu(trayItem.modelData, trayItem, mouse)
        else trayItem.modelData.activate()
      }
      onWheel: function(wheel) {
        trayItem.modelData.scroll(wheel.angleDelta.y, false)
      }
    }
  }

  // An icon from Quickshell's image:// URL, which already finds those an app
  // keeps outside an icon theme. A symbolic one (named "-symbolic") is drawn
  // in the bar's colour, as freedesktop means it to be: its own fill, often
  // near white, would vanish on a light bar.
  component TrayIcon: Item {
    id: trayIcon

    required property var icon
    readonly property bool symbolic: String(icon || "").split("?")[0].slice(-9) === "-symbolic"

    Image {
      id: image
      anchors.fill: parent
      fillMode: Image.PreserveAspectFit
      // At the screen's pixels: at the logical size, PNG icons blur on HiDPI.
      sourceSize.width: Math.round(Math.min(width, height) * Screen.devicePixelRatio)
      sourceSize.height: Math.round(Math.min(width, height) * Screen.devicePixelRatio)
      source: String(trayIcon.icon || "")
      // A symbolic one is drawn through the effect below, which reads it as
      // a layer.
      visible: !trayIcon.symbolic
      layer.enabled: trayIcon.symbolic
    }

    MultiEffect {
      anchors.fill: image
      source: image
      visible: trayIcon.symbolic
      colorization: 1.0
      colorizationColor: root.foreground
    }
  }

  // ----- pin and hide -----

  property bool managePopupOpen: false

  function close() {
    managePopupOpen = false
    trayMenuOpen = false
  }

  PopupCard {
    id: managePopup
    anchorItem: root
    owner: root
    bar: root.bar
    open: root.managePopupOpen
    contentWidth: managePopup.fittedContentWidth(Style.space(300))
    contentHeight: managePopup.fittedContentHeight(manageList.implicitHeight)

    Column {
      id: manageList
      anchors.fill: parent
      spacing: Style.space(8)

      Text {
        text: "Tray icons"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Text {
        width: parent.width
        text: "Pinned icons stay visible. Hidden icons never show."
        wrapMode: Text.WordWrap
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        visible: root.allItems.length === 0
        text: "No tray items reporting."
        color: Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.italic: true
      }

      Repeater {
        model: root.allItems

        Item {
          id: entry

          required property var modelData
          readonly property string itemId: String(modelData.id || "")
          // Its title, or its tooltip's, or the last part of its id.
          readonly property string name: {
            var title = String(modelData.title || "").trim()
            if (title) return title
            var tooltip = String(modelData.tooltipTitle || "").trim()
            if (tooltip) return tooltip
            var slash = itemId.lastIndexOf("/")
            return slash !== -1 ? itemId.substring(slash + 1) : (itemId || "Unknown")
          }

          width: manageList.width
          implicitHeight: 28

          TrayIcon {
            id: entryIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: 16
            height: 16
            icon: entry.modelData.icon
          }

          Text {
            anchors.left: entryIcon.right
            anchors.leftMargin: Style.space(10)
            anchors.right: hideButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: entry.name
            textFormat: Text.PlainText
            elide: Text.ElideRight
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          EntryButton {
            id: pinButton
            anchors.right: parent.right
            iconText: ""
            text: root.pinnedIds.indexOf(entry.itemId) !== -1 ? "Unpin" : "Pin"
            onClicked: root.togglePin(entry.itemId)
          }

          EntryButton {
            id: hideButton
            anchors.right: pinButton.left
            anchors.rightMargin: Style.space(6)
            iconText: ""
            text: root.hiddenIds.indexOf(entry.itemId) !== -1 ? "Show" : "Hide"
            onClicked: root.toggleHide(entry.itemId)
          }
        }
      }
    }
  }

  component EntryButton: Button {
    anchors.verticalCenter: parent.verticalCenter
    foreground: root.foreground
    horizontalPadding: 8
    verticalPadding: 3
    iconSize: Style.font.bodySmall
    fontSize: Style.font.bodySmall
  }

  // ----- an icon's menu -----

  property bool trayMenuOpen: false
  property var activeTrayItem: null
  property var activeTrayAnchor: null

  // The submenus open, outermost first, each { opener, title }. A submenu is
  // drawn here: QsMenuEntry.display() would hand it to Qt's own menus, which
  // Quickshell refuses outside QApplication mode, which Nova's shell is not
  // in, so the click did nothing and an app whose menu is all submenus
  // (radiotray-ng's stations) could not be used. Each level keeps its own
  // opener, as a submenu's entry belongs to its parent's: one opener for all
  // would free the entry it shows.
  property var submenuStack: []
  readonly property int submenuDepth: submenuStack.length
  readonly property string currentTitle: submenuDepth > 0 ? submenuStack[submenuDepth - 1].title : ""
  readonly property var currentChildren: submenuDepth > 0 ? submenuStack[submenuDepth - 1].opener.children : menuOpener.children

  // A new level is drawn at once, so its row under the pointer would take a
  // second click meant for the row before it. Clicks wait 250 ms after each
  // change of level.
  property bool menuLevelSettling: false

  function settleMenuLevel() {
    menuLevelSettling = true
    settling.restart()
  }

  // An app with no menu of its own draws one where it was clicked.
  function openTrayMenu(item, anchor, mouse) {
    if (!item.menu) {
      var point = anchor.QsWindow.contentItem.mapFromItem(anchor, mouse.x, mouse.y)
      item.display(anchor.QsWindow.window, point.x, point.y)
      return
    }
    // Before the item changes: its menu's entries go with it, and the
    // submenu openers hold some of them.
    resetTrayMenu()
    activeTrayItem = item
    activeTrayAnchor = anchor
    trayMenuOpen = true
  }

  function enterSubmenu(entry, title) {
    var opener = openerComponent.createObject(root, { menu: entry })
    if (!opener) return
    submenuStack = submenuStack.concat([{ opener: opener, title: title }])
    settleMenuLevel()
  }

  function leaveSubmenu() {
    if (submenuStack.length === 0) return
    var top = submenuStack[submenuStack.length - 1]
    submenuStack = submenuStack.slice(0, -1)
    top.opener.destroy()
    settleMenuLevel()
  }

  // Back to the top of the menu's first level. The stack empties before an
  // opener goes, so no binding reads one half freed, and the innermost goes
  // first, as its entry belongs to the one outside it. The list scrolls back
  // up too: a Flickable keeps its place across a new model that is tall
  // enough, so a menu closed scrolled down would open scrolled down.
  function resetTrayMenu() {
    menuLevelSettling = false
    settling.stop()
    menuFlick.contentY = 0
    var openers = submenuStack
    submenuStack = []
    for (var i = openers.length - 1; i >= 0; i--) openers[i].opener.destroy()
  }

  QsMenuOpener {
    id: menuOpener
    menu: root.activeTrayItem ? root.activeTrayItem.menu : null
  }

  Component {
    id: openerComponent
    QsMenuOpener {}
  }

  Timer {
    id: settling
    interval: 250
    onTriggered: root.menuLevelSettling = false
  }

  PopupCard {
    id: menuPopup
    anchorItem: root.activeTrayAnchor || root
    owner: root
    bar: root.bar
    open: root.trayMenuOpen
    padding: Style.space(8)
    borderColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)
    contentWidth: menuPopup.fittedContentWidth(Style.space(232))
    contentHeight: menuPopup.fittedContentHeight(headerHeight + menuRows.implicitHeight, Style.space(420))

    // A Column still counts a hidden child's height.
    readonly property int headerHeight: header.visible ? header.implicitHeight : 0

    // The card fades out over 140 ms, still visible: back to the first level
    // once it has gone, as a submenu swapped for it mid-fade would flash and
    // move. Another icon's menu resets at once, in openTrayMenu.
    onVisibleChanged: if (!visible) root.resetTrayMenu()

    Column {
      id: menuLayout
      anchors.fill: parent
      spacing: 0

      // In a submenu: its name, which leads back out. It stays above the
      // rows rather than scrolling with them, so the way back is always
      // there.
      Column {
        id: header
        visible: root.submenuDepth > 0
        width: menuLayout.width
        spacing: 0

        Item {
          width: header.width
          implicitHeight: Style.space(30)

          HoverFill { lit: back.containsMouse }

          MenuText {
            anchors.left: parent.left
            width: Style.space(22)
            horizontalAlignment: Text.AlignHCenter
            text: "‹"
          }

          MenuText {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(28)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(10)
            text: root.currentTitle
            elide: Text.ElideRight
          }

          MouseArea {
            id: back
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: {
              if (root.menuLevelSettling) return
              // Before the rows change, so the level shows from its top.
              menuFlick.contentY = 0
              root.leaveSubmenu()
            }
          }
        }

        Item {
          width: header.width
          implicitHeight: Style.space(11)

          Rule {}
        }
      }

      Flickable {
        id: menuFlick
        width: menuLayout.width
        height: menuLayout.height - menuPopup.headerHeight
        contentWidth: width
        contentHeight: menuRows.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: menuRows
          width: menuFlick.width
          spacing: 0

          Repeater {
            model: root.currentChildren

            Item {
              id: row

              required property var modelData
              required property int index
              readonly property string label: String(modelData.text || "")
              readonly property bool separator: modelData.isSeparator
              // At the first level, the entry that only repeats the app's
              // name, and a separator at the top.
              readonly property string appTitle: root.activeTrayItem ? String(root.activeTrayItem.title || root.activeTrayItem.id || "") : ""
              readonly property bool skipped: root.submenuDepth === 0
                && ((index === 0 && modelData.hasChildren && label.toLowerCase() === appTitle.toLowerCase())
                  || (separator && index <= 1))

              visible: !skipped
              width: menuRows.width
              implicitHeight: skipped ? 0 : (separator ? Style.space(11) : Style.space(30))
              opacity: modelData.enabled ? 1.0 : 0.45

              Rule { visible: row.separator }

              HoverFill {
                visible: !row.separator
                lit: rowArea.containsMouse && row.modelData.enabled
              }

              // The tick of a check or radio entry.
              MenuText {
                visible: !row.separator && row.modelData.buttonType !== QsMenuButtonType.None
                anchors.left: parent.left
                width: Style.space(22)
                horizontalAlignment: Text.AlignHCenter
                text: row.modelData.checkState === Qt.Checked ? "" : ""
              }

              Image {
                id: rowIcon
                visible: !row.separator && String(row.modelData.icon || "") !== ""
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(24)
                width: Style.space(16)
                height: Style.space(16)
                fillMode: Image.PreserveAspectFit
                // At the screen's pixels: at the logical size, PNG icons blur
                // on HiDPI.
                sourceSize.width: width * Screen.devicePixelRatio
                sourceSize.height: height * Screen.devicePixelRatio
                source: row.modelData.icon
              }

              MenuText {
                visible: !row.separator
                anchors.left: parent.left
                anchors.leftMargin: rowIcon.visible ? Style.space(46) : Style.space(28)
                anchors.right: arrow.left
                anchors.rightMargin: Style.space(8)
                text: row.label
                elide: Text.ElideRight
              }

              MenuText {
                id: arrow
                visible: !row.separator && row.modelData.hasChildren
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                text: "›"
              }

              MouseArea {
                id: rowArea
                anchors.fill: parent
                hoverEnabled: true
                enabled: !row.separator && row.modelData.enabled
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                  if (root.menuLevelSettling) return
                  if (row.modelData.hasChildren) {
                    // Before the rows change: this one goes with them.
                    menuFlick.contentY = 0
                    root.enterSubmenu(row.modelData, row.label)
                  } else {
                    row.modelData.triggered()
                    root.close()
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  component MenuText: Text {
    anchors.verticalCenter: parent.verticalCenter
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component HoverFill: Rectangle {
    property bool lit: false
    anchors.fill: parent
    radius: Math.max(2, Style.cornerRadius)
    color: lit ? Style.hoverFillFor(root.foreground, root.foreground) : "transparent"
  }

  // A separator's line.
  component Rule: Rectangle {
    anchors.left: parent.left
    anchors.leftMargin: Style.space(10)
    anchors.right: parent.right
    anchors.rightMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
    height: 1
    color: Commons.Color.popups.border
    opacity: 0.45
  }
}
