import AppKit
import CanvasCore
import CanvasUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private var windows: [NSWindowController] = []
    private var welcome: NSWindowController?
    private var untitledCount = 0
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        installMenu()
        NSApp.setActivationPolicy(.regular)
        let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if arguments.isEmpty && windows.isEmpty {
            showWelcome()
        } else {
            for argument in arguments { openDocument(URL(fileURLWithPath: argument)) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { openDocument(url) }
    }

    @objc private func chooseDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            for url in panel.urls { openDocument(url) }
        }
    }

    private func showWelcome() {
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

    private func openDocument(_ url: URL) {
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

    @objc private func newDocument(_ sender: Any?) {
        do {
            let document = try CanvasDocument.blank()
            untitledCount += 1
            showDocument(document, name: untitledCount == 1 ? "Untitled" : "Untitled \(untitledCount)")
        } catch {
            NSApp.presentError(error)
        }
    }

    private func showDocument(_ document: CanvasDocument, name: String) {
        let canvas = CanvasView(document: document)
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
        welcome?.close()
        welcome = nil
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    @objc private func insertShape(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let kind = CanvasShapeKind(rawValue: value) else { return }
        activeCanvas()?.insertShape(kind)
    }

    @objc private func insertConnection(_ sender: Any?) {
        activeCanvas()?.beginConnection()
    }

    @objc private func editGeometry(_ sender: Any?) {
        activeCanvas()?.beginGeometryEditing()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(editGeometry(_:)) {
            return activeCanvas()?.canEditGeometry == true &&
                activeCanvas()?.hasGeometryPreview == false && NSApp.keyWindow?.attachedSheet == nil
        }
        if menuItem.action == #selector(insertConnection(_:)) {
            return activeCanvas()?.canInsertConnection == true &&
                activeCanvas()?.hasGeometryPreview == false && NSApp.keyWindow?.attachedSheet == nil
        }
        if menuItem.action == #selector(insertShape(_:)) {
            return activeCanvas() != nil && activeCanvas()?.hasGeometryPreview == false &&
                NSApp.keyWindow?.attachedSheet == nil
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeAll { $0.window === window }
    }

    @objc private func undoMove(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            editor.undoManager?.undo()
        } else {
            activeCanvas()?.undoMove(sender)
        }
    }

    @objc private func redoMove(_ sender: Any?) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            editor.undoManager?.redo()
        } else {
            activeCanvas()?.redoMove(sender)
        }
    }

    private func activeCanvas() -> CanvasView? {
        guard let scrollView = NSApp.keyWindow?.contentView as? NSScrollView else { return nil }
        return scrollView.documentView as? CanvasView
    }

    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Elixir Canvas", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let fileItem = NSMenuItem()
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
        let editItem = NSMenuItem()
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
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        let geometry = NSMenuItem(title: "Edit Geometry", action: #selector(editGeometry(_:)), keyEquivalent: "")
        geometry.target = self
        editMenu.addItem(geometry)
        editItem.submenu = editMenu
        let insertItem = NSMenuItem()
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
        let connection = NSMenuItem(title: "Connection…", action: #selector(insertConnection(_:)), keyEquivalent: "")
        connection.target = self
        insertMenu.addItem(connection)
        insertItem.submenu = insertMenu
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
