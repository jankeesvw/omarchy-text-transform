import QtQuick
import QtQuick.Controls
import QtQuick.Shapes
import Quickshell.Io
import qs.Commons
import qs.Ui

// Text Transform: paste text, pick a transformation, get the result back.
//
// The transforming is done by whichever coding agent Omarchy is already set up
// with, through `bin/text-transform`. That is the whole design: someone who
// installs this has already picked an agent and is already paying for its
// tokens, so there is no API key to enter and no model to choose.
//
// Structured after the stock Basecamp plugin: a Panel root owning the
// open/close lifecycle, a BarIconButton for the bar, and a KeyboardPanel for
// the popup. KeyboardPanel matters specifically because PopupCard is a
// PopupWindow, which never receives keyboard focus on Wayland, so a text field
// inside one can be clicked but not typed into, and this panel is two text
// fields and little else.
//
// Everything in the panel is reachable and operable without a mouse: Tab walks
// a ring over the two text boxes, the dropdown and every button, Enter or space
// presses whatever is focused, Ctrl+Enter runs or stops a transform from
// anywhere, and Escape closes. That rules out PanelKeyCatcher here; see the
// comment on the key catcher below for why a form needs the other pattern.
//
// Glyphs are \u escapes rather than literal characters, so the source survives
// editors and patches that mangle private-use codepoints.
Panel {
  id: root

  moduleName: "jankeesvw.text-transform"
  ipcTarget: "jankeesvw.text-transform"

  // Panel's own IpcHandler is switched off so this file can add `paste` to the
  // same target. Two handlers on one target is one too many, so the five it
  // would have given us are repeated below.
  manageIpc: false

  // The script that does the talking sits next to this file, so the plugin
  // runs from wherever it was installed without putting anything on $PATH.
  readonly property string script:
    Qt.resolvedUrl("bin/text-transform").toString().replace(/^file:\/\//, "")

  readonly property string iconWand: "\uF0EC"
  readonly property string iconRun: "\uF063"
  readonly property string iconCopy: "\uF0C5"
  readonly property string iconPaste: "\uF0EA"
  readonly property string iconReuse: "\uF062"
  readonly property string iconSettings: "\uF013"
  readonly property string iconAdd: "\uF067"
  readonly property string iconRemove: "\uF1F8"
  readonly property string iconDone: "\uF00C"
  readonly property string iconStop: "\uF04D"
  // The same chevron every other dropdown in the shell draws. Past U+FFFF, so
  // it is written as the surrogate pair rather than as the character itself.
  readonly property string iconChevron: "\udb80\udd40"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // [{ name, prompt, autoCopy }], as the script hands them over.
  property var transformations: []
  property int selectedIndex: 0
  property string inputText: ""
  property string outputText: ""
  property string errorText: ""
  property bool busy: false
  property bool copied: false
  // Captured at the start of a run, so editing settings while it is running
  // cannot change what happens to that answer.
  property bool runningAutoCopy: true
  // A result that landed while the panel was closed, so the bar can say so.
  property bool resultWaiting: false
  // Set while a stop is on its way, so the empty answer that follows is read
  // as "you stopped it" rather than as a failure worth reporting.
  property bool cancelled: false

  // Which agent is going to do the work, so the panel can name it and say so
  // when there is nothing to do the work with.
  property string agentLabel: ""
  property bool agentReady: false
  property string agentProblem: ""

  // The settings view replaces the main view in the same card rather than
  // opening a second one: it edits the list the main view selects from, and
  // two surfaces for one thing is one too many.
  property bool settingsOpen: false

  readonly property var currentTransformation:
    selectedIndex >= 0 && selectedIndex < transformations.length
      ? transformations[selectedIndex]
      : null

  readonly property bool canRun:
    agentReady && !busy && currentTransformation !== null
    && inputText.trim().length > 0

  // Panel is a bare Item, so it has no size of its own and the bar would give
  // the widget zero width. Set it here, never from a child that fills this
  // item: that is a loop where nothing decides the size and everything
  // collapses to zero.
  readonly property int barSlot: Style.bar.iconFont + Style.space(14)
  implicitWidth: bar && bar.vertical ? (bar ? bar.barSize : Style.bar.sizeHorizontal) : barSlot
  implicitHeight: bar && bar.vertical ? barSlot : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  // Strip the markup characters out of anything the agent produced before it
  // reaches a Text element the shell owns. Ours are all PlainText, but the
  // shared bar tooltip is the shell's component and its textFormat is not
  // ours to set.
  function plain(value) {
    return String(value || "").replace(/[<>]/g, "")
  }

  function refreshAgent() {
    if (!agentProc.running) agentProc.running = true
  }

  function loadTransformations() {
    if (!listProc.running) listProc.running = true
  }

  function applyTransformations(list) {
    var wanted = currentTransformation ? currentTransformation.name : ""
    transformations = list

    // Keep the selection on the same transformation across a reload, since
    // editing the list in settings rebuilds it wholesale.
    selectedIndex = 0
    if (wanted !== "") {
      for (var i = 0; i < list.length; i++) {
        if (String(list[i].name) === wanted) {
          selectedIndex = i
          break
        }
      }
    }
  }

  function runTransform() {
    if (!canRun) return
    errorText = ""
    outputText = ""
    copied = false
    cancelled = false
    runningAutoCopy = currentTransformation.autoCopy !== false
    busy = true
    runProc.request = JSON.stringify({
      text: inputText,
      prompt: String(currentTransformation.prompt)
    })
    // onStarted closes stdin to signal end of input, and that sticks: without
    // this the second run has no stdin and the script waits forever on it.
    runProc.stdinEnabled = true
    runProc.running = true
  }

  function cancelTransform() {
    if (!busy) return
    cancelled = true
    runProc.signal(15)   // SIGTERM; the script traps it and takes the agent with it
  }

  function notify(title, body) {
    notifyProc.command = ["notify-send", "--app-name=Text Transform",
                          "--icon=accessories-text-editor", "--", title, body]
    notifyProc.running = true
  }

  // Pull the clipboard into the input box. Ctrl+V does this too, but the
  // panel opens with the mouse as often as not, and the button is where
  // someone looks for it.
  function pasteInput() {
    if (!pasteProc.running) pasteProc.running = true
  }

  // Set while a keybinding is opening the panel on the clipboard, so the paste
  // that comes back lands the focus on the run button rather than in the input
  // box. Then the whole thing is one key to open and one to go.
  property bool openedForClipboard: false

  // The `transform` IPC method goes one further than `paste`: it also presses
  // the button. The first flag makes the paste that comes back start the run;
  // the second closes the panel again when the answer lands, since the result
  // is on the clipboard by then and there is nothing left to look at. A
  // failure clears it instead, so the panel stays open on the error.
  property bool transformOnPaste: false
  property bool closeWhenDone: false

  // The `replace` IPC method goes further still: it copies the selection out
  // of the active window itself, transforms it, and pastes the answer back
  // over the selection. The window is remembered by address so the paste finds
  // it even if the focus moved while the agent was thinking.
  property bool replaceWhenDone: false
  property string replaceWindow: ""

  // What the `paste` IPC method does: open, fill the input from the clipboard,
  // and leave the cursor on the button. The paste is a process, so the focus
  // cannot be set here; pasteProc does it when the text actually arrives.
  //
  // A bar widget exists once per monitor and all of those copies register the
  // same IPC target, so the call arrives at whichever one claimed it rather
  // than at the one you are looking at. The bar already answers that question
  // for `shell summon`, so ask it the same way and hand the work over.
  function pasteAndArm() {
    var chosen = bar && typeof bar.findPanelWidget === "function"
      ? bar.findPanelWidget(moduleName)
      : null
    if (chosen && chosen !== root && typeof chosen.pasteAndArm === "function") {
      chosen.pasteAndArm()
      return
    }
    openedForClipboard = true
    if (!opened) open()
    pasteInput()
  }

  // What the `transform` IPC method does: everything `paste` does, and then
  // run the last-used transformation on it without waiting for Enter. The
  // panel opens so the spinner and a possible error have somewhere to be seen.
  function transformClipboard() {
    var chosen = bar && typeof bar.findPanelWidget === "function"
      ? bar.findPanelWidget(moduleName)
      : null
    if (chosen && chosen !== root && typeof chosen.transformClipboard === "function") {
      chosen.transformClipboard()
      return
    }
    // A second press while a run is going opens the panel on the spinner
    // instead of quietly queueing nothing.
    if (busy) {
      if (!opened) open()
      return
    }
    transformOnPaste = true
    pasteAndArm()
  }

  // What the `replace` IPC method does: copy the selection out of the window
  // the keybinding was pressed in, transform it, and paste the answer back
  // over it. The grab has to run before the panel opens, because the panel
  // takes the keyboard focus and the copy needs it where the selection is;
  // grabProc opens the panel when the text is in.
  function replaceSelection() {
    var chosen = bar && typeof bar.findPanelWidget === "function"
      ? bar.findPanelWidget(moduleName)
      : null
    if (chosen && chosen !== root && typeof chosen.replaceSelection === "function") {
      chosen.replaceSelection()
      return
    }
    if (busy) {
      if (!opened) open()
      return
    }
    if (grabProc.running) return
    grabProc.running = true
  }

  // Send the answer back up to the input, so it can be run through another
  // transformation, or the same one again. Shortening something twice is a
  // different thing from asking for it very short once.
  //
  // The output box is emptied on the way: the same text sitting in both boxes
  // reads as a transform that did nothing.
  function reuseOutput() {
    if (outputText === "") return
    var text = outputText
    inputText = text
    inputField.text = text
    outputText = ""
    errorText = ""
    copied = false
    inputField.forceActiveFocus()
    inputField.cursorPosition = text.length
  }

  function copyOutput() {
    if (outputText === "") return
    copyProc.payload = outputText
    copyProc.stdinEnabled = true
    copyProc.running = true
    copied = true
    copiedTimer.restart()
  }

  // Settings edit a copy, so abandoning them by closing the panel leaves the
  // saved list alone.
  //
  // A ListModel rather than a JavaScript array, because the rows write back
  // into it on every keystroke: replacing an array reassigns the Repeater's
  // model, which rebuilds every delegate mid-word and is a binding loop
  // besides. setProperty touches one field and leaves the rows standing.
  function openSettings() {
    draft.clear()
    for (var i = 0; i < transformations.length; i++) {
      draft.append({ name: String(transformations[i].name),
                     prompt: String(transformations[i].prompt),
                     autoCopy: transformations[i].autoCopy !== false })
    }
    settingsOpen = true

    // The main view is about to go invisible, and an item that loses its
    // visibility loses the focus with it, leaving the keyboard pointed at
    // nothing. Hand it to the button that is on screen in both views.
    settingsButton.forceActiveFocus()
  }

  function updateDraft(index, field, value) {
    if (index < 0 || index >= draft.count) return
    if (draft.get(index)[field] === value) return
    draft.setProperty(index, field, value)
  }

  // Drag the settings window to whatever just took the keyboard. Tabbing to a
  // field below the fold otherwise types into something you cannot see, which
  // reads as the panel having stopped responding.
  //
  // `y` and `h` are inside `item`, so the same call covers both a whole field
  // and the one line of it the cursor is on.
  function revealInDrafts(item, y, h) {
    if (!item || !draftFlick.visible || draftFlick.contentHeight <= draftFlick.height) return
    var margin = Style.space(8)
    var top = item.mapToItem(draftColumn, 0, y).y - margin
    var bottom = top + h + margin * 2
    if (top < draftFlick.contentY) {
      draftFlick.contentY = Math.max(0, top)
    } else if (bottom > draftFlick.contentY + draftFlick.height) {
      draftFlick.contentY = Math.max(0, Math.min(bottom - draftFlick.height,
                                                 draftFlick.contentHeight - draftFlick.height))
    }
  }

  function addDraft() {
    draft.append({ name: "New transformation", prompt: "", autoCopy: true })

    // The row does not exist yet: appending to the model builds the delegate
    // after this returns. So scrolling to it and naming it have to wait a
    // turn, or they land on the row that used to be last.
    Qt.callLater(function() {
      draftFlick.contentY = Math.max(0, draftFlick.contentHeight - draftFlick.height)
      var row = draftRepeater.itemAt(draft.count - 1)
      if (row && row.nameField) {
        row.nameField.forceActiveFocus()
        row.nameField.selectAll()
      }
    })
  }

  function removeDraft(index) {
    if (index < 0 || index >= draft.count) return
    draft.remove(index)
  }

  function saveSettings() {
    settingsOpen = false
    inputField.forceActiveFocus()
    var list = []
    for (var i = 0; i < draft.count; i++) {
      var item = draft.get(i)
      list.push({ name: String(item.name), prompt: String(item.prompt),
                  autoCopy: item.autoCopy !== false })
    }
    saveProc.request = JSON.stringify({ transformations: list })
    saveProc.stdinEnabled = true
    saveProc.running = true
  }

  // Panel's own close() is what actually hides the card, so this override has
  // to end by calling it: replacing it outright leaves Escape, the bar button
  // and `omarchy-shell shell hide` all doing nothing but tidying up.
  //
  // Whatever is running keeps running. A transform takes seconds and there is
  // no reason to sit and watch it; the bar shows it is working and says so
  // again when the answer lands.
  function close() {
    // Leaving settings half-edited would lose the edits silently, so closing
    // the panel commits them the same way the done button does.
    if (settingsOpen) saveSettings()
    dropdown.close()
    errorText = ""
    // Closing by hand takes over from a `transform` or `replace` keybinding:
    // the answer still lands on the clipboard, but it must not close a panel
    // that was reopened in the meantime, or paste into an app someone has
    // moved on from.
    transformOnPaste = false
    closeWhenDone = false
    replaceWhenDone = false
    replaceWindow = ""
    controller.hide()
  }

  Process {
    id: agentProc
    command: [root.script, "agent"]
    stdout: StdioCollector {
      onStreamFinished: {
        var payload
        try { payload = JSON.parse(text) } catch (e) { return }
        if (!payload || payload.ok !== true) return

        root.agentReady = payload.ready === true
        root.agentLabel = String(payload.label || "")

        if (root.agentReady) {
          root.agentProblem = ""
        } else if (payload.reason === "unset") {
          root.agentProblem = "No default agent yet. Pick one with: omarchy default agent"
        } else if (payload.reason === "missing") {
          root.agentProblem = root.agentLabel + " is not installed"
        } else if (payload.reason === "unsupported") {
          root.agentProblem = "This plugin cannot drive " + root.agentLabel + " without a terminal"
        } else {
          root.agentProblem = String(payload.reason || "The default agent is not ready")
        }
      }
    }
  }

  Process {
    id: listProc
    command: [root.script, "list"]
    stdout: StdioCollector {
      onStreamFinished: {
        var payload
        try { payload = JSON.parse(text) } catch (e) { return }
        if (!payload || payload.ok !== true) return
        root.applyTransformations(payload.transformations || [])
      }
    }
  }

  // The text being transformed goes in over stdin, never argv, so it stays out
  // of /proc/PID/cmdline where any account on the machine could read it.
  Process {
    id: runProc
    property string request: ""
    command: [root.script, "run"]
    stdinEnabled: true
    onStarted: {
      write(request)
      request = ""
      stdinEnabled = false
    }
    stdout: StdioCollector {
      onStreamFinished: {
        root.busy = false
        if (root.cancelled) {
          root.cancelled = false
          root.closeWhenDone = false
          root.replaceWhenDone = false
          root.replaceWindow = ""
          return
        }
        var payload
        try {
          payload = JSON.parse(text)
        } catch (e) {
          root.errorText = "Could not read the answer"
          root.closeWhenDone = false
          root.replaceWhenDone = false
          root.replaceWindow = ""
          return
        }
        var replace = false
        var replaceTarget = ""
        if (payload && payload.ok === true) {
          root.outputText = String(payload.output || "")
          root.errorText = ""

          if (root.replaceWhenDone) {
            // The answer goes back over the selection instead of only onto
            // the clipboard; putProc is started below, after the panel has
            // closed and the keyboard is back with the app. The window goes
            // into a local now, because the close on the way there wipes the
            // property: that wipe is what stops a manual close from pasting,
            // and this run has already earned its paste.
            root.replaceWhenDone = false
            replaceTarget = root.replaceWindow
            root.replaceWindow = ""
            replace = true
          } else if (root.runningAutoCopy) {
            // Straight onto the clipboard. Transforming text is a step on the
            // way to pasting it somewhere else, so making that a second click
            // only adds a click. The copy button stays for a second helping.
            root.copyOutput()

            // Said out loud even with the panel open, because the clipboard is
            // the part you cannot see. The text itself stays out of it: a
            // notification can end up on a lock screen.
            root.notify("Text Transform", "Transformed and copied to your clipboard")
          } else {
            // Questions often need reading rather than pasting. Keep the
            // answer in the panel and never put it on the clipboard. Unlike
            // the copy notification, this deliberately carries the result so
            // someone who has walked away can read the answer there.
            root.notify("Text Transform", root.plain(root.outputText))
          }
        } else {
          root.errorText = String((payload && payload.error) || "Something went wrong")

          // A run that was going to close the panel keeps it open instead:
          // closing on a failure would hide the one thing worth reading. The
          // same goes for pasting: a failure replaces nothing.
          root.closeWhenDone = false
          root.replaceWhenDone = false
          root.replaceWindow = ""

          // A failure with the panel open is already on screen in red, so
          // only tell the people who walked away.
          if (!root.opened) {
            root.notify("Text Transform failed", "Open the panel to see what went wrong.")
          }
        }

        // The run outlives the panel on purpose, so a result can arrive with
        // nobody looking, and the bar has to keep saying so until it is seen.
        // A replace delivers its result into the app, so nothing is waiting.
        if (!root.opened && !replace) root.resultWaiting = true

        // After the waiting check, not before: a panel that closes itself has
        // delivered its result, so the bar must not keep signalling one.
        if (root.closeWhenDone) {
          root.closeWhenDone = false
          if (root.opened) root.close()
        }

        // And only now the paste: on Wayland the clipboard offer follows the
        // keyboard focus, so the panel has to be out of the way before the
        // window the answer is going into gets its Ctrl+V.
        if (replace) {
          putProc.request = JSON.stringify({ text: root.outputText, window: replaceTarget })
          putProc.stdinEnabled = true
          putProc.running = true
        }
      }
    }
    onExited: {
      root.busy = false
      root.cancelled = false
    }
  }

  Process {
    id: saveProc
    property string request: ""
    command: [root.script, "save"]
    stdinEnabled: true
    onStarted: {
      write(request)
      request = ""
      stdinEnabled = false
    }
    onExited: root.loadTransformations()
  }

  Process {
    id: pasteProc
    command: ["wl-paste", "--no-newline"]
    stdout: StdioCollector {
      onStreamFinished: {
        // Whatever happens next, the clipboard opening is over: an empty
        // clipboard must not leave the flags set for the next ordinary paste.
        var arm = root.openedForClipboard
        var go = root.transformOnPaste
        root.openedForClipboard = false
        root.transformOnPaste = false
        if (text === "") return
        root.inputText = text
        inputField.text = text
        inputField.cursorPosition = text.length
        // KeyboardPanel focuses its focusTarget on open through Qt.callLater,
        // so hand the focus over the same way or that call lands after this
        // one and takes it back.
        if (arm) Qt.callLater(function() { runButton.forceActiveFocus() })
        else inputField.forceActiveFocus()
        // Auto-close is promised only once the run actually starts: if the
        // agent is not ready the panel stays open saying why, exactly as it
        // would after a manual paste.
        if (go && root.canRun) {
          root.closeWhenDone = root.currentTransformation.autoCopy !== false
          root.runTransform()
        }
      }
    }
  }

  // The selection grab for `replace`: a synthetic Ctrl+C into the active
  // window, the clipboard read back, all done by the script. Only when the
  // text is in does the panel open, so the copy happened while the app still
  // had the keyboard.
  Process {
    id: grabProc
    command: [root.script, "grab"]
    stdout: StdioCollector {
      onStreamFinished: {
        var payload
        try { payload = JSON.parse(text) } catch (e) { payload = null }
        if (!payload || payload.ok !== true) {
          if (!root.opened) root.open()
          root.errorText = String((payload && payload.error) || "Could not copy the selection")
          return
        }
        root.replaceWindow = String(payload.window || "")
        root.inputText = String(payload.text || "")
        inputField.text = root.inputText
        inputField.cursorPosition = root.inputText.length
        if (!root.opened) root.open()
        Qt.callLater(function() { runButton.forceActiveFocus() })
        if (root.canRun) {
          root.closeWhenDone = true
          root.replaceWhenDone = true
          root.runTransform()
        }
        // Not ready to run (no agent, say): the panel is now open and already
        // explains why, exactly as it would after a manual paste.
      }
    }
  }

  // The paste back for `replace`. The script puts the answer on the clipboard,
  // focuses the remembered window and sends it Ctrl+V; the text goes in over
  // stdin like everywhere else.
  Process {
    id: putProc
    property string request: ""
    command: [root.script, "put"]
    stdinEnabled: true
    onStarted: {
      write(request)
      request = ""
      stdinEnabled = false
    }
    stdout: StdioCollector {
      onStreamFinished: {
        var payload
        try { payload = JSON.parse(text) } catch (e) { payload = null }
        if (payload && payload.ok === true) {
          root.notify("Text Transform", "Transformed and pasted over your selection")
        } else {
          // The script copies before it pastes, so even here the answer is
          // safe on the clipboard and the notification can say so.
          root.notify("Text Transform",
                      String((payload && payload.error) || "Could not paste. The answer is on your clipboard"))
        }
      }
    }
  }

  // wl-copy takes the text on stdin for the same reason the script does.
  Process {
    id: copyProc
    property string payload: ""
    command: ["wl-copy"]
    stdinEnabled: true
    onStarted: {
      write(payload)
      payload = ""
      stdinEnabled = false
    }
  }

  Process { id: notifyProc }

  // The five Panel would have registered, plus the three this panel adds.
  //
  //   omarchy-shell jankeesvw.text-transform paste
  //
  // opens on whatever is on the clipboard with the run button focused, which
  // makes a keybinding one key to open and one to go.
  //
  //   omarchy-shell jankeesvw.text-transform transform
  //
  // presses the button too: the last-used transformation runs on the clipboard
  // straight away, and the panel closes itself once the answer is copied.
  //
  //   omarchy-shell jankeesvw.text-transform replace
  //
  // starts from the selection instead of the clipboard: it copies what is
  // selected in the active window, transforms it, and pastes the answer back
  // over the selection.
  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function paste(): void { root.pasteAndArm() }
    function transform(): void { root.transformClipboard() }
    function replace(): void { root.replaceSelection() }
  }

  ListModel { id: draft }

  Timer {
    id: copiedTimer
    interval: 1600
    onTriggered: root.copied = false
  }

  Component.onCompleted: {
    refreshAgent()
    loadTransformations()
  }

  // The default agent can change while the shell runs, and a panel that still
  // names the old one is worse than one that says nothing.
  onOpenedChanged: {
    if (opened) {
      refreshAgent()
      resultWaiting = false
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: root.barSlot
    tooltipText: {
      if (root.busy) return "Text Transform · working"
      if (root.resultWaiting) return "Text Transform · result ready"
      if (root.agentReady && root.agentLabel !== "")
        return "Text Transform · " + root.plain(root.agentLabel)
      return "Text Transform"
    }
    onPressed: function(b) { root.toggle() }

    // A transform runs for seconds and keeps running with the panel shut, so
    // the bar has to carry that state: there is nowhere else to see it.
    iconComponent: Component {
      Item {
        Text {
          id: barGlyph
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: root.iconWand
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
          renderType: Text.NativeRendering
          color: root.busy || root.resultWaiting || root.opened
            ? root.accent
            : root.foreground

          SequentialAnimation on opacity {
            running: root.busy
            loops: Animation.Infinite
            alwaysRunToEnd: true
            NumberAnimation { to: 0.35; duration: 700; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
          }
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    // Focus lands in the input box, so the panel opens ready to paste.
    focusTarget: inputField

    // Plain property reads rather than fittedContentWidth, which is evaluated
    // once on open and would not follow a panel that resizes while it is up.
    readonly property int desiredWidth: Style.space(420)
    contentWidth: Math.min(desiredWidth,
                           panel.availableCardWidth > 0 ? panel.availableCardWidth : desiredWidth)
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(760))

    // A plain Item rather than PanelKeyCatcher. That component reads keys
    // before its descendants and turns Tab, Enter and Space into signals of
    // its own, which is right for a panel that is a list of rows and wrong for
    // one that is a form: every button here could be reached with Tab and none
    // of them could be pressed, because the catcher ate the Enter first.
    //
    // An ancestor Item only sees the keys the focused control did not want, so
    // Tab walks the controls the way Qt already knows how to, Enter presses
    // whatever is focused, and this handler keeps just the two keys that have
    // to work from anywhere in the panel.
    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
        } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                   && (event.modifiers & Qt.ControlModifier)) {
          // The same keystroke that started it stops it, so a run that hangs
          // needs no reaching for the mouse. In settings it commits instead:
          // there is nothing to transform while the list is being edited.
          if (root.settingsOpen) root.saveSettings()
          else if (root.busy) root.cancelTransform()
          else root.runTransform()
          event.accepted = true
        }
      }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(8)

        // --- header ---------------------------------------------------------

        Item {
          width: parent.width
          height: Math.max(title.implicitHeight, settingsButton.height)

          Text {
            id: title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.settingsOpen ? "Transformations" : "Text Transform"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            anchors.right: settingsButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.settingsOpen && root.agentLabel !== ""
            textFormat: Text.PlainText
            text: root.agentLabel
            color: Qt.darker(root.foreground, 1.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelActionButton {
            id: settingsButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            focusable: true
            iconText: root.settingsOpen ? root.iconDone : root.iconSettings
            tooltipText: root.settingsOpen ? "Done" : "Edit transformations"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.settingsOpen ? root.saveSettings() : root.openSettings()
          }
        }

        // --- main view ------------------------------------------------------

        // Input. One box you can paste a paragraph into; Ctrl+Enter runs it,
        // because plain Enter has to stay a line break in text this long.
        Rectangle {
          visible: !root.settingsOpen
          width: parent.width
          height: Style.space(120)
          radius: Style.cornerRadius
          color: Style.controlFill(inputField.activeFocus, false, root.foreground, root.accent)
          border.width: 1
          border.color: inputField.activeFocus
            ? root.accent
            : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

          ScrollView {
            anchors.fill: parent
            anchors.margins: Style.space(6)
            anchors.bottomMargin: Style.space(30)
            clip: true

            TextArea {
              id: inputField
              text: root.inputText
              onTextChanged: root.inputText = text
              wrapMode: TextArea.Wrap
              textFormat: TextEdit.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              color: root.foreground
              selectionColor: Style.selectionFillFor(root.foreground, root.accent)
              selectedTextColor: root.foreground
              placeholderText: "Paste or type the text here"
              placeholderTextColor: Qt.darker(root.foreground, 1.6)
              background: null

              // Without this a TextArea is not a stop on the Tab ring at all.
              // You could tab out of it and never tab back in, which is a
              // dead end in the one control the panel opens on.
              activeFocusOnTab: true

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                  // A TextArea would otherwise insert a literal tab, and this
                  // is a form: Tab has to walk to the next control.
                  inputField.nextItemInFocusChain(event.key === Qt.Key_Tab).forceActiveFocus()
                  event.accepted = true
                }
                // Ctrl+Enter and Escape fall through to the key catcher, so
                // they mean the same thing here as anywhere else in the panel.
              }
            }
          }

          PanelActionButton {
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(4)
            focusable: true
            iconText: root.iconPaste
            tooltipText: "Paste from clipboard"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.pasteInput()
          }
        }

        // Transformation and the button that fires it. The arrow points down
        // because that is where the answer lands.
        Item {
          visible: !root.settingsOpen
          width: parent.width
          height: Math.max(dropdown.height, runButton.height)

          // The shared Dropdown, with the arithmetic that decides how tall the
          // open list is put right. That component measures the rows and
          // forgets the frame around them, so the last transformation you
          // wrote is sliced off along the bottom edge, and it stops growing at
          // eight rows however many you have written. Everything else here is
          // the same component: same chrome, same keys.
          Item {
            id: dropdown
            anchors.left: parent.left
            anchors.right: runButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            height: Style.spacing.controlHeight

            // Past this it scrolls. Ten is about as far down a panel as a list
            // can hang before it stops looking like it belongs to the box it
            // came out of.
            readonly property int maxVisibleRows: 10

            // root.close() calls this: closing the panel with the list hanging
            // open would leave the list on screen with nothing behind it.
            function close() { picker.close() }

            BorderSurface {
              id: trigger
              anchors.fill: parent
              radius: Style.cornerRadius
              activeFocusOnTab: true

              readonly property bool hot: triggerHover.hovered
              color: Style.controlFill(trigger.activeFocus, trigger.hot, root.foreground, root.accent)
              borderSpec: Border.controlSpec(
                trigger.activeFocus ? "focus" : (trigger.hot ? "hover-cursor" : "normal"),
                root.foreground, root.accent)

              HoverHandler { id: triggerHover }

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                    || event.key === Qt.Key_Space || event.key === Qt.Key_Down) {
                  picker.opened ? picker.close() : picker.open()
                  event.accepted = true
                }
              }

              Text {
                anchors.left: parent.left
                anchors.right: chevron.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: trigger.borderLeft + Style.spacing.controlPaddingX
                anchors.rightMargin: Style.spacing.md
                textFormat: Text.PlainText
                text: root.currentTransformation ? String(root.currentTransformation.name) : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                id: chevron
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.rightMargin: trigger.borderRight + Style.spacing.controlGap
                textFormat: Text.PlainText
                text: root.iconChevron
                color: Qt.darker(root.foreground, 1.2)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  trigger.forceActiveFocus()
                  picker.opened ? picker.close() : picker.open()
                }
              }

              Popup {
                id: picker
                x: 0
                y: trigger.height + Style.spacing.xxs
                width: trigger.width
                focus: true

                readonly property var spec: Border.localOrSurfaceSpec(
                  "popups", "border", Color.popups.border, Color.popups.border, Style.normalBorderWidth)

                padding: Style.spacing.hairline
                leftPadding: Border.left(picker.spec) + Style.spacing.hairline
                rightPadding: Border.right(picker.spec) + Style.spacing.hairline
                topPadding: Border.top(picker.spec) + Style.spacing.hairline
                bottomPadding: Border.bottom(picker.spec) + Style.spacing.hairline

                // The whole repair: the rows, and then the frame they sit in.
                implicitHeight: optionList.implicitHeight + topPadding + bottomPadding

                background: BorderSurface {
                  color: Color.popups.background
                  borderSpec: picker.spec
                  radius: Style.cornerRadius
                }

                onOpened: {
                  optionList.currentIndex = root.selectedIndex
                  optionList.positionViewAtIndex(optionList.currentIndex, ListView.Contain)
                  optionList.forceActiveFocus()
                }
                // Nothing hands the focus back on its own, and the Tab ring is
                // broken until something does.
                onClosed: trigger.forceActiveFocus()

                contentItem: ListView {
                  id: optionList

                  readonly property int rowHeight: Style.spacing.popupRowHeight

                  spacing: Style.spacing.labelGap
                  clip: true
                  boundsBehavior: Flickable.StopAtBounds
                  model: root.transformations
                  currentIndex: -1
                  implicitHeight: Math.min(contentHeight,
                                           dropdown.maxVisibleRows * (rowHeight + spacing) - spacing)
                  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                  function choose(i) {
                    if (i < 0 || i >= root.transformations.length) return
                    root.selectedIndex = i
                    picker.close()
                  }

                  Keys.priority: Keys.BeforeItem
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) {
                      picker.close(); event.accepted = true
                    } else if (event.key === Qt.Key_Down || event.text === "j") {
                      optionList.currentIndex = Math.min(optionList.count - 1, optionList.currentIndex + 1)
                      event.accepted = true
                    } else if (event.key === Qt.Key_Up || event.text === "k") {
                      optionList.currentIndex = Math.max(0, optionList.currentIndex - 1)
                      event.accepted = true
                    } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                               || event.key === Qt.Key_Space) {
                      optionList.choose(optionList.currentIndex); event.accepted = true
                    }
                  }

                  delegate: Rectangle {
                    id: optionRow
                    required property var modelData
                    required property int index

                    width: optionList.width
                    height: optionList.rowHeight
                    radius: Style.cornerRadius
                    color: optionRow.index === optionList.currentIndex
                      ? Style.hoverFillFor(root.foreground, root.accent)
                      : "transparent"

                    Text {
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.spacing.controlPaddingX
                      anchors.rightMargin: Style.spacing.controlPaddingX
                      textFormat: Text.PlainText
                      text: String(optionRow.modelData.name)
                      color: optionRow.index === optionList.currentIndex
                        ? Style.hoverStateColor(root.foreground, root.accent)
                        : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }

                    MouseArea {
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onPositionChanged: optionList.currentIndex = optionRow.index
                      onClicked: optionList.choose(optionRow.index)
                    }
                  }
                }
              }
            }
          }

          // While it runs, the same button stops it. An agent left thinking
          // after you have given up is still spending your tokens, so this
          // kills the script and the agent under it rather than only hiding
          // the spinner.
          PanelActionButton {
            id: runButton

            // Whether there is anything to press it for. Not wired to
            // `enabled`, which is what it looks like it wants: Qt steps over
            // disabled items in the focus ring, and this is the one button the
            // whole panel is about. Dropping it out of the ring until you have
            // typed something means the ring changes shape as you type, and
            // the only way to find that out is to tab past where it should be.
            //
            // So it stays reachable and says with its colour that there is
            // nothing to run yet. Pressing it then does the one useful thing
            // left: put the cursor where the text has to go.
            readonly property bool armed: root.busy || root.canRun

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            focusable: true
            size: Style.spacing.controlHeight
            iconText: root.busy ? root.iconStop : root.iconRun
            tooltipText: root.busy
              ? "Stop"
              : (root.canRun ? "Transform (Ctrl+Enter)" : "Nothing to transform yet")
            foreground: armed ? root.foreground : Qt.darker(root.foreground, 2.0)
            hoverColor: root.busy
              ? Color.urgent
              : (armed ? root.foreground : Qt.darker(root.foreground, 2.0))
            fontFamily: root.fontFamily
            bordered: true
            onClicked: {
              if (root.busy) root.cancelTransform()
              else if (root.canRun) root.runTransform()
              else inputField.forceActiveFocus()
            }
          }
        }

        // Output. Selectable and read-only: it is an answer, not a draft, and
        // editing it here would be lost the moment the next run lands.
        Rectangle {
          visible: !root.settingsOpen
          width: parent.width
          height: Style.space(140)
          radius: Style.cornerRadius
          color: Style.controlFill(outputField.activeFocus, false, root.foreground, root.accent)
          border.width: 1
          border.color: outputField.activeFocus
            ? root.accent
            : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

          ScrollView {
            anchors.fill: parent
            anchors.margins: Style.space(6)
            anchors.bottomMargin: Style.space(30)
            clip: true

            TextArea {
              id: outputField
              text: root.outputText
              readOnly: true
              wrapMode: TextArea.Wrap
              // The agent wrote this, so it is displayed as plain text and
              // never as markup: rich text would fetch <img src="http://..">
              // from whatever host it named.
              textFormat: TextEdit.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              color: root.foreground
              selectionColor: Style.selectionFillFor(root.foreground, root.accent)
              selectedTextColor: root.foreground
              placeholderText: root.busy ? "" : "The result appears here"
              placeholderTextColor: Qt.darker(root.foreground, 1.6)
              background: null

              // Read-only, but still a stop on the ring: it is the only way to
              // reach the answer with the keyboard and select part of it.
              activeFocusOnTab: true

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                  outputField.nextItemInFocusChain(event.key === Qt.Key_Tab).forceActiveFocus()
                  event.accepted = true
                }
              }
            }
          }

          Column {
            anchors.centerIn: parent
            visible: root.busy
            spacing: Style.space(10)

            Item {
              id: spinner
              width: Style.space(26)
              height: width
              anchors.horizontalCenter: parent.horizontalCenter

              Shape {
                anchors.fill: parent
                antialiasing: true
                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                  strokeColor: root.accent
                  strokeWidth: 2
                  fillColor: "transparent"
                  capStyle: ShapePath.RoundCap

                  PathAngleArc {
                    centerX: spinner.width / 2
                    centerY: spinner.height / 2
                    radiusX: spinner.width / 2 - 2
                    radiusY: spinner.height / 2 - 2
                    startAngle: 0
                    sweepAngle: 280
                  }
                }
              }

              RotationAnimator on rotation {
                running: root.busy && root.opened
                loops: Animation.Infinite
                from: 0
                to: 360
                duration: 900
              }
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: root.agentLabel !== "" ? root.plain(root.agentLabel) + " is working" : "Working"
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              textFormat: Text.PlainText
              text: "Close this and carry on, or stop it with Ctrl+Enter"
              color: Qt.darker(root.foreground, 1.8)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(7)
            visible: root.copied
            textFormat: Text.PlainText
            text: "Copied"
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // Declared left to right, because Tab follows the order the
          // children are written in and a ring that jumps backwards over the
          // pair is one you have to look at to use.
          PanelActionButton {
            id: reuseButton
            anchors.right: copyButton.left
            anchors.rightMargin: Style.space(2)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(4)
            focusable: true
            enabled: root.outputText !== "" && !root.busy
            iconText: root.iconReuse
            tooltipText: "Send back up to transform again"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.reuseOutput()
          }

          PanelActionButton {
            id: copyButton
            anchors.right: parent.right
            anchors.rightMargin: Style.space(4)
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(4)
            focusable: true
            enabled: root.outputText !== ""
            iconText: root.iconCopy
            tooltipText: "Copy"
            foreground: root.copied ? root.accent : root.foreground
            fontFamily: root.fontFamily
            onClicked: root.copyOutput()
          }
        }

        // One strip for whatever went wrong, which is nearly always the agent
        // saying it is not logged in or out of quota. Worth passing on
        // verbatim: it is the only thing that tells someone what to fix.
        Text {
          visible: !root.settingsOpen && (root.errorText !== "" || root.agentProblem !== "")
          width: parent.width
          textFormat: Text.PlainText
          text: root.errorText !== "" ? root.errorText : root.agentProblem
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        // --- settings view ---------------------------------------------------

        Text {
          visible: root.settingsOpen
          width: parent.width
          textFormat: Text.PlainText
          text: "The name is what the dropdown shows. The prompt is what the agent is told to do with your text."
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }

        // One scrolling surface, not two. Every prompt used to sit in a fixed
        // 64px box with a ScrollView of its own, which meant a long prompt was
        // read three lines at a time and the wheel over it scrolled that
        // keyhole instead of the list. The boxes now grow to whatever they
        // hold and only this flickable scrolls.
        Flickable {
          id: draftFlick
          visible: root.settingsOpen
          width: parent.width
          height: Math.min(draftColumn.implicitHeight, Style.space(500))
          clip: true
          contentWidth: width
          contentHeight: draftColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: draftColumn
            width: draftFlick.width
            spacing: Style.space(8)

            Repeater {
              id: draftRepeater
              model: draft

              delegate: Rectangle {
                id: draftRow
                required property int index
                required property string name
                required property string prompt
                required property bool autoCopy

                // So addDraft can put the cursor in the row it just made.
                property alias nameField: nameField

                width: parent.width
                height: rowContent.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: Style.normalFill
                border.width: 1
                border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)

                Column {
                  id: rowContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.top: parent.top
                  anchors.margins: Style.space(6)
                  spacing: Style.space(6)

                  Item {
                    width: parent.width
                    height: Style.spacing.controlHeight

                    TextField {
                      id: nameField
                      anchors.left: parent.left
                      anchors.right: autoCopyButton.left
                      anchors.rightMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                      text: draftRow.name
                      placeholderText: "Name"
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      // The shared TextField does not opt into the Tab ring
                      // itself, so without this the name of every
                      // transformation is unreachable without a mouse.
                      activeFocusOnTab: true
                      onTextChanged: root.updateDraft(draftRow.index, "name", text)
                      onActiveFocusChanged: {
                        if (activeFocus) root.revealInDrafts(nameField, 0, height)
                      }
                    }

                    PanelActionButton {
                      id: autoCopyButton
                      anchors.right: removeButton.left
                      anchors.rightMargin: Style.space(6)
                      anchors.verticalCenter: parent.verticalCenter
                      focusable: true
                      // A copy glyph names the action itself; the slash only
                      // changes whether that action happens automatically.
                      iconText: root.iconCopy
                      tooltipText: draftRow.autoCopy
                        ? "Copy result to clipboard automatically: on"
                        : "Copy result to clipboard automatically: off"
                      foreground: draftRow.autoCopy ? root.accent : root.foreground
                      hoverColor: root.accent
                      fontFamily: root.fontFamily
                      onClicked: root.updateDraft(draftRow.index, "autoCopy", !draftRow.autoCopy)
                      onActiveFocusChanged: {
                        if (activeFocus) root.revealInDrafts(autoCopyButton, 0, height)
                      }

                      // Off is a preference, not an error, so its slash uses
                      // the normal foreground rather than an urgent colour.
                      Rectangle {
                        visible: !draftRow.autoCopy
                        anchors.centerIn: parent
                        width: parent.width * 1.1
                        height: Math.max(1, Style.space(1))
                        rotation: -45
                        color: root.foreground
                        radius: height / 2
                      }
                    }

                    PanelActionButton {
                      id: removeButton
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      focusable: true
                      iconText: root.iconRemove
                      tooltipText: "Remove"
                      foreground: root.foreground
                      hoverColor: Color.urgent
                      fontFamily: root.fontFamily
                      onClicked: root.removeDraft(draftRow.index)
                      onActiveFocusChanged: {
                        if (activeFocus) root.revealInDrafts(removeButton, 0, height)
                      }
                    }
                  }

                  Rectangle {
                    width: parent.width
                    // Tall enough to be worth typing in when it is empty, and
                    // as tall as it needs to be once it is not.
                    height: Math.max(Style.space(76), promptField.implicitHeight + Style.space(8))
                    radius: Style.cornerRadius
                    color: Style.controlFill(promptField.activeFocus, false, root.foreground, root.accent)
                    border.width: 1
                    border.color: promptField.activeFocus
                      ? root.accent
                      : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

                    TextArea {
                      id: promptField
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.top: parent.top
                      anchors.margins: Style.space(4)
                      text: draftRow.prompt
                      onTextChanged: root.updateDraft(draftRow.index, "prompt", text)
                      wrapMode: TextArea.Wrap
                      textFormat: TextEdit.PlainText
                      font.family: root.fontFamily
                      // Body, not caption. A prompt is the thing being written
                      // on this screen; it should read like the box in the
                      // main view rather than like a footnote.
                      font.pixelSize: Style.font.body
                      color: root.foreground
                      selectionColor: Style.selectionFillFor(root.foreground, root.accent)
                      selectedTextColor: root.foreground
                      placeholderText: "What should the agent do with the text?"
                      placeholderTextColor: Qt.darker(root.foreground, 1.6)
                      background: null

                      activeFocusOnTab: true

                      // The cursor can walk off the bottom of a long prompt,
                      // and Tab can land on a row below the fold. Both are the
                      // same fix: drag the window to wherever the keyboard is.
                      onCursorRectangleChanged: {
                        if (activeFocus)
                          root.revealInDrafts(promptField, cursorRectangle.y, cursorRectangle.height)
                      }
                      onActiveFocusChanged: {
                        if (activeFocus)
                          root.revealInDrafts(promptField, cursorRectangle.y, cursorRectangle.height)
                      }

                      Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                          promptField.nextItemInFocusChain(event.key === Qt.Key_Tab).forceActiveFocus()
                          event.accepted = true
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }

        Item {
          visible: root.settingsOpen
          width: parent.width
          height: addButton.height

          PanelActionButton {
            id: addButton
            anchors.left: parent.left
            focusable: true
            iconText: root.iconAdd
            tooltipText: "Add a transformation"
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.addDraft()
          }

          Text {
            anchors.left: addButton.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: addButton.verticalCenter
            textFormat: Text.PlainText
            text: "Add"
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // Every control here is reachable with Tab, which is worth saying
        // once: an icon button gives up its tooltip only to a mouse, so a
        // keyboard has nothing else to read.
        Text {
          width: parent.width
          textFormat: Text.PlainText
          text: root.settingsOpen
            ? "Tab moves \u00B7 Ctrl+Enter saves \u00B7 Esc closes"
            : "Tab moves \u00B7 Enter presses \u00B7 Ctrl+Enter transforms \u00B7 Esc closes"
          color: Qt.darker(root.foreground, 1.9)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.Wrap
        }
      }
    }
  }
}
