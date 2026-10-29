import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// BulkPublish in the bar: write a post, pick channels, post it now or keep it
// as a draft, and see how the last few posts went.
//
// Every request goes through bin/bulkpublish, run with an argv array and never
// through a shell. That script is the only thing that reads the API key, so the
// key never passes through QML or the shell's settings file.
//
// Glyphs are \u escapes so the source survives editors that mangle
// private-use codepoints.
Panel {
  id: root
  moduleName: "com.bulkpublish.omarchy"
  ipcTarget: "com.bulkpublish.omarchy"
  manageIpc: false

  readonly property string script:
    Qt.resolvedUrl("bin/bulkpublish").toString().replace(/^file:\/\//, "")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property int refreshMinutes: setting("refreshMinutes", 10)
  readonly property int recentCount: setting("recentCount", 6)

  // "" before the first answer, then "signed-out", "ready" or "error".
  property string connState: ""
  property string errorText: ""
  property string notice: ""
  property var channels: []
  property var posts: []
  property var selected: ({})
  property bool sending: false

  // What the main button does: "now", "queue" (the next free slot in the
  // posting schedule set in BulkPublish) or "at" (a time typed in whenInput).
  property string postWhen: "now"
  // How the typed time was understood, e.g. "Fri 30 Oct, 09:00", or why not.
  property string whenLabel: ""
  property string whenError: ""

  // Local paths of the files to attach, in the order they will appear.
  property var attachments: []
  readonly property var mediaExtensions:
    ["jpg", "jpeg", "png", "webp", "gif", "mp4", "m4v", "mov", "webm", "pdf", "doc", "docx", "ppt", "pptx"]

  readonly property int selectedCount: {
    var n = 0
    for (var k in selected) if (selected[k]) n++
    return n
  }
  readonly property bool hasFailed: {
    for (var i = 0; i < posts.length; i++)
      if (posts[i].status === "failed" || posts[i].status === "partial") return true
    return false
  }

  // Text from the network is never allowed to look like markup: a Text in
  // rich mode would fetch <img src> from inside the shell process.
  function plain(s) {
    return String(s === undefined || s === null ? "" : s).replace(/[<>]/g, "")
  }

  function parse(text) {
    try { return JSON.parse(text) } catch (e) { return { ok: false, error: "Unexpected answer from BulkPublish." } }
  }

  function run(proc, args) {
    if (proc.running) return
    proc.command = [root.script].concat(args)
    proc.running = true
  }

  function refresh() {
    root.run(channelsProc, ["channels"])
    root.run(postsProc, ["posts", String(root.recentCount)])
  }

  function toggleChannel(id) {
    var next = Object.assign({}, selected)
    next[id] = !next[id]
    selected = next
  }

  function fileName(path) {
    return String(path).split("/").pop()
  }

  // Add files from the picker or a drop. Duplicates are skipped, and so is
  // anything BulkPublish cannot post, with a note saying which.
  function attach(paths) {
    var next = attachments.slice()
    var skipped = []
    for (var i = 0; i < paths.length; i++) {
      var p = String(paths[i])
      if (p.indexOf("file://") === 0) p = decodeURIComponent(p.slice(7))
      if (p === "" || next.indexOf(p) !== -1) continue
      var ext = p.split(".").pop().toLowerCase()
      if (mediaExtensions.indexOf(ext) === -1) { skipped.push(fileName(p)); continue }
      next.push(p)
    }
    attachments = next
    notice = skipped.length ? root.plain("Can't post " + skipped.join(", ")
      + ". Use images, videos (MP4, MOV, WebM), or PDF, Word or PowerPoint files.") : ""
  }

  function detach(path) {
    attachments = attachments.filter(function(p) { return p !== path })
  }

  function send(mode) {
    var ids = []
    for (var k in selected) if (selected[k]) ids.push(k)
    if (composer.text.trim() === "" && attachments.length === 0) { notice = "Write something or add media first."; return }
    if (ids.length === 0) { notice = "Pick at least one channel."; return }
    if (mode === "at" && whenLabel === "") {
      notice = whenError
        || (whenInput.text.trim() !== "" ? "Still reading that time. Try again in a moment."
                                         : "Type when to post it, like tomorrow 9:00.")
      return
    }
    if (sendProc.running) return
    notice = ""
    sending = true
    sendProc.mode = mode
    // Text and file paths go in on stdin, never in argv: another local account
    // can read any process's command line while it runs.
    sendProc.pendingText = JSON.stringify({ text: composer.text, files: attachments })
    sendProc.stdinEnabled = true
    run(sendProc, ["send", mode, ids.join(",")].concat(mode === "at" ? [whenInput.text] : []))
  }

  // Ask the helper how the typed time reads, so the user sees the exact date
  // before anything is scheduled. Local only: no request leaves the machine.
  function checkWhen() {
    if (whenProc.running) { whenDebounce.restart(); return }
    whenProc.asked = whenInput.text
    root.run(whenProc, ["when", whenInput.text])
  }

  function openApp(path) {
    run(openProc, ["open", path || "/"])
    root.close()
  }

  function statusLabel(s) {
    var names = { draft: "Draft", scheduled: "Scheduled", publishing: "Publishing",
                  processing: "Processing", published: "Published", partial: "Partly failed",
                  failed: "Failed" }
    return names[s] || s
  }

  function when(iso) {
    if (!iso) return ""
    var d = new Date(iso)
    if (isNaN(d.getTime())) return ""
    return Qt.formatDateTime(d, "d MMM, hh:mm")
  }

  function platformLabel(p) {
    var names = { x: "X", gmb: "Google Business", linkedin: "LinkedIn", tiktok: "TikTok", youtube: "YouTube" }
    return names[p] || (p.charAt(0).toUpperCase() + p.slice(1))
  }

  // ------------------------------------------------------------ processes

  Process {
    id: channelsProc
    stdout: StdioCollector {
      onStreamFinished: {
        var data = root.parse(text)
        if (data.ok !== true) {
          root.errorText = root.plain(data.error)
          root.connState = /login/.test(data.error || "") ? "signed-out" : "error"
          return
        }
        root.errorText = ""
        root.connState = "ready"
        root.channels = data.channels || []
        // Drop selections for channels that have gone.
        var keep = {}
        for (var i = 0; i < root.channels.length; i++) {
          var id = root.channels[i].id
          if (root.selected[id] && root.channels[i].problem === "") keep[id] = true
        }
        root.selected = keep
      }
    }
  }

  Process {
    id: postsProc
    stdout: StdioCollector {
      onStreamFinished: {
        var data = root.parse(text)
        if (data.ok === true) root.posts = data.posts || []
      }
    }
  }

  Process {
    id: sendProc
    property string mode: ""
    property string pendingText: ""
    onStarted: {
      sendProc.write(sendProc.pendingText)
      sendProc.pendingText = ""
      sendProc.stdinEnabled = false   // closes stdin, so the script sees end of input
    }
    stdout: StdioCollector {
      onStreamFinished: {
        root.sending = false
        var data = root.parse(text)
        if (data.ok !== true) { root.notice = root.plain(data.error); return }
        composer.text = ""
        root.attachments = []
        root.notice = sendProc.mode === "now" ? "Sent. It's publishing now."
          : sendProc.mode === "draft" ? "Saved as a draft."
          : "Scheduled for " + root.plain(data.label) + "."
        if (sendProc.mode === "at") whenInput.text = ""
        root.run(postsProc, ["posts", String(root.recentCount)])
      }
    }
  }

  Process {
    id: retryProc
    stdout: StdioCollector {
      onStreamFinished: {
        var data = root.parse(text)
        root.notice = data.ok === true ? "Retrying the failed destinations." : root.plain(data.error)
        root.run(postsProc, ["posts", String(root.recentCount)])
      }
    }
  }

  Process { id: openProc }

  Process {
    id: pickProc
    stdout: StdioCollector {
      onStreamFinished: {
        var data = root.parse(text)
        if (data.ok !== true) { root.notice = root.plain(data.error); return }
        root.attach(data.files || [])
        // The picker took focus away; bring the panel back with the files on it.
        root.open()
      }
    }
  }

  Process {
    id: whenProc
    property string asked: ""
    stdout: StdioCollector {
      onStreamFinished: {
        // The user kept typing: this answer is for text that is gone.
        if (whenProc.asked !== whenInput.text) return
        var data = root.parse(text)
        root.whenLabel = data.ok === true ? root.plain(data.label) : ""
        root.whenError = data.ok === true ? "" : root.plain(data.error)
      }
    }
  }

  Timer {
    id: whenDebounce
    interval: 300
    onTriggered: root.checkWhen()
  }

  Timer {
    interval: Math.max(1, root.refreshMinutes) * 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onOpenedChanged: {
    if (opened) {
      notice = ""
      refresh()
      Qt.callLater(function() { composer.forceActiveFocus() })
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function status(): string { return root.connState }
  }

  // ------------------------------------------------------------------ bar

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // nf-fa-paper_plane
    text: ""
    active: root.hasFailed
    dimmed: root.connState === "signed-out" || root.connState === "error"
    tooltipText: root.connState === "signed-out" ? "BulkPublish: not signed in"
      : root.connState === "error" ? root.plain("BulkPublish: " + root.errorText)
      : root.hasFailed ? "BulkPublish: a recent post failed"
      : "BulkPublish"
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.openApp("/compose")
      else if (b === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  // ---------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(body.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: composer.activeFocus || whenInput.activeFocus
      onCloseRequested: root.close()
      onTabRequested: function(direction) { composer.forceActiveFocus() }

      Flickable {
        anchors.fill: parent
        contentHeight: body.implicitHeight
        clip: true

        Column {
          id: body
          width: parent.width
          spacing: Style.space(10)

          Text {
            text: "BulkPublish"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            textFormat: Text.PlainText
          }

          // -------------------------------------------- not signed in

          Column {
            visible: root.connState === "signed-out" || root.connState === "error"
            width: parent.width
            spacing: Style.space(6)
            Text {
              width: parent.width
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              color: root.connState === "error" ? Color.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              text: root.connState === "signed-out"
                ? "Connect your BulkPublish account. Create an API key in BulkPublish on its API page, then run this in a terminal and paste it:"
                : root.errorText
            }
            Text {
              visible: root.connState === "signed-out"
              width: parent.width
              wrapMode: Text.WrapAnywhere
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              text: root.script + " login"
            }
            Row {
              spacing: Style.space(8)
              Button {
                text: "Open API keys"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.openApp("/developer")
              }
              Button {
                text: "Try again"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.refresh()
              }
            }
          }

          // ------------------------------------------------- composer

          Column {
            visible: root.connState === "ready"
            width: parent.width
            spacing: Style.space(8)

            Rectangle {
              width: parent.width
              height: Math.max(Style.space(90), composer.contentHeight + Style.space(16))
              color: "transparent"
              border.color: composer.activeFocus || drop.containsDrag ? root.foreground : root.dim
              border.width: drop.containsDrag ? 2 : 1
              radius: Style.space(4)

              // Files dragged in from the file manager are attached.
              DropArea {
                id: drop
                anchors.fill: parent
                keys: ["text/uri-list"]
                onDropped: function(event) {
                  if (!event.hasUrls) return
                  root.attach(event.urls)
                  event.acceptProposedAction()
                }
              }

              TextEdit {
                id: composer
                anchors.fill: parent
                anchors.margins: Style.space(8)
                wrapMode: TextEdit.Wrap
                textFormat: TextEdit.PlainText
                selectByMouse: true
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                Keys.onEscapePressed: function(event) {
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
                // Ctrl+Enter does what the main button does, the way most
                // composers do.
                Keys.onReturnPressed: function(event) {
                  if (event.modifiers & Qt.ControlModifier) { root.send(root.postWhen); event.accepted = true }
                  else event.accepted = false
                }
              }
              Text {
                visible: composer.text === "" && !composer.activeFocus
                anchors.fill: composer
                text: "What do you want to post? Drop images or videos here."
                wrapMode: Text.Wrap
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                textFormat: Text.PlainText
              }
            }

            // Attached files, each removable, then the button that adds more.
            Flow {
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: root.attachments
                Button {
                  required property var modelData
                  text: root.plain(root.fileName(modelData)) + "  ×"
                  enabled: !root.sending
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.detach(modelData)
                }
              }
              Button {
                text: pickProc.running ? "Choosing…" : "+ Add media"
                enabled: !root.sending && !pickProc.running
                opacity: enabled ? 1 : 0.45
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                onClicked: root.run(pickProc, ["pick"])
              }
            }

            Text {
              text: "CHANNELS  " + root.selectedCount + "/" + root.channels.length
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
            }

            Text {
              visible: root.channels.length === 0
              width: parent.width
              wrapMode: Text.Wrap
              text: "No channels connected yet. Connect one in BulkPublish first."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: root.channels
                Button {
                  required property var modelData
                  text: root.plain(root.platformLabel(modelData.platform) + " · " + modelData.name
                    + (modelData.problem ? " (" + modelData.problem + ")" : ""))
                  enabled: modelData.problem === ""
                  opacity: enabled ? 1 : 0.45
                  selected: !!root.selected[modelData.id]
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: root.toggleChannel(modelData.id)
                }
              }
            }

            Text {
              text: "WHEN"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
            }

            Flow {
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: [
                  { key: "now", label: "Now" },
                  { key: "queue", label: "Next queue slot" },
                  { key: "at", label: "Pick a time" }
                ]
                Button {
                  required property var modelData
                  text: modelData.label
                  selected: root.postWhen === modelData.key
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  onClicked: {
                    root.postWhen = modelData.key
                    if (modelData.key === "at") Qt.callLater(function() { whenInput.forceActiveFocus() })
                  }
                }
              }
            }

            Rectangle {
              visible: root.postWhen === "at"
              width: parent.width
              height: whenInput.implicitHeight + Style.space(12)
              color: "transparent"
              border.width: 1
              border.color: whenInput.activeFocus ? root.foreground : root.dim
              radius: Style.space(4)

              TextInput {
                id: whenInput
                anchors.fill: parent
                anchors.margins: Style.space(6)
                verticalAlignment: TextInput.AlignVCenter
                selectByMouse: true
                clip: true
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                onTextChanged: {
                  root.whenLabel = ""
                  root.whenError = ""
                  if (text.trim() !== "") whenDebounce.restart()
                  else whenDebounce.stop()
                }
                Keys.onEscapePressed: function(event) {
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                }
                Keys.onReturnPressed: function(event) {
                  root.send("at")
                  event.accepted = true
                }
              }
              Text {
                visible: whenInput.text === ""
                anchors.fill: whenInput
                verticalAlignment: Text.AlignVCenter
                text: "tomorrow 9:00, fri 14:30, 2026-11-03 18:00"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
              }
            }

            Text {
              visible: root.postWhen === "at" && (root.whenLabel !== "" || root.whenError !== "")
              width: parent.width
              wrapMode: Text.Wrap
              text: root.whenLabel !== "" ? "Posts " + root.whenLabel + ", your time" : root.whenError
              color: root.whenLabel !== "" ? root.foreground : Color.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
            }

            Row {
              spacing: Style.space(8)
              Button {
                text: root.sending ? (root.attachments.length ? "Uploading…" : "Sending…")
                  : root.postWhen === "queue" ? "Add to queue"
                  : root.postWhen === "at" ? "Schedule"
                  : "Post now"
                enabled: !root.sending
                opacity: enabled ? 1 : 0.45
                selected: true
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.send(root.postWhen)
              }
              Button {
                text: "Save draft"
                enabled: !root.sending
                opacity: enabled ? 1 : 0.45
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.send("draft")
              }
              Button {
                text: "Open BulkPublish"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                onClicked: root.openApp("/compose")
              }
            }

            Text {
              visible: root.notice !== ""
              width: parent.width
              wrapMode: Text.Wrap
              text: root.notice
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }
          }

          // --------------------------------------------- recent posts

          Column {
            visible: root.connState === "ready" && root.posts.length > 0
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: "RECENT POSTS"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              textFormat: Text.PlainText
            }

            Repeater {
              model: root.posts
              Column {
                id: postRow
                required property var modelData
                readonly property bool failed: modelData.status === "failed" || modelData.status === "partial"
                width: parent.width
                spacing: Style.space(2)

                Text {
                  width: parent.width
                  elide: Text.ElideRight
                  text: root.plain(modelData.content || "(no text)")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  textFormat: Text.PlainText
                }
                Row {
                  spacing: Style.space(8)
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.plain(root.statusLabel(modelData.status)
                      + (root.when(modelData.at) ? " · " + root.when(modelData.at) : "")
                      + (modelData.platforms.length ? " · " + modelData.platforms.map(root.platformLabel).join(", ") : ""))
                    color: postRow.failed ? Color.urgent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    textFormat: Text.PlainText
                  }
                  Button {
                    visible: postRow.failed
                    text: "Retry"
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    onClicked: root.run(retryProc, ["retry", String(modelData.id)])
                  }
                }
                Text {
                  visible: postRow.failed && modelData.error !== ""
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: root.plain(modelData.error)
                  color: Color.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                }
              }
            }
          }
        }
      }
    }
  }
}
