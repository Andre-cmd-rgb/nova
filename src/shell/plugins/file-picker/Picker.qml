import QtQuick
import QtQuick.Layouts
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "FilePickerModel.js" as Model

// The file picker's window: the places down the left, the folder's files in
// the middle under a trail of its path, and under them what the app asked
// for (a name, its choices, a filter) and the answers. FilePicker.qml makes
// it for one pick and ends it with the one line it says: finished(line).
//
// The list is Qt's FolderListModel, which reads and watches the folder in a
// thread of its own and says each file's size, date and kind itself, so no
// row asks anything of the disk but its picture, and only an image's. The
// few questions the model cannot answer (is this path a folder or a file,
// can this folder be read, make this folder) are asked of a command, once, when
// the person has done something that needs the answer.
//
// What a pick may choose, by its mode:
//   open        files; a folder is entered, never chosen
//   save        a folder to save in, and a name typed or clicked
//   folder      folders; the files are shown, dimmed, so that the place is known
//   save-files  the folder the app's files will be saved in
FloatingWindow {
  id: win

  property var request: null
  signal finished(string line)

  // The fields, for a test to type in.
  readonly property alias nameInput: nameField
  readonly property alias locationInput: locationField
  readonly property alias newInput: newField
  readonly property alias confirm: sheet

  // ---------------------------------------------------------------- state

  readonly property string mode: request ? request.mode : "open"
  readonly property bool saves: mode === "save"
  readonly property bool picksFolders: mode === "folder" || mode === "save-files"
  readonly property bool multiple: request ? request.multiple : false
  readonly property var filters: request ? request.filters : []
  readonly property var places: request ? request.places : []
  readonly property var choices: request ? request.choices : []
  readonly property string home: Commons.Color.home

  property string folder: request ? request.folder : "/"
  property var trail: Model.history(request ? request.folder : "/")
  property bool hidden: request ? request.hidden : false
  property int filterIndex: request && request.filters.length > 0 ? request.filter : 0
  // The paths chosen in the list, each with whether it is a folder.
  property var chosen: ({})
  property int anchor: -1
  // A path to select as soon as the list has it.
  property string pending: request ? request.select : ""
  property int pendingTries: 0
  property var values: ({})
  property string message: ""
  property bool done: false
  // Which text field the keys are in: "name", "location", "new", or "" for the list.
  property string field: ""
  property bool locating: false
  property bool naming: false
  // "empty", "full" or "no": what is known of a folder that shows nothing.
  property string bareKind: ""
  property int sortField: FolderListModel.Name
  property bool sortReversed: false
  property string typed: ""
  property real typedAt: 0

  readonly property var chosenPaths: Object.keys(chosen)
  readonly property var chosenDirs: chosenPaths.filter(function (p) { return chosen[p] })
  readonly property var chosenFiles: chosenPaths.filter(function (p) { return !chosen[p] })
  readonly property bool canBack: Model.canBack(trail)
  readonly property bool canForward: Model.canForward(trail)
  readonly property var crumbs: Model.collapse(Model.breadcrumbs(folder, home), 5, 3)
  readonly property int placeIndex: Model.placeFor(places, folder)
  readonly property bool filtered: filters.length > 0 && filters[filterIndex].globs.every(function (g) { return g !== "*" }) && filters[filterIndex].globs.length > 0
  readonly property bool canAccept: {
    if (saves) return nameField.text !== ""
    if (picksFolders) return true
    return chosenPaths.length > 0
  }

  readonly property int rowHeight: Style.space(32)
  readonly property int iconBox: Style.space(22)
  readonly property int sizeWidth: Style.space(84)
  readonly property int dateWidth: Style.space(138)
  readonly property int gap: Style.space(12)

  // ---------------------------------------------------------------- window

  // The room on the focused screen, as Settings has it: the usual size
  // where it fits, a little more on a big screen, and no more than a small
  // one has.
  property size room: Qt.size(Style.space(880), Style.space(560))
  property real growth: 1

  function measureRoom() {
    var hyprland = !!Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")
    var name = hyprland && Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (screens[i].name === name) {
        room = Qt.size(screens[i].width - Style.space(48), screens[i].height - Style.space(80))
        growth = Util.windowGrowth(screens[i].width, screens[i].height, Style.spaceScale)
        return
      }
    }
  }

  title: request ? Model.title(request) : ""
  visible: request !== null
  color: Commons.Color.background
  implicitWidth: Math.min(Style.space(880 * growth), room.width)
  implicitHeight: Math.min(Style.space(560 * growth), room.height)
  minimumSize: Qt.size(Math.min(Style.space(600), room.width), Math.min(Style.space(400), room.height))

  // The window closed by the window manager is a cancel.
  onVisibleChanged: if (!visible) cancel()

  Component.onCompleted: {
    if (!request) return
    measureRoom()
    var all = {}
    request.choices.forEach(function (c) { all[c.id] = c.value })
    values = all
    nameField.text = request.name
    Qt.callLater(start)
  }

  // The keys start in the name when there is one to type, with its stem
  // chosen, and else in the list.
  function start() {
    if (saves) {
      nameField.forceActiveFocus()
      nameField.select(0, Model.stemLength(nameField.text))
      field = "name"
    } else {
      focusList()
    }
  }

  function focusList() {
    field = ""
    list.forceActiveFocus()
  }

  // ---------------------------------------------------------------- the answer

  function finish(line) {
    if (done) return
    done = true
    finished(line)
  }

  function cancel() {
    finish(Model.cancelLine())
  }

  function answer(paths) {
    finish(Model.answerLine(paths, filters.length > 0 ? filterIndex : -1, Model.choiceValues(choices, values), hidden))
  }

  // The accept button, and Return in the name: what the mode makes of what
  // is chosen.
  function accept() {
    if (!canAccept || done) return
    message = ""
    if (saves) {
      var name = nameField.text
      var problem = Model.nameProblem(name)
      if (problem !== "") {
        message = Model.nameMessage(problem)
        return
      }
      look(Model.join(folder, name), "save")
    } else if (mode === "open") {
      if (chosenFiles.length === 0 && chosenDirs.length === 1) navigate(chosenDirs[0])
      else answer(Model.answerPaths(request, folder, "", chosenPaths, chosenDirs))
    } else {
      answer(Model.answerPaths(request, folder, "", chosenPaths, chosenDirs))
    }
  }

  // ---------------------------------------------------------------- places

  function navigate(path) {
    path = Model.normalize(path)
    folder = path
    trail = Model.visit(trail, path)
    arrived()
  }

  function arrived() {
    chosen = ({})
    anchor = -1
    pending = ""
    message = ""
    bareKind = ""
    typed = ""
    list.currentIndex = -1
    closeLocation()
    cancelNaming()
    bare.restart()
  }

  function goBack() {
    if (!canBack) return
    trail = Model.stepped(trail, -1)
    folder = trail.stack[trail.at]
    arrived()
  }

  function goForward() {
    if (!canForward) return
    trail = Model.stepped(trail, 1)
    folder = trail.stack[trail.at]
    arrived()
  }

  function goUp() {
    if (folder !== "/") navigate(Model.parent(folder))
  }

  function toggleHidden() {
    hidden = !hidden
  }

  // ---------------------------------------------------------------- the list

  function count() {
    return folderModel.count
  }

  function pathAt(i) {
    return folderModel.get(i, "filePath")
  }

  function nameAt(i) {
    return folderModel.get(i, "fileName")
  }

  function isDirAt(i) {
    return folderModel.get(i, "fileIsDir") === true
  }

  // Folder mode has no use for a file, which is shown but not chosen.
  function selectable(i) {
    return !picksFolders || isDirAt(i)
  }

  // Clicks and keys choose a row: Control adds or takes away one, Shift
  // runs from the last chosen, where the pick takes several.
  function choose(i, modifiers) {
    if (i < 0 || i >= count() || !selectable(i)) return
    var ctrl = (modifiers & Qt.ControlModifier) !== 0
    var shift = (modifiers & Qt.ShiftModifier) !== 0
    var next = {}
    var path = pathAt(i)
    if (multiple && ctrl) {
      next = Object.assign({}, chosen)
      if (next.hasOwnProperty(path)) delete next[path]
      else next[path] = isDirAt(i)
      anchor = i
    } else if (multiple && shift && anchor >= 0) {
      for (var k = Math.min(anchor, i); k <= Math.max(anchor, i); k++)
        if (selectable(k)) next[pathAt(k)] = isDirAt(k)
    } else {
      next[path] = isDirAt(i)
      anchor = i
    }
    chosen = next
    list.currentIndex = i
    list.positionViewAtIndex(i, ListView.Contain)
    message = ""
    if (saves && !isDirAt(i)) nameField.text = nameAt(i)
  }

  function selectAll() {
    if (!multiple) return
    var next = {}
    for (var i = 0; i < count(); i++)
      if (selectable(i) && (picksFolders || !isDirAt(i))) next[pathAt(i)] = isDirAt(i)
    chosen = next
  }

  // The next row that can be chosen from <from>, going by <dir>; <from> itself
  // when there is none.
  function reach(from, dir) {
    for (var i = from + dir; i >= 0 && i < count(); i += dir)
      if (selectable(i)) return i
    return from
  }

  function move(key, modifiers) {
    var n = count()
    if (n === 0) return
    var at = list.currentIndex
    var page = Math.max(1, Math.floor(list.height / rowHeight) - 1)
    var to
    if (key === Qt.Key_Down) to = at < 0 ? reach(-1, 1) : reach(at, 1)
    else if (key === Qt.Key_Up) to = at < 0 ? reach(n, -1) : reach(at, -1)
    else if (key === Qt.Key_Home) to = selectable(0) ? 0 : reach(0, 1)
    else if (key === Qt.Key_End) to = selectable(n - 1) ? n - 1 : reach(n - 1, -1)
    else if (key === Qt.Key_PageDown) to = reach(Math.min(n - 1, Math.max(at, 0) + page) + 1, -1)
    else to = reach(Math.max(0, Math.max(at, 0) - page) - 1, 1)
    if (to < 0 || to >= n) return
    choose(to, modifiers)
  }

  // Return, or two clicks, on the row at <i>: a folder is entered, a file
  // is what the mode makes of it.
  function open(i) {
    if (i < 0 || i >= count() || !selectable(i)) return
    if (isDirAt(i)) {
      navigate(pathAt(i))
    } else {
      if (!chosen.hasOwnProperty(pathAt(i))) choose(i, 0)
      accept()
    }
  }

  function activate() {
    var i = list.currentIndex
    if (i >= 0 && chosen.hasOwnProperty(pathAt(i))) open(i)
    else accept()
  }

  function typeAhead(char) {
    var now = Date.now()
    typed = now - typedAt > 1000 ? char : typed + char
    typedAt = now
    var start = typed.length === 1 ? Math.max(0, list.currentIndex + 1) : Math.max(0, list.currentIndex)
    var found = Model.typeAhead(count(), function (i) { return selectable(i) ? nameAt(i) : "" }, typed, start)
    if (found >= 0) choose(found, 0)
  }

  // Selects the path asked for as it appears in the list.
  function applyPending() {
    if (pending === "" || folderModel.status === FolderListModel.Loading) return
    for (var i = 0; i < count(); i++) {
      if (pathAt(i) === pending) {
        pending = ""
        choose(i, 0)
        list.positionViewAtIndex(i, ListView.Center)
        return
      }
    }
  }

  // ---------------------------------------------------------------- sorting

  function sortBy(sortKey) {
    if (sortField === sortKey) {
      sortReversed = !sortReversed
    } else {
      sortField = sortKey
      sortReversed = false
    }
  }

  // ---------------------------------------------------------------- filters

  function chooseFilter(index) {
    if (index < 0 || index >= filters.length || index === filterIndex) return
    if (saves) nameField.text = Model.swapExtension(nameField.text, filters[filterIndex].globs, filters[index].globs)
    filterIndex = index
    chosen = ({})
    anchor = -1
  }

  function setChoice(id, value) {
    var next = Object.assign({}, values)
    next[id] = value
    values = next
  }

  // ---------------------------------------------------------------- location

  function openLocation(first) {
    locating = true
    field = "location"
    locationField.text = first !== undefined ? first : folder
    locationField.forceActiveFocus()
    if (first === undefined) locationField.selectAll()
    else locationField.cursorPosition = locationField.text.length
  }

  function closeLocation() {
    if (!locating) return
    locating = false
    focusList()
  }

  function goToLocation() {
    var path = Model.resolveLocation(locationField.text, home, folder)
    look(path, "location")
  }

  // ---------------------------------------------------------------- new folder

  function folderTaken(name) {
    for (var i = 0; i < count(); i++)
      if (nameAt(i) === name) return true
    return false
  }

  function startNaming() {
    if (naming || !(saves || picksFolders)) return
    naming = true
    field = "new"
    newField.text = Model.freeName("New Folder", folderTaken)
    newField.forceActiveFocus()
    newField.selectAll()
  }

  function cancelNaming() {
    if (!naming) return
    naming = false
    focusList()
  }

  function makeFolder() {
    var name = newField.text
    var problem = Model.nameProblem(name)
    if (problem !== "") {
      message = Model.nameMessage(problem)
      return
    }
    if (maker.running) return
    maker.target = Model.join(folder, name)
    maker.named = name
    maker.command = ["sh", "-c", "mkdir -- \"$1\" 2>&1; echo \"status:$?\"", "sh", maker.target]
    maker.running = true
  }

  function madeFolder(output) {
    var status = /status:(\d+)\s*$/.exec(output)
    if (status && status[1] === "0") {
      var path = maker.target
      naming = false
      message = ""
      if (saves) {
        navigate(path)
      } else {
        pending = path
        pendingTries = 0
        focusList()
        applyPending()
      }
      return
    }
    if (output.indexOf("File exists") >= 0) message = "“" + maker.named + "” already exists."
    else if (output.indexOf("Permission denied") >= 0) message = "You don’t have permission to make a folder here."
    else if (output.indexOf("Read-only") >= 0) message = "This folder is read-only."
    else message = "The folder couldn’t be made."
  }

  Process {
    id: maker
    property string target: ""
    property string named: ""
    stdout: StdioCollector {
      onStreamFinished: win.madeFolder(text)
    }
  }

  // ---------------------------------------------------------------- what is at a path

  // Asks whether a path is a folder, a file or neither, for the location
  // field and for a name about to be saved under.
  function look(path, why) {
    if (finder.running) return
    finder.path = path
    finder.why = why
    finder.command = ["sh", "-c", "if [ -d \"$1\" ]; then echo dir; elif [ -e \"$1\" ]; then echo file; else echo none; fi", "sh", path]
    finder.running = true
  }

  function found(kind) {
    var path = finder.path
    if (finder.why === "location") {
      if (kind === "dir") {
        navigate(path)
      } else if (kind === "file" && mode === "open") {
        answer([path])
      } else if (kind === "file" && saves) {
        navigate(Model.parent(path))
        nameField.text = Model.baseName(path)
      } else {
        message = kind === "file" ? "That is a file, and a folder is wanted." : "There is no such file or folder."
      }
    } else if (finder.why === "save") {
      if (kind === "dir") {
        nameField.text = ""
        navigate(path)
      } else if (kind === "file") {
        sheet.question = Model.overwriteQuestion(Model.baseName(path), folder)
        sheet.asking = true
      } else {
        answer([path])
      }
    }
  }

  Process {
    id: finder
    property string path: ""
    property string why: ""
    stdout: StdioCollector {
      onStreamFinished: win.found(text.trim())
    }
  }

  // A folder that shows nothing: is it empty, unreadable, or has the filter
  // or the hidden files taken everything out?
  Timer {
    id: bare
    interval: 150
    onTriggered: {
      if (folderModel.count > 0 || folderModel.status === FolderListModel.Loading || reader.running) return
      reader.path = win.folder
      reader.command = ["sh", "-c", "if [ ! -r \"$1\" ] || [ ! -x \"$1\" ]; then echo no; elif [ -n \"$(ls -A -- \"$1\" | head -n 1)\" ]; then echo full; else echo empty; fi", "sh", win.folder]
      reader.running = true
    }
  }

  Process {
    id: reader
    property string path: ""
    stdout: StdioCollector {
      onStreamFinished: {
        if (reader.path === win.folder) win.bareKind = text.trim()
        else bare.restart()
      }
    }
  }

  // ---------------------------------------------------------------- keys

  // True for a key the window took. Escape leaves the field or the question
  // it is in, and else cancels; the arrows, Home, End and the pages move in
  // the list, and what is typed there searches it.
  function handleKey(event) {
    var took = pressed(event)
    if (took) event.accepted = true
    return took
  }

  function pressed(event) {
    if (sheet.asking) return sheet.key(event)
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    var alt = (event.modifiers & Qt.AltModifier) !== 0
    var key = event.key
    if (key === Qt.Key_Escape) {
      if (locating) closeLocation()
      else if (naming) cancelNaming()
      else cancel()
      return true
    }
    if (ctrl && key === Qt.Key_H) {
      toggleHidden()
      return true
    }
    if (ctrl && key === Qt.Key_L) {
      openLocation()
      return true
    }
    if (alt && key === Qt.Key_Left) {
      goBack()
      return true
    }
    if (alt && key === Qt.Key_Right) {
      goForward()
      return true
    }
    if (alt && key === Qt.Key_Up) {
      goUp()
      return true
    }
    if (key === Qt.Key_Up || key === Qt.Key_Down) {
      if (field === "location" || field === "new") return false
      move(key, event.modifiers)
      return true
    }
    if (field !== "") return false
    if (ctrl && key === Qt.Key_A) {
      selectAll()
      return true
    }
    switch (key) {
    case Qt.Key_Home:
    case Qt.Key_End:
    case Qt.Key_PageUp:
    case Qt.Key_PageDown:
      move(key, event.modifiers)
      return true
    case Qt.Key_Return:
    case Qt.Key_Enter:
      activate()
      return true
    case Qt.Key_Backspace:
      goUp()
      return true
    }
    if (ctrl || alt) return false
    var text = event.text || ""
    if (text === "/" || text === "~") {
      openLocation(text)
      return true
    }
    if (text.length === 1 && text.charCodeAt(0) > 32) {
      typeAhead(text)
      return true
    }
    return false
  }

  // ---------------------------------------------------------------- the model

  FolderListModel {
    id: folderModel
    folder: Model.fileUrl(win.folder)
    showDirs: true
    showFiles: true
    showDirsFirst: true
    showDotAndDotDot: false
    showHidden: win.hidden
    caseSensitive: false
    sortCaseSensitive: false
    sortField: win.sortField
    sortReversed: win.sortReversed
    nameFilters: win.filters.length > 0 ? win.filters[win.filterIndex].globs : []

    onCountChanged: {
      win.applyPending()
      bare.restart()
    }
    onStatusChanged: {
      win.applyPending()
      bare.restart()
    }
  }

  // A path to select that the list did not have yet, as the folder is
  // watched: asked again a few times.
  Timer {
    interval: 150
    repeat: true
    running: win.pending !== ""
    onTriggered: {
      win.applyPending()
      if (++win.pendingTries > 20) win.pending = ""
    }
  }

  // ---------------------------------------------------------------- the picture

  FocusScope {
    id: scope
    anchors.fill: parent
    focus: true

    Keys.onPressed: function (event) { win.handleKey(event) }

    // ---- sidebar ----------------------------------------------------------
    Rectangle {
      id: sidebar
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: Style.space(190)
      color: Qt.alpha(Commons.Color.foreground, 0.03)

      Flickable {
        anchors.fill: parent
        anchors.margins: Style.space(12)
        anchors.topMargin: Style.space(18)
        contentHeight: entries.implicitHeight
        boundsBehavior: Flickable.StopAtBounds
        clip: true

        Column {
          id: entries
          width: parent.width
          spacing: Style.space(2)

          Repeater {
            model: win.places

            delegate: Rectangle {
              id: place
              required property var modelData
              required property int index
              readonly property bool here: win.placeIndex === index
              width: entries.width
              height: Style.space(32)
              radius: Style.cornerRadius
              color: here ? Style.selectedFill : (hover.hovered ? Style.hoverFill : "transparent")

              HoverHandler { id: hover }
              TapHandler { onTapped: win.navigate(place.modelData.path) }

              Row {
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(10)

                Text {
                  width: Style.space(18)
                  text: Model.glyph(place.modelData.glyph)
                  textFormat: Text.PlainText
                  color: place.here ? Commons.Color.accent : Commons.Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.icon
                  horizontalAlignment: Text.AlignHCenter
                }

                Text {
                  width: parent.width - Style.space(28)
                  text: place.modelData.label
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: Commons.Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: place.here
                }
              }
            }
          }
        }
      }
    }

    // ---- the rest -----------------------------------------------------------
    Item {
      id: main
      anchors.left: sidebar.right
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      anchors.margins: win.gap

      // ---- title ----------------------------------------------------------
      Row {
        id: heading
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: Style.space(30)
        spacing: Style.space(10)

        Text {
          id: headingTitle
          anchors.verticalCenter: parent.verticalCenter
          width: Math.min(implicitWidth, parent.width)
          text: win.request ? Model.title(win.request) : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: Commons.Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(0, parent.width - headingTitle.width - parent.spacing)
          visible: win.request !== null && win.request.app !== ""
          text: win.request ? "\u00b7 " + win.request.app : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: Commons.Color.mutedText
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
      }

      // ---- header ---------------------------------------------------------
      Item {
        id: header
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: heading.bottom
        height: Style.spacing.controlHeight + Style.space(4)

        Row {
          id: steps
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(4)

          Button {
            iconText: Model.glyph("back")
            enabled: win.canBack
            opacity: enabled ? 1 : 0.4
            tooltipText: "Back"
            onClicked: win.goBack()
          }

          Button {
            iconText: Model.glyph("forward")
            enabled: win.canForward
            opacity: enabled ? 1 : 0.4
            tooltipText: "Forward"
            onClicked: win.goForward()
          }
        }

        Button {
          id: newFolderButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: win.saves || win.picksFolders
          iconText: Model.glyph("plus")
          text: "New Folder"
          bordered: true
          onClicked: win.startNaming()
        }

        // The trail of the path, each part to click.
        Item {
          id: trailBox
          anchors.left: steps.right
          anchors.leftMargin: win.gap
          anchors.right: newFolderButton.visible ? newFolderButton.left : parent.right
          anchors.rightMargin: newFolderButton.visible ? win.gap : 0
          anchors.verticalCenter: parent.verticalCenter
          height: parent.height
          clip: true
          visible: !win.locating

          Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Repeater {
              model: win.crumbs

              delegate: Row {
                id: crumb
                required property var modelData
                required property int index
                readonly property bool last: index === win.crumbs.length - 1
                spacing: Style.space(2)

                Text {
                  visible: crumb.index > 0
                  anchors.verticalCenter: parent.verticalCenter
                  text: "›"
                  color: Commons.Color.mutedText
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.min(label.implicitWidth + Style.space(12), Style.space(180))
                  height: Style.space(26)
                  radius: Style.cornerRadius
                  color: crumbHover.hovered ? Style.hoverFill : "transparent"

                  HoverHandler { id: crumbHover }
                  TapHandler { onTapped: win.navigate(crumb.modelData.path) }

                  Text {
                    id: label
                    anchors.centerIn: parent
                    width: Math.min(implicitWidth, parent.width - Style.space(12))
                    text: crumb.modelData.label
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: Commons.Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    font.bold: crumb.last
                  }
                }
              }
            }
          }
        }

        // The path typed, in place of the trail.
        TextField {
          id: locationField
          anchors.left: steps.right
          anchors.leftMargin: win.gap
          anchors.right: trailBox.right
          anchors.verticalCenter: parent.verticalCenter
          visible: win.locating
          placeholderText: "Type a path"
          onAccepted: win.goToLocation()
        }
      }

      // ---- the new folder's name -------------------------------------------
      Item {
        id: newRow
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: header.bottom
        height: win.naming ? Style.spacing.controlHeight + Style.space(8) : 0
        visible: win.naming

        Row {
          anchors.fill: parent
          anchors.topMargin: Style.space(4)
          spacing: Style.space(8)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: Model.glyph("folder")
            color: Commons.Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.iconLarge
          }

          TextField {
            id: newField
            width: Style.space(280)
            onAccepted: win.makeFolder()
          }

          Button {
            text: "Create"
            bordered: true
            onClicked: win.makeFolder()
          }
        }
      }

      // ---- columns ----------------------------------------------------------
      Item {
        id: columns
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: newRow.bottom
        height: Style.space(26)

        Repeater {
          model: [
            { key: FolderListModel.Name, label: "Name" },
            { key: FolderListModel.Size, label: "Size" },
            { key: FolderListModel.Time, label: "Modified" }
          ]

          delegate: Item {
            id: head
            required property var modelData
            required property int index
            readonly property bool active: win.sortField === modelData.key
            // Over the row's own columns: the date's at the right edge, the
            // size's before it, the name's from the icon.
            x: index === 0 ? win.iconBox + Style.space(18) : index === 1 ? columns.width - win.dateWidth - win.sizeWidth - Style.space(16) : columns.width - win.dateWidth - Style.space(8)
            width: index === 0 ? columns.width - win.dateWidth - win.sizeWidth - Style.space(34) - win.iconBox : index === 1 ? win.sizeWidth : win.dateWidth
            height: columns.height

            Text {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: index === 1 ? undefined : parent.left
              anchors.right: index === 1 ? parent.right : undefined
              text: head.modelData.label + (head.active ? " " + Model.glyph(win.sortReversed ? "up" : "down") : "")
              textFormat: Text.PlainText
              color: head.active ? Commons.Color.foreground : Commons.Color.mutedText
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: head.active
            }

            TapHandler { onTapped: win.sortBy(head.modelData.key) }
          }
        }

        Rectangle {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: 1
          color: Qt.alpha(Commons.Color.foreground, 0.12)
        }
      }

      // ---- bottom -------------------------------------------------------------
      Column {
        id: bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        spacing: Style.space(8)

        Text {
          width: parent.width
          visible: win.message !== ""
          text: win.message
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          color: Commons.Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Text {
          width: parent.width
          visible: win.mode === "save-files"
          text: win.request ? Model.savesLine(win.request.files) : ""
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: Commons.Color.mutedText
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        Row {
          width: parent.width
          visible: win.saves
          spacing: Style.space(10)

          Text {
            id: nameLabel
            anchors.verticalCenter: parent.verticalCenter
            text: "Name:"
            color: Commons.Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          TextField {
            id: nameField
            width: parent.width - nameLabel.width - parent.spacing
            onAccepted: win.accept()
            onTextChanged: win.message = ""
          }
        }

        RowLayout {
          width: parent.width
          spacing: Style.space(12)

          Flow {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: Style.space(14)

            Repeater {
              model: win.choices

              delegate: Row {
                id: choice
                required property var modelData
                spacing: Style.space(8)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: choice.modelData.options.length > 0 ? choice.modelData.label + ":" : choice.modelData.label
                  textFormat: Text.PlainText
                  color: Commons.Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }

                ToggleSwitch {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: choice.modelData.options.length === 0
                  checked: win.values[choice.modelData.id] === "true"
                  onToggled: win.setChoice(choice.modelData.id, checked ? "false" : "true")
                }

                Dropdown {
                  anchors.verticalCenter: parent.verticalCenter
                  visible: choice.modelData.options.length > 0
                  width: Style.space(170)
                  options: choice.modelData.options.map(function (o) { return { value: o.id, label: o.label } })
                  value: win.values[choice.modelData.id] ?? ""
                  onChanged: v => win.setChoice(choice.modelData.id, v)
                }
              }
            }

            Dropdown {
              visible: win.filters.length > 1
              width: Style.space(190)
              options: win.filters.map(function (f, i) { return { value: String(i), label: f.name } })
              value: String(win.filterIndex)
              onChanged: v => win.chooseFilter(parseInt(v, 10))
            }
          }

          Button {
            text: "Cancel"
            bordered: true
            onClicked: win.cancel()
          }

          Button {
            id: acceptButton
            text: win.request ? Model.acceptWords(win.request) : ""
            bordered: true
            lit: true
            enabled: win.canAccept
            opacity: enabled ? 1 : 0.45
            onClicked: win.accept()
          }
        }
      }

      // ---- the list -----------------------------------------------------------
      ListView {
        id: list
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: columns.bottom
        anchors.topMargin: Style.space(2)
        anchors.bottom: bottom.top
        anchors.bottomMargin: Style.space(10)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        keyNavigationEnabled: false
        currentIndex: -1
        model: folderModel
        cacheBuffer: win.rowHeight * 6
        reuseItems: true

        delegate: Item {
          id: row

          required property int index
          required property string fileName
          required property string filePath
          required property bool fileIsDir
          required property var fileSize
          required property var fileModified
          required property string fileSuffix

          readonly property bool picked: win.chosen.hasOwnProperty(filePath)
          readonly property bool dim: win.picksFolders && !fileIsDir
          readonly property bool image: !fileIsDir && Model.isImage(fileSuffix)

          width: list.width
          height: win.rowHeight

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: row.picked ? Style.selectedFill : (rowHover.hovered && !row.dim ? Style.hoverFill : "transparent")
          }

          HoverHandler { id: rowHover }

          MouseArea {
            anchors.fill: parent
            onPressed: win.focusList()
            onClicked: mouse => win.choose(row.index, mouse.modifiers)
            onDoubleClicked: win.open(row.index)
          }

          Item {
            id: iconBox
            x: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            width: win.iconBox
            height: win.iconBox
            opacity: row.dim ? 0.4 : 1

            Text {
              anchors.centerIn: parent
              visible: !row.image || thumb.status !== Image.Ready
              text: Model.fileGlyph(row.fileIsDir, row.fileSuffix)
              textFormat: Text.PlainText
              color: row.fileIsDir ? Commons.Color.accent : Commons.Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.iconLarge
            }

            Image {
              id: thumb
              anchors.fill: parent
              visible: status === Image.Ready
              source: row.image ? Model.fileUrl(row.filePath) : ""
              asynchronous: true
              cache: false
              fillMode: Image.PreserveAspectCrop
              sourceSize: Qt.size(win.iconBox * 2, win.iconBox * 2)
            }
          }

          Text {
            anchors.left: iconBox.right
            anchors.leftMargin: Style.space(10)
            anchors.right: sizeText.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: row.fileName
            textFormat: Text.PlainText
            elide: Text.ElideMiddle
            color: Commons.Color.foreground
            opacity: row.dim ? 0.4 : 1
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: row.picked
          }

          Text {
            id: sizeText
            anchors.right: dateText.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            width: win.sizeWidth
            horizontalAlignment: Text.AlignRight
            text: row.fileIsDir ? "" : Model.sizeLabel(row.fileSize)
            textFormat: Text.PlainText
            color: Commons.Color.mutedText
            opacity: row.dim ? 0.5 : 1
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            id: dateText
            anchors.right: parent.right
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            width: win.dateWidth
            text: Model.dateLabel(row.fileModified, Date.now())
            textFormat: Text.PlainText
            color: Commons.Color.mutedText
            opacity: row.dim ? 0.5 : 1
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        Text {
          anchors.centerIn: parent
          visible: folderModel.count === 0 && folderModel.status !== FolderListModel.Loading && win.bareKind !== ""
          text: win.bareKind === "no" ? "This folder can’t be opened"
            : win.bareKind === "full" && win.filtered ? "No files of this type here"
            : "This folder is empty"
          textFormat: Text.PlainText
          color: Commons.Color.mutedText
          font.family: Style.font.family
          font.pixelSize: Style.font.title
        }
      }
    }

    // ---- the question on replacing a file ---------------------------------------
    ConfirmDialog {
      id: sheet
      anchors.fill: parent
      z: 10
      yes: "Replace"
      onKept: {
        asking = false
        nameField.forceActiveFocus()
        win.field = "name"
      }
      onConfirmed: {
        asking = false
        win.answer([Model.join(win.folder, nameField.text)])
      }
    }
  }
}
