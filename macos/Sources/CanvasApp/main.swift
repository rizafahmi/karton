import AppKit
import CanvasCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var windows: [NSWindowController] = []
    private var welcome: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Elixir Canvas — Read-only viewer"
        window.center()
        let label = NSTextField(labelWithString: "Open a JSON canvas to view it.\nRead-only; routes are approximate and code is plain text.")
        label.alignment = .center
        label.frame = NSRect(x: 30, y: 125, width: 420, height: 52)
        let button = NSButton(title: "Open Canvas…", target: self, action: #selector(chooseDocument(_:)))
        button.frame = NSRect(x: 165, y: 65, width: 150, height: 34)
        window.contentView?.addSubview(label)
        window.contentView?.addSubview(button)
        let controller = NSWindowController(window: window)
        welcome = controller
        controller.showWindow(nil)
    }

    private func openDocument(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let document = try CanvasDocument(data: data)
            let canvas = CanvasView(document: document)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true
            scroll.autohidesScrollers = true
            scroll.documentView = canvas
            let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.delegate = self
            window.title = "\(url.lastPathComponent) — Read-only, approximate routes"
            window.contentView = scroll
            window.center()
            let controller = NSWindowController(window: window)
            windows.append(controller)
            welcome?.close()
            welcome = nil
            controller.showWindow(nil)
            window.makeKeyAndOrderFront(nil)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Cannot open canvas"
            alert.informativeText = "\(url.lastPathComponent): \(error.localizedDescription)"
            alert.runModal()
            if windows.isEmpty && welcome == nil { showWelcome() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeAll { $0.window === window }
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
        let open = NSMenuItem(title: "Open…", action: #selector(chooseDocument(_:)), keyEquivalent: "o")
        open.target = self
        fileMenu.addItem(open)
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
