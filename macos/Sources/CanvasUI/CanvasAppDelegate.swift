import AppKit
import CanvasCore
import UniformTypeIdentifiers

@MainActor
public final class CanvasAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var windows: [NSWindowController] = []
    private weak var currentWindow: NSWindow?
    private var welcome: NSWindowController?
    private var untitledCount = 0

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        app.appearance = NSAppearance(named: .aqua)
        installMenu()
        app.setActivationPolicy(.regular)
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if arguments.isEmpty && windows.isEmpty {
            showWelcome()
        } else {
            for argument in arguments { openDocument(URL(fileURLWithPath: argument)) }
        }
        app.activate(ignoringOtherApps: true)
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
        window.title = "Elixir Canvas — Session-only viewer"
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

    public func openDocument(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let document = try CanvasDocument(data: data)
            showDocument(document, name: url.lastPathComponent)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Cannot open canvas"
            alert.informativeText = "\(url.lastPathComponent): \(error.localizedDescription)"
            alert.runModal()
            if windows.isEmpty && welcome == nil { showWelcome() }
        }
    }

    @objc public func newDocument(_ sender: Any?) {
        do {
            let document = try CanvasDocument.blank()
            untitledCount += 1
            showDocument(document, name: untitledCount == 1 ? "Untitled" : "Untitled \(untitledCount)")
        } catch {
            NSApp.presentError(error)
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
        window.delegate = self
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

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let keyWin = activeKeyWindow()
        let sheetOpen = keyWin?.attachedSheet != nil || keyWin?.sheetParent != nil || (activeCanvas()?.hasActiveInlineTextEditor == true)
        if menuItem.action == #selector(undoMove(_:)) || menuItem.action == #selector(redoMove(_:)) {
            if let editor = keyWin?.firstResponder as? NSTextView {
                return menuItem.action == #selector(undoMove(_:))
                    ? (editor.undoManager?.canUndo == true)
                    : (editor.undoManager?.canRedo == true)
            }
            guard !sheetOpen, let canvas = activeCanvas() else { return false }
            if canvas.hasGeometryPreview { return true }
            return menuItem.action == #selector(undoMove(_:))
                ? (canvas.undoManager?.canUndo == true)
                : (canvas.undoManager?.canRedo == true)
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
                 #selector(resetZoom(_:)), #selector(zoomToFit(_:)):
                return false
            default:
                return true
            }
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
        if menuItem.action == #selector(insertShape(_:)) || menuItem.action == #selector(insertLine(_:)) ||
           menuItem.action == #selector(showStyleInspector(_:)) {
            return !canvas.hasGeometryPreview && !sheetOpen
        }
        return true
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            currentWindow = window
        }
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
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

    public func activeCanvas() -> CanvasView? {
        guard let window = NSApplication.shared.keyWindow ?? currentWindow ?? windows.last?.window,
              window.attachedSheet == nil,
              window.sheetParent == nil,
              let scrollView = window.contentView as? NSScrollView else { return nil }
        return scrollView.documentView as? CanvasView
    }

    public func closeAllWindows() {
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
        let appItem = NSMenuItem(title: "Elixir Canvas", action: nil, keyEquivalent: "")
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Elixir Canvas", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let duplicate = NSMenuItem(title: "Duplicate", action: #selector(duplicateSelection(_:)), keyEquivalent: "d")
        duplicate.target = self
        editMenu.addItem(duplicate)
        let delete = NSMenuItem(title: "Delete", action: #selector(deleteSelection(_:)), keyEquivalent: "")
        delete.target = self
        editMenu.addItem(delete)
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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
