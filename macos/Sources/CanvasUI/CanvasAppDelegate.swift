import AppKit
import CanvasCore
import UniformTypeIdentifiers

@MainActor
public final class CanvasAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var windows: [NSWindowController] = []
    private var documentsByWindow: [ObjectIdentifier: CanvasNativeDocument] = [:]
    private weak var currentWindow: NSWindow?
    private var welcome: NSWindowController?
    private var untitledCount = 0

    private var sigtermSource: DispatchSourceSignal?
    public var recoveryStore: CanvasRecoveryStore
    public var recoveryLaunchDecisionProvider: ((CanvasRecoveryInspection) -> CanvasRecoveryLaunchDecision)?
    public var openErrorHandler: ((URL, Error) -> Void)?
    public var saveErrorHandler: ((CanvasNativeDocument, Error) -> Void)?
    public private(set) var corruptRecoveryNotices: [String] = []

    public init(recoveryStore: CanvasRecoveryStore = CanvasRecoveryStore()) {
        self.recoveryStore = recoveryStore
        super.init()
    }

    public override convenience init() {
        self.init(recoveryStore: CanvasRecoveryStore())
    }

    public var openNativeDocuments: [CanvasNativeDocument] {
        windows.compactMap { controller in
            guard let window = controller.window else { return nil }
            return documentsByWindow[ObjectIdentifier(window)]
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: .aqua)
        installMenu()
        app.setActivationPolicy(.regular)
        if let bundledIconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let bundledIcon = NSImage(contentsOf: bundledIconURL) {
            app.applicationIconImage = bundledIcon
        } else if let icon = CanvasTheme.appIconImage() {
            app.applicationIconImage = icon
        }
        Darwin.signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { Darwin._exit(0) }
                if self.applicationShouldTerminate(NSApplication.shared) == .terminateNow {
                    Darwin._exit(0)
                }
            }
        }
        source.resume()
        sigtermSource = source
        _ = processPendingRecoveriesOnLaunch()
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for argument in arguments {
            openDocument(URL(fileURLWithPath: argument))
        }
        if windows.isEmpty {
            showWelcome()
        }
        app.activate(ignoringOtherApps: true)
    }

    public func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }
    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openDocument(url) }
    }

    @objc public func chooseDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls { openDocument(url) }
        }
    }

    public func showWelcome() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 264),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Canvas"
        window.backgroundColor = CanvasTheme.canvasBackground
        window.center()
        let content = WelcomeContentView(frame: NSRect(x: 0, y: 0, width: 520, height: 264))
        let new = NSButton(title: "New Canvas", target: self, action: #selector(newDocument(_:)))
        new.frame = NSRect(x: 32, y: 214, width: 140, height: 32)
        new.keyEquivalent = "\r"
        let button = NSButton(title: "Open Canvas…", target: self, action: #selector(chooseDocument(_:)))
        button.frame = NSRect(x: 184, y: 214, width: 140, height: 32)
        content.addSubview(new)
        content.addSubview(button)
        window.contentView = content
        let controller = NSWindowController(window: window)
        welcome = controller
        controller.showWindow(nil)
    }

    @discardableResult
    public func openDocument(_ url: URL) -> CanvasNativeDocument? {
        let standardized = url.standardizedFileURL
        if let existingController = windows.first(where: { controller in
            guard let win = controller.window,
                  let doc = documentsByWindow[ObjectIdentifier(win)],
                  let existingURL = doc.fileURL?.standardizedFileURL else { return false }
            return existingURL == standardized
        }), let existingWindow = existingController.window,
           let existingDoc = documentsByWindow[ObjectIdentifier(existingWindow)] {
            currentWindow = existingWindow
            existingController.showWindow(nil)
            existingWindow.makeKeyAndOrderFront(nil)
            existingWindow.makeFirstResponder(existingDoc.canvasView)
            return existingDoc
        }
        do {
            let nativeDoc = try CanvasNativeDocument(opening: url, recoveryStore: recoveryStore)
            _ = showNativeDocument(nativeDoc)
            return nativeDoc
        } catch {
            if let openErrorHandler {
                openErrorHandler(url, error)
            } else {
                let alert = NSAlert(error: error)
                alert.messageText = "Cannot open canvas"
                alert.informativeText = "\(url.lastPathComponent): \(error.localizedDescription)"
                alert.runModal()
            }
            if windows.isEmpty && welcome == nil { showWelcome() }
            return nil
        }
    }

    @objc public func newDocument(_ sender: Any?) {
        do {
            untitledCount += 1
            let title = untitledCount == 1 ? "Untitled" : "Untitled \(untitledCount)"
            let nativeDoc = try CanvasNativeDocument(
                untitledDisplayName: title,
                recoveryStore: recoveryStore
            )
            _ = showNativeDocument(nativeDoc)
        } catch {
            NSApp.presentError(error)
        }
    }

    @discardableResult
    public func showNativeDocument(_ nativeDocument: CanvasNativeDocument) -> CanvasView {
        let canvas = nativeDocument.canvasView
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = CanvasTheme.canvasBackground
        scroll.documentView = canvas
        let window = NSWindow(
            contentRect: scroll.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        window.backgroundColor = CanvasTheme.canvasBackground
        window.contentView = scroll
        window.center()
        let controller = NSWindowController(window: window)
        nativeDocument.addWindowController(controller)
        windows.append(controller)
        documentsByWindow[ObjectIdentifier(window)] = nativeDocument

        let syncWindowChrome: (CanvasPersistenceState) -> Void = { [weak window, weak nativeDocument] state in
            guard let window, let nativeDocument else { return }
            window.title = nativeDocument.windowTitle
            window.representedURL = nativeDocument.fileURL
            window.isDocumentEdited = state.hasUnresolvedWork
        }
        nativeDocument.onStateDidChange = syncWindowChrome
        syncWindowChrome(nativeDocument.persistenceState)

        currentWindow = window
        welcome?.close()
        welcome = nil
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        if canvas.hasActiveInlineTextEditor, let editor = canvas.inlineTextEditorView {
            window.makeFirstResponder(editor)
        } else {
            window.makeFirstResponder(canvas)
        }
        return canvas
    }

    @discardableResult
    public func processPendingRecoveriesOnLaunch() -> [CanvasNativeDocument] {
        let inspections = recoveryStore.inspectAll()
        var restoredDocs: [CanvasNativeDocument] = []
        for inspection in inspections {
            let decision = recoveryLaunchDecisionProvider?(inspection)
                ?? promptRecoveryLaunchDecision(inspection)
            switch inspection {
            case .corrupt(_, _, _, let reason):
                corruptRecoveryNotices.append(reason)
                if decision == .discard {
                    recoveryStore.discard(inspection)
                }
            case .restorableUntitled, .restorableConnected, .sourceChangedRestoreAsUntitled:
                switch decision {
                case .restore:
                    if let doc = try? CanvasNativeDocument(restoring: inspection, recoveryStore: recoveryStore) {
                        _ = showNativeDocument(doc)
                        restoredDocs.append(doc)
                    }
                case .discard:
                    recoveryStore.discard(inspection)
                case .keepCorruptFile:
                    break
                }
            }
        }
        return restoredDocs
    }

    private func promptRecoveryLaunchDecision(_ inspection: CanvasRecoveryInspection) -> CanvasRecoveryLaunchDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        switch inspection {
        case .corrupt(_, _, _, let reason):
            alert.messageText = "Damaged recovery data could not be restored"
            alert.informativeText = "\(reason) Any original canvas JSON file on disk was left untouched."
            alert.addButton(withTitle: "Discard Damaged Recovery")
            alert.addButton(withTitle: "Keep Recovery File")
            return alert.runModal() == .alertFirstButtonReturn ? .discard : .keepCorruptFile
        case .restorableUntitled(let env, _, _):
            alert.messageText = "Restore unsaved canvas “\(env.displayName)”?"
            alert.informativeText = "Recovered work from an earlier session is available."
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Discard Recovery")
            return alert.runModal() == .alertFirstButtonReturn ? .restore : .discard
        case .restorableConnected(let env, _, _, _):
            alert.messageText = "Restore unsaved changes for “\(env.displayName)”?"
            alert.informativeText = "The original file on disk has not been overwritten. Restoring opens your recovered changes so you can review and save them."
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Discard Recovery")
            return alert.runModal() == .alertFirstButtonReturn ? .restore : .discard
        case .sourceChangedRestoreAsUntitled(let env, let sourceURL, _, _):
            alert.messageText = "Restore “\(env.displayName)” as a separate Untitled canvas?"
            alert.informativeText = "“\(sourceURL.lastPathComponent)” changed on disk since this recovery was saved. Restoring opens a separate Untitled document without modifying the disk file."
            alert.addButton(withTitle: "Restore as Untitled")
            alert.addButton(withTitle: "Discard Recovery")
            return alert.runModal() == .alertFirstButtonReturn ? .restore : .discard
        }
    }

    @discardableResult
    public func showDocument(_ document: CanvasDocument, name: String) -> CanvasView {
        let session = CanvasSession(document: document)
        return showSession(session, name: name)
    }

    @discardableResult
    public func showSession(_ session: CanvasSession, name: String) -> CanvasView {
        let canvas = CanvasView(session: session)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = CanvasTheme.canvasBackground
        scroll.documentView = canvas
        let window = NSWindow(
            contentRect: scroll.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        window.title = "\(name) — Session changes not saved"
        window.backgroundColor = CanvasTheme.canvasBackground
        window.contentView = scroll
        window.center()
        let controller = NSWindowController(window: window)
        windows.append(controller)
        currentWindow = window
        welcome?.close()
        welcome = nil
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        return canvas
    }

    @objc public func insertShape(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let kind = CanvasShapeKind(rawValue: value) else { return }
        activeCanvas()?.insertShape(kind)
    }

    @objc public func insertLine(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let kind = CanvasLineKind(rawValue: value) else { return }
        activeCanvas()?.insertLine(kind)
    }

    @objc public func insertConnection(_ sender: Any?) {
        activeCanvas()?.beginConnection()
    }

    @objc public func editGeometry(_ sender: Any?) {
        activeCanvas()?.beginGeometryEditing()
    }

    @objc public func insertAdjacentThought(_ sender: Any?) {
        activeCanvas()?.beginAdjacentThought()
    }

    @objc public func zoomIn(_ sender: Any?) {
        activeCanvas()?.zoomIn(sender)
    }

    @objc public func zoomOut(_ sender: Any?) {
        activeCanvas()?.zoomOut(sender)
    }

    @objc public func resetZoom(_ sender: Any?) {
        activeCanvas()?.resetZoom(sender)
    }

    @objc public func zoomToFit(_ sender: Any?) {
        activeCanvas()?.zoomToFit(sender)
    }

    @objc public func editText(_ sender: Any?) {
        activeCanvas()?.beginTextEditing()
    }

    @objc public func previewAttachment(_ sender: Any?) {
        activeCanvas()?.beginAttachmentPreview()
    }

    @objc public func editConnection(_ sender: Any?) {
        activeCanvas()?.beginConnection(focusLabel: true)
    }


    @objc public func cutSelection(_ sender: Any?) {
        if let editor = activeKeyWindow()?.firstResponder as? NSTextView {
            if editor.isEditable {
                editor.cut(sender)
            } else {
                NSSound.beep()
            }
        } else {
            activeCanvas()?.cutSelection(sender)
        }
    }

    @objc public func copySelection(_ sender: Any?) {
        if let editor = activeKeyWindow()?.firstResponder as? NSTextView {
            editor.copy(sender)
        } else {
            activeCanvas()?.copySelection(sender)
        }
    }

    @objc public func pasteSelection(_ sender: Any?) {
        if let editor = activeKeyWindow()?.firstResponder as? NSTextView {
            if editor.isEditable {
                editor.paste(sender)
            } else {
                NSSound.beep()
            }
        } else {
            activeCanvas()?.pasteSelection(sender)
        }
    }

    @objc public func selectAllItems(_ sender: Any?) {
        if let editor = activeKeyWindow()?.firstResponder as? NSTextView {
            editor.selectAll(sender)
        } else {
            activeCanvas()?.selectAll(sender)
        }
    }
    @objc public func duplicateSelection(_ sender: Any?) {
        activeCanvas()?.duplicateSelection(sender)
    }

    @objc public func deleteSelection(_ sender: Any?) {
        if let editor = activeKeyWindow()?.firstResponder as? NSTextView {
            editor.deleteBackward(sender)
        } else {
            activeCanvas()?.deleteSelection(sender)
        }
    }

    @objc public func bringToFront(_ sender: Any?) {
        activeCanvas()?.bringToFront(sender)
    }

    @objc public func sendToBack(_ sender: Any?) {
        activeCanvas()?.sendToBack(sender)
    }

    @objc public func toggleLock(_ sender: Any?) {
        activeCanvas()?.toggleLock(sender)
    }

    @objc public func showStyleInspector(_ sender: Any?) {
        activeCanvas()?.showStyleInspector(sender)
    }

    @objc public func exportPNG(_ sender: Any?) {
        activeCanvas()?.beginPNGExport()
    }

    @objc public func saveDocument(_ sender: Any?) {
        guard let doc = activeNativeDocument() else {
            NSSound.beep()
            return
        }
        do {
            _ = try doc.saveDocumentExplicitly()
        } catch let error as CanvasPersistenceError {
            if case .externalConflict(let reason) = error {
                handleConflictPrompt(for: doc, reason: reason)
                return
            }
            presentSaveError(for: doc, error: error)
        } catch {
            presentSaveError(for: doc, error: error)
        }
    }

    @objc public func saveDocumentAs(_ sender: Any?) {
        guard let doc = activeNativeDocument() else {
            NSSound.beep()
            return
        }
        do {
            try doc.canvasView.flushPendingEditsForSave()
        } catch {
            presentSaveError(for: doc, error: CanvasPersistenceError.invalidDraft(error.localizedDescription))
            return
        }
        guard let destinationURL = doc.chooseSaveDestination(suggestedName: doc.suggestedSaveFilename()) else {
            return
        }
        do {
            _ = try doc.saveDocumentAs(to: destinationURL)
        } catch {
            presentSaveError(for: doc, error: error)
        }
    }

    @objc public func saveVersion2Copy(_ sender: Any?) {
        guard let doc = activeNativeDocument() else {
            NSSound.beep()
            return
        }
        do {
            try doc.canvasView.flushPendingEditsForSave()
        } catch {
            presentSaveError(for: doc, error: CanvasPersistenceError.invalidDraft(error.localizedDescription))
            return
        }
        let baseName = (doc.suggestedSaveFilename() as NSString).deletingPathExtension
        guard let destinationURL = doc.chooseSaveDestination(suggestedName: "\(baseName)-v2.json") else {
            return
        }
        do {
            try doc.saveVersion2Copy(to: destinationURL)
        } catch {
            presentSaveError(for: doc, error: error)
        }
    }

    @objc public func reloadDocumentFromDisk(_ sender: Any?) {
        guard let doc = activeNativeDocument(), doc.fileURL != nil else {
            NSSound.beep()
            return
        }
        if let provider = doc.conflictDecisionProvider,
           let reason = doc.conflictReason {
            if case .reloadFromDisk(let confirmed) = provider(reason) {
                _ = try? doc.reloadFromDisk(confirmed: confirmed)
            }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reload “\(doc.displayNameTitle)” from disk?"
        alert.informativeText = "Unsaved local changes in this window will be replaced by the disk file (a recovery copy will be saved first)."
        alert.addButton(withTitle: "Reload from Disk")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                _ = try doc.reloadFromDisk(confirmed: true)
            } catch {
                presentSaveError(for: doc, error: error)
            }
        }
    }

    private func handleConflictPrompt(for doc: CanvasNativeDocument, reason: CanvasConflictReason) {
        if let provider = doc.conflictDecisionProvider {
            let decision = provider(reason)
            _ = try? doc.applyConflictDecision(decision)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "External change detected for “\(doc.displayNameTitle)”"
        alert.informativeText = reason.message
        alert.addButton(withTitle: "Save As…")
        if case .modifiedExternally = reason {
            alert.addButton(withTitle: "Reload from Disk…")
        }
        alert.addButton(withTitle: "Keep Editing")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            saveDocumentAs(nil)
        } else if case .modifiedExternally = reason, response == .alertSecondButtonReturn {
            reloadDocumentFromDisk(nil)
        } else {
            _ = try? doc.applyConflictDecision(.keepEditing)
        }
    }

    private func presentSaveError(for doc: CanvasNativeDocument, error: Error) {
        if let saveErrorHandler {
            saveErrorHandler(doc, error)
            return
        }
        let alert = NSAlert(error: error)
        alert.messageText = "Cannot save “\(doc.displayNameTitle)”"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let keyWin = activeKeyWindow()
        let sheetOpen = keyWin?.attachedSheet != nil || keyWin?.sheetParent != nil || (activeCanvas()?.hasActiveInlineTextEditor == true)
        if menuItem.action == #selector(undoMove(_:)) || menuItem.action == #selector(redoMove(_:)) {
            if let editor = keyWin?.firstResponder as? NSTextView {
                return menuItem.action == #selector(undoMove(_:))
                    ? (editor.undoManager?.canUndo == true)
                    : (editor.undoManager?.canRedo == true)
            }
            guard !sheetOpen, let canvas = activeCanvas(), !canvas.isReadOnly else { return false }
            if canvas.hasGeometryPreview { return true }
            return menuItem.action == #selector(undoMove(_:))
                ? (canvas.undoManager?.canUndo == true)
                : (canvas.undoManager?.canRedo == true)
        }
        if menuItem.action == #selector(cutSelection(_:)) {
            if let editor = keyWin?.firstResponder as? NSTextView {
                return editor.isEditable && editor.selectedRange().length > 0
            }
            guard !sheetOpen, let canvas = activeCanvas() else { return false }
            return canvas.canCutSelection
        }
        if menuItem.action == #selector(copySelection(_:)) {
            if let editor = keyWin?.firstResponder as? NSTextView {
                return editor.selectedRange().length > 0
            }
            guard !sheetOpen, let canvas = activeCanvas() else { return false }
            return canvas.canCopySelection
        }
        if menuItem.action == #selector(pasteSelection(_:)) {
            if let editor = keyWin?.firstResponder as? NSTextView {
                return editor.isEditable
            }
            guard !sheetOpen, let canvas = activeCanvas() else { return false }
            return canvas.canPaste
        }
        if menuItem.action == #selector(selectAllItems(_:)) {
            if let editor = keyWin?.firstResponder as? NSTextView {
                return editor.isSelectable
            }
            guard !sheetOpen, let canvas = activeCanvas() else { return false }
            return canvas.canSelectAll
        }
        guard let canvas = activeCanvas() else {
            switch menuItem.action {
            case #selector(editGeometry(_:)), #selector(editText(_:)),
                 #selector(previewAttachment(_:)), #selector(editConnection(_:)),
                 #selector(insertConnection(_:)), #selector(insertAdjacentThought(_:)),
                 #selector(insertShape(_:)), #selector(insertLine(_:)),
                 #selector(duplicateSelection(_:)), #selector(deleteSelection(_:)),
                 #selector(bringToFront(_:)), #selector(sendToBack(_:)),
                 #selector(toggleLock(_:)), #selector(showStyleInspector(_:)),
                 #selector(zoomIn(_:)), #selector(zoomOut(_:)),
                 #selector(resetZoom(_:)), #selector(zoomToFit(_:)),
                 #selector(exportPNG(_:)), #selector(saveDocument(_:)),
                 #selector(saveDocumentAs(_:)), #selector(saveVersion2Copy(_:)),
                 #selector(reloadDocumentFromDisk(_:)):
                return false
            default:
                return true
            }
        }
        let modalSheetOpen = keyWin?.attachedSheet != nil || keyWin?.sheetParent != nil
        if menuItem.action == #selector(saveDocument(_:)) {
            return !modalSheetOpen && activeNativeDocument() != nil && !canvas.isReadOnly
        }
        if menuItem.action == #selector(saveDocumentAs(_:)) {
            return !modalSheetOpen && activeNativeDocument() != nil
        }
        if menuItem.action == #selector(saveVersion2Copy(_:)) {
            guard !modalSheetOpen, let doc = activeNativeDocument() else { return false }
            return (doc.session.root["version"] as? Int) == 1
        }
        if menuItem.action == #selector(reloadDocumentFromDisk(_:)) {
            guard !modalSheetOpen, let doc = activeNativeDocument() else { return false }
            return doc.fileURL != nil
        }
        if menuItem.action == #selector(toggleLock(_:)) {
            menuItem.title = canvas.isSelectedNodeLocked ? "Unlock" : "Lock"
            return canvas.canToggleLock && !sheetOpen
        }
        if menuItem.action == #selector(duplicateSelection(_:)) {
            return canvas.canDuplicateSelection && !sheetOpen
        }
        if menuItem.action == #selector(deleteSelection(_:)) {
            return canvas.canDeleteSelection && !sheetOpen
        }
        if menuItem.action == #selector(bringToFront(_:)) {
            return canvas.canBringToFront && !sheetOpen
        }
        if menuItem.action == #selector(sendToBack(_:)) {
            return canvas.canSendToBack && !sheetOpen
        }
        if menuItem.action == #selector(editGeometry(_:)) {
            return canvas.canEditGeometry && !canvas.hasGeometryPreview && !sheetOpen
        }
        if menuItem.action == #selector(editText(_:)) {
            return canvas.canEditTextSelection && !sheetOpen
        }
        if menuItem.action == #selector(previewAttachment(_:)) {
            return canvas.canPreviewAttachment && !sheetOpen
        }
        if menuItem.action == #selector(editConnection(_:)) {
            return canvas.canEditConnectionSelection && !sheetOpen
        }
        if menuItem.action == #selector(insertConnection(_:)) {
            return canvas.canInsertConnection && !canvas.hasGeometryPreview && !sheetOpen
        }
        if menuItem.action == #selector(insertAdjacentThought(_:)) {
            return canvas.canInsertAdjacentThought && !sheetOpen
        }
        if menuItem.action == #selector(zoomIn(_:)) || menuItem.action == #selector(zoomOut(_:)) ||
           menuItem.action == #selector(resetZoom(_:)) || menuItem.action == #selector(zoomToFit(_:)) {
            return !sheetOpen
        }
        if menuItem.action == #selector(exportPNG(_:)) {
            let modalSheetOpen = keyWin?.attachedSheet != nil || keyWin?.sheetParent != nil
            return !modalSheetOpen && canvas.canExportPNG
        }
        if menuItem.action == #selector(insertShape(_:)) || menuItem.action == #selector(insertLine(_:)) {
            return !canvas.isReadOnly && !canvas.hasGeometryPreview && !sheetOpen
        }
        if menuItem.action == #selector(showStyleInspector(_:)) {
            return !canvas.hasGeometryPreview && !sheetOpen
        }
        return true
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            currentWindow = window
            documentsByWindow[ObjectIdentifier(window)]?.checkExternalSourceStatus()
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let doc = documentsByWindow[ObjectIdentifier(sender)] {
            return doc.shouldCloseDocument()
        }
        return true
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        var pendingFinalizers: [() -> Void] = []
        for controller in windows {
            if let window = controller.window,
               let doc = documentsByWindow[ObjectIdentifier(window)] {
                let evaluation = doc.evaluateCloseApproval()
                guard evaluation.approved else {
                    return .terminateCancel
                }
                if let finalizeClose = evaluation.finalizeClose {
                    pendingFinalizers.append(finalizeClose)
                }
            }
        }
        for finalizeClose in pendingFinalizers {
            finalizeClose()
        }
        return .terminateNow
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let doc = documentsByWindow.removeValue(forKey: ObjectIdentifier(window)) {
            doc.cancelScheduledTimers()
        }
        windows.removeAll { $0.window === window }
        if currentWindow === window {
            currentWindow = windows.last?.window
        }
    }

    @objc public func undoMove(_ sender: Any?) {
        if let editor = activeKeyWindow()?.firstResponder as? NSTextView {
            editor.undoManager?.undo()
        } else {
            activeCanvas()?.undoMove(sender)
        }
    }

    @objc public func redoMove(_ sender: Any?) {
        if let editor = activeKeyWindow()?.firstResponder as? NSTextView {
            editor.undoManager?.redo()
        } else {
            activeCanvas()?.redoMove(sender)
        }
    }

    private func activeKeyWindow() -> NSWindow? {
        if let key = NSApplication.shared.keyWindow {
            return key.attachedSheet ?? key
        }
        let base = currentWindow ?? windows.last?.window
        return base?.attachedSheet ?? base
    }

    public func activeNativeDocument() -> CanvasNativeDocument? {
        guard let window = NSApplication.shared.keyWindow ?? currentWindow ?? windows.last?.window else {
            return nil
        }
        return documentsByWindow[ObjectIdentifier(window)]
    }

    public func activeCanvas() -> CanvasView? {
        guard let window = NSApplication.shared.keyWindow ?? currentWindow ?? windows.last?.window,
              window.attachedSheet == nil,
              window.sheetParent == nil,
              let scrollView = window.contentView as? NSScrollView else { return nil }
        return scrollView.documentView as? CanvasView
    }

    public func closeAllWindows() {
        for doc in documentsByWindow.values {
            doc.cancelScheduledTimers()
        }
        documentsByWindow.removeAll()
        for controller in windows {
            controller.window?.orderOut(nil)
            controller.close()
        }
        windows.removeAll()
        currentWindow = nil
        welcome?.window?.orderOut(nil)
        welcome?.close()
        welcome = nil
    }

    public func installMenu() {
        let app = NSApplication.shared
        let main = NSMenu()
        let appItem = NSMenuItem(title: "Canvas", action: nil, keyEquivalent: "")
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Canvas", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        main.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let new = NSMenuItem(title: "New", action: #selector(newDocument(_:)), keyEquivalent: "n")
        new.target = self
        fileMenu.addItem(new)
        let open = NSMenuItem(title: "Open…", action: #selector(chooseDocument(_:)), keyEquivalent: "o")
        open.target = self
        fileMenu.addItem(open)
        fileMenu.addItem(.separator())
        let save = NSMenuItem(title: "Save", action: #selector(saveDocument(_:)), keyEquivalent: "s")
        save.target = self
        fileMenu.addItem(save)
        let saveAs = NSMenuItem(title: "Save As…", action: #selector(saveDocumentAs(_:)), keyEquivalent: "s")
        saveAs.target = self
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(saveAs)
        let saveV2Copy = NSMenuItem(title: "Save Version 2 Copy…", action: #selector(saveVersion2Copy(_:)), keyEquivalent: "")
        saveV2Copy.target = self
        fileMenu.addItem(saveV2Copy)
        let reload = NSMenuItem(title: "Reload from Disk…", action: #selector(reloadDocumentFromDisk(_:)), keyEquivalent: "")
        reload.target = self
        fileMenu.addItem(reload)
        fileMenu.addItem(.separator())
        let exportPNGItem = NSMenuItem(title: "Export PNG…", action: #selector(exportPNG(_:)), keyEquivalent: "e")
        exportPNGItem.target = self
        exportPNGItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(exportPNGItem)
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        let undo = NSMenuItem(title: "Undo", action: #selector(undoMove(_:)), keyEquivalent: "z")
        undo.target = self
        let redo = NSMenuItem(title: "Redo", action: #selector(redoMove(_:)), keyEquivalent: "z")
        redo.target = self
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(undo)
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        let cut = NSMenuItem(title: "Cut", action: #selector(cutSelection(_:)), keyEquivalent: "x")
        cut.target = self
        editMenu.addItem(cut)
        let copy = NSMenuItem(title: "Copy", action: #selector(copySelection(_:)), keyEquivalent: "c")
        copy.target = self
        editMenu.addItem(copy)
        let paste = NSMenuItem(title: "Paste", action: #selector(pasteSelection(_:)), keyEquivalent: "v")
        paste.target = self
        editMenu.addItem(paste)
        let duplicate = NSMenuItem(title: "Duplicate", action: #selector(duplicateSelection(_:)), keyEquivalent: "d")
        duplicate.target = self
        editMenu.addItem(duplicate)
        let delete = NSMenuItem(title: "Delete", action: #selector(deleteSelection(_:)), keyEquivalent: "")
        delete.target = self
        editMenu.addItem(delete)
        let selectAll = NSMenuItem(title: "Select All", action: #selector(selectAllItems(_:)), keyEquivalent: "a")
        selectAll.target = self
        editMenu.addItem(selectAll)
        editMenu.addItem(.separator())
        let front = NSMenuItem(title: "Bring to Front", action: #selector(bringToFront(_:)), keyEquivalent: "]")
        front.target = self
        front.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(front)
        let back = NSMenuItem(title: "Send to Back", action: #selector(sendToBack(_:)), keyEquivalent: "[")
        back.target = self
        back.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(back)
        let lock = NSMenuItem(title: "Lock", action: #selector(toggleLock(_:)), keyEquivalent: "l")
        lock.target = self
        editMenu.addItem(lock)
        editMenu.addItem(.separator())
        let editTextItem = NSMenuItem(title: "Edit Text…", action: #selector(editText(_:)), keyEquivalent: "")
        editTextItem.target = self
        editMenu.addItem(editTextItem)
        let previewAttachmentItem = NSMenuItem(title: "Preview Attachment…", action: #selector(previewAttachment(_:)), keyEquivalent: "")
        previewAttachmentItem.target = self
        editMenu.addItem(previewAttachmentItem)
        let editConnectionItem = NSMenuItem(title: "Edit Connection…", action: #selector(editConnection(_:)), keyEquivalent: "")
        editConnectionItem.target = self
        editMenu.addItem(editConnectionItem)
        let geometry = NSMenuItem(title: "Edit Geometry", action: #selector(editGeometry(_:)), keyEquivalent: "")
        geometry.target = self
        editMenu.addItem(geometry)
        let style = NSMenuItem(title: "Style…", action: #selector(showStyleInspector(_:)), keyEquivalent: "")
        style.target = self
        editMenu.addItem(style)
        editItem.submenu = editMenu
        let insertItem = NSMenuItem(title: "Insert", action: nil, keyEquivalent: "")
        main.addItem(insertItem)
        let insertMenu = NSMenu(title: "Insert")
        for (title, kind) in [
            ("Rectangle", CanvasShapeKind.rectangle), ("Ellipse", .ellipse),
            ("Diamond", .diamond), ("Triangle", .triangle), ("Text…", .text)
        ] {
            let item = NSMenuItem(title: title, action: #selector(insertShape(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            insertMenu.addItem(item)
        }
        insertMenu.addItem(.separator())
        for (title, kind) in [("Line", CanvasLineKind.line), ("Arrow", .arrow)] {
            let item = NSMenuItem(title: title, action: #selector(insertLine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            insertMenu.addItem(item)
        }
        insertMenu.addItem(.separator())
        let connection = NSMenuItem(title: "Connection…", action: #selector(insertConnection(_:)), keyEquivalent: "")
        connection.target = self
        insertMenu.addItem(connection)
        let thought = NSMenuItem(title: "Adjacent Thought", action: #selector(insertAdjacentThought(_:)), keyEquivalent: "")
        thought.target = self
        insertMenu.addItem(thought)
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        let zoomInItem = NSMenuItem(title: "Zoom In", action: #selector(zoomIn(_:)), keyEquivalent: "+")
        zoomInItem.target = self
        viewMenu.addItem(zoomInItem)
        let zoomOutItem = NSMenuItem(title: "Zoom Out", action: #selector(zoomOut(_:)), keyEquivalent: "-")
        zoomOutItem.target = self
        viewMenu.addItem(zoomOutItem)
        let resetZoomItem = NSMenuItem(title: "Actual Size", action: #selector(resetZoom(_:)), keyEquivalent: "0")
        resetZoomItem.target = self
        viewMenu.addItem(resetZoomItem)
        let fitItem = NSMenuItem(title: "Zoom to Fit", action: #selector(zoomToFit(_:)), keyEquivalent: "")
        fitItem.target = self
        viewMenu.addItem(fitItem)
        viewItem.submenu = viewMenu
        insertItem.submenu = insertMenu
        app.mainMenu = main
    }

}
