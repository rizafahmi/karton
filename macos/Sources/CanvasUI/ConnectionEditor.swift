import AppKit
import CanvasCore

@MainActor
final class ConnectionEditor: NSObject {
    struct ObjectOption {
        let id: String
        let title: String
    }

    private let panel: NSPanel
    private let objects: [ObjectOption]
    private let source = NSPopUpButton()
    private let target = NSPopUpButton()
    private let sourceSide = NSPopUpButton()
    private let targetSide = NSPopUpButton()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let commit: (String, CanvasConnectionSide?, String, CanvasConnectionSide?) throws -> Void
    private let completion: () -> Void

    init(objects: [ObjectOption], selectedID: String?,
         commit: @escaping (String, CanvasConnectionSide?, String, CanvasConnectionSide?) throws -> Void,
         completion: @escaping () -> Void) {
        self.objects = objects
        self.commit = commit
        self.completion = completion
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 400),
                        styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        panel.title = "Create Connection"
        configure(source, label: "Source", id: "connection-source", y: 338)
        configure(sourceSide, label: "Source side", id: "connection-source-side", y: 294)
        configure(target, label: "Target", id: "connection-target", y: 250)
        configure(targetSide, label: "Target side", id: "connection-target-side", y: 206)
        for object in objects {
            source.addItem(withTitle: object.title)
            target.addItem(withTitle: object.title)
        }
        let sourceIndex = objects.firstIndex { $0.id == selectedID } ?? 0
        source.selectItem(at: sourceIndex)
        target.selectItem(at: objects.indices.first { $0 != sourceIndex } ?? sourceIndex)
        for popup in [sourceSide, targetSide] {
            popup.addItem(withTitle: "Automatic")
            for side in CanvasConnectionSide.allCases { popup.addItem(withTitle: side.rawValue.capitalized) }
        }
        if objects.count == 1 {
            sourceSide.selectItem(at: 2) // Right; self-loops require distinct named sides.
            targetSide.selectItem(at: 1) // Top.
        }
        let hint = NSTextField(wrappingLabelWithString:
            "Creates a curved arrow. Automatic sides follow the objects as they move. A self-loop needs two different named sides.")
        hint.frame = NSRect(x: 24, y: 144, width: 532, height: 48)
        hint.textColor = .secondaryLabelColor
        panel.contentView?.addSubview(hint)
        errorLabel.identifier = NSUserInterfaceItemIdentifier("connection-error")
        errorLabel.frame = NSRect(x: 24, y: 76, width: 532, height: 56)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        panel.contentView?.addSubview(errorLabel)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelEditing))
        cancel.frame = NSRect(x: 300, y: 20, width: 92, height: 32)
        cancel.keyEquivalent = "\u{1b}"
        cancel.identifier = NSUserInterfaceItemIdentifier("connection-cancel")
        let create = NSButton(title: "Create Connection", target: self, action: #selector(createConnection))
        create.frame = NSRect(x: 400, y: 20, width: 156, height: 32)
        create.keyEquivalent = "\r"
        create.identifier = NSUserInterfaceItemIdentifier("connection-create")
        panel.contentView?.addSubview(cancel)
        panel.contentView?.addSubview(create)
        source.nextKeyView = sourceSide
        sourceSide.nextKeyView = target
        target.nextKeyView = targetSide
        targetSide.nextKeyView = cancel
        cancel.nextKeyView = create
        create.nextKeyView = source
    }

    private func configure(_ popup: NSPopUpButton, label: String, id: String, y: CGFloat) {
        let field = NSTextField(labelWithString: label)
        field.frame = NSRect(x: 24, y: y + 5, width: 116, height: 22)
        popup.frame = NSRect(x: 148, y: y, width: 408, height: 32)
        popup.identifier = NSUserInterfaceItemIdentifier(id)
        popup.setAccessibilityLabel(label)
        panel.contentView?.addSubview(field)
        panel.contentView?.addSubview(popup)
    }

    func present(on window: NSWindow) {
        window.beginSheet(panel)
        panel.makeFirstResponder(target)
    }

    private func side(_ popup: NSPopUpButton) -> CanvasConnectionSide? {
        let index = popup.indexOfSelectedItem
        return index > 0 ? CanvasConnectionSide.allCases[index - 1] : nil
    }

    @objc private func createConnection() {
        guard objects.indices.contains(source.indexOfSelectedItem),
              objects.indices.contains(target.indexOfSelectedItem) else { return }
        do {
            try commit(objects[source.indexOfSelectedItem].id, side(sourceSide),
                       objects[target.indexOfSelectedItem].id, side(targetSide))
            dismiss()
        } catch {
            errorLabel.stringValue = error.localizedDescription
            errorLabel.isHidden = false
            panel.makeFirstResponder(sourceSide)
        }
    }

    @objc private func cancelEditing() { dismiss() }

    private func dismiss() {
        panel.sheetParent?.endSheet(panel)
        panel.orderOut(nil)
        completion()
    }
}
