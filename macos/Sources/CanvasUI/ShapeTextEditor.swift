import AppKit

@MainActor
final class ShapeTextEditor: NSObject {
    private final class SourceView: NSTextView {
        var finish: (() -> Void)?
        var cancel: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            if !hasMarkedText() {
                if event.keyCode == 53 { cancel?(); return }
                if event.keyCode == 36 && event.modifierFlags.contains(.command) {
                    finish?(); return
                }
            }
            super.keyDown(with: event)
        }
    }

    private let panel: NSPanel
    private let editor: SourceView
    private let errorLabel: NSTextField
    private let commit: (String) throws -> Void
    private let completion: () -> Void

    init(text: String, commit: @escaping (String) throws -> Void, completion: @escaping () -> Void) {
        self.commit = commit
        self.completion = completion
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 360),
                        styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Edit Shape Text"
        editor = SourceView(frame: NSRect(x: 0, y: 0, width: 512, height: 220))
        errorLabel = NSTextField(wrappingLabelWithString: "Return inserts a newline. ⌘Return finishes; Escape cancels.")
        super.init()
        let scroll = NSScrollView(frame: NSRect(x: 24, y: 112, width: 512, height: 220))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        editor.isRichText = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.font = .systemFont(ofSize: 16)
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.string = text
        editor.setAccessibilityLabel("Shape text")
        scroll.documentView = editor
        errorLabel.frame = NSRect(x: 24, y: 58, width: 512, height: 44)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelEditing))
        cancel.frame = NSRect(x: 344, y: 16, width: 92, height: 32)
        let done = NSButton(title: "Done", target: self, action: #selector(finishEditing))
        done.frame = NSRect(x: 444, y: 16, width: 92, height: 32)
        panel.contentView?.addSubview(scroll)
        panel.contentView?.addSubview(errorLabel)
        panel.contentView?.addSubview(cancel)
        panel.contentView?.addSubview(done)
        editor.finish = { [weak self] in self?.finishEditing() }
        editor.cancel = { [weak self] in self?.cancelEditing() }
    }

    func present(on window: NSWindow) {
        window.beginSheet(panel)
        panel.makeFirstResponder(editor)
    }

    @objc private func finishEditing() {
        guard !editor.hasMarkedText() else { return }
        do {
            try commit(editor.string)
            dismiss()
        } catch {
            errorLabel.stringValue = error.localizedDescription
            errorLabel.textColor = .systemRed
            panel.makeFirstResponder(editor)
        }
    }

    @objc private func cancelEditing() { dismiss() }

    private func dismiss() {
        let parent = panel.sheetParent
        parent?.endSheet(panel)
        panel.orderOut(nil)
        parent?.makeKeyAndOrderFront(nil)
        completion()
    }
}
