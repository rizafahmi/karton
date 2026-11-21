import AppKit
import CanvasCore

@MainActor
final class ConnectionEditor: NSObject, NSTextFieldDelegate {
    struct ObjectOption {
        let id: String
        let title: String
    }

    private final class LabelTextField: NSTextField {
        var onSubmit: (() -> Void)?
        var onCancel: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 {
                onCancel?()
                return
            }
            if event.keyCode == 36 {
                onSubmit?()
                return
            }
            super.keyDown(with: event)
        }
    }

    private let panel: NSPanel
    private let objects: [ObjectOption]
    private let source = NeoAcidPopUpButton()
    private let target = NeoAcidPopUpButton()
    private let sourceSide = NeoAcidPopUpButton()
    private let targetSide = NeoAcidPopUpButton()
    private let labelField = LabelTextField()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let focusLabel: Bool
    private let commit: (String, CanvasConnectionSide?, String, CanvasConnectionSide?, String?) throws -> Void
    private let completion: () -> Void

    init(
        objects: [ObjectOption],
        selectedID: String? = nil,
        existingConnection: CanvasConnectionState? = nil,
        focusLabel: Bool = false,
        commit: @escaping (String, CanvasConnectionSide?, String, CanvasConnectionSide?, String?) throws -> Void,
        completion: @escaping () -> Void
    ) {
        self.objects = objects
        self.focusLabel = focusLabel
        self.commit = commit
        self.completion = completion
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 444),
                        styleMask: [.titled], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .aqua)
        panel.backgroundColor = CanvasTheme.canvasBackground
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = CanvasTheme.canvasBackground.cgColor
        super.init()
        let isEditing = existingConnection != nil
        panel.title = isEditing ? "Edit Connection" : "Create Connection"
        configure(source, label: "Source", id: "connection-source", y: 382)
        configure(sourceSide, label: "Source side", id: "connection-source-side", y: 338)
        configure(target, label: "Target", id: "connection-target", y: 294)
        configure(targetSide, label: "Target side", id: "connection-target-side", y: 250)

        let labelCaption = NSTextField(labelWithString: "Label")
        labelCaption.font = CanvasTypography.font("sans", "m", scale: 12.5 / 16.0)
        labelCaption.textColor = CanvasTheme.primaryText
        labelCaption.frame = NSRect(x: 24, y: 211, width: 116, height: 22)
        labelField.frame = NSRect(x: 148, y: 206, width: 408, height: 28)
        labelField.identifier = NSUserInterfaceItemIdentifier("connection-label")
        labelField.placeholderString = "Optional label"
        labelField.setAccessibilityLabel("Label")
        labelField.isEditable = true
        labelField.isSelectable = true
        labelField.isBezeled = true
        labelField.bezelStyle = .squareBezel
        labelField.font = CanvasTypography.font("sans", "m", scale: 13.0 / 16.0)
        labelField.delegate = self
        labelField.onSubmit = { [weak self] in self?.createConnection() }
        labelField.onCancel = { [weak self] in self?.cancelEditing() }
        panel.contentView?.addSubview(labelCaption)
        panel.contentView?.addSubview(labelField)

        for object in objects {
            source.addItem(withTitle: object.title)
            target.addItem(withTitle: object.title)
        }
        for popup in [sourceSide, targetSide] {
            popup.addItem(withTitle: "Automatic")
            for side in CanvasConnectionSide.allCases { popup.addItem(withTitle: side.rawValue.capitalized) }
        }
        if let existing = existingConnection {
            let sIdx = objects.firstIndex { $0.id == existing.source } ?? 0
            let tIdx = objects.firstIndex { $0.id == existing.target } ?? 0
            source.selectItem(at: sIdx)
            target.selectItem(at: tIdx)
            let sSideIdx = existing.sourceSide.flatMap { CanvasConnectionSide.allCases.firstIndex(of: $0).map { $0 + 1 } } ?? 0
            let tSideIdx = existing.targetSide.flatMap { CanvasConnectionSide.allCases.firstIndex(of: $0).map { $0 + 1 } } ?? 0
            sourceSide.selectItem(at: sSideIdx)
            targetSide.selectItem(at: tSideIdx)
            labelField.stringValue = existing.label ?? ""
        } else {
            let sourceIndex = objects.firstIndex { $0.id == selectedID } ?? 0
            source.selectItem(at: sourceIndex)
            target.selectItem(at: objects.indices.first { $0 != sourceIndex } ?? sourceIndex)
            if objects.count == 1 {
                sourceSide.selectItem(at: 2) // Right; self-loops require distinct named sides.
                targetSide.selectItem(at: 1) // Top.
            }
            labelField.stringValue = ""
        }

        let hint = NSTextField(wrappingLabelWithString:
            "Creates or updates a bound arrow. Automatic sides follow the objects as they move. A self-loop needs two different named sides.")
        hint.font = CanvasTypography.font("sans", "s", scale: 12.0 / 14.0)
        hint.frame = NSRect(x: 24, y: 144, width: 532, height: 48)
        hint.textColor = CanvasTheme.secondaryText
        panel.contentView?.addSubview(hint)
        errorLabel.identifier = NSUserInterfaceItemIdentifier("connection-error")
        errorLabel.font = CanvasTypography.font("sans", "s", scale: 12.0 / 14.0)
        errorLabel.frame = NSRect(x: 24, y: 76, width: 532, height: 56)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        panel.contentView?.addSubview(errorLabel)
        let cancel = NeoAcidActionButton(title: "Cancel", variant: .secondary, target: self, action: #selector(cancelEditing))
        cancel.frame = NSRect(x: 300, y: 20, width: 92, height: 32)
        cancel.keyEquivalent = "\u{1b}"
        cancel.identifier = NSUserInterfaceItemIdentifier("connection-cancel")
        let create = NeoAcidActionButton(title: isEditing ? "Save Connection" : "Create Connection",
                                         variant: .primary, target: self, action: #selector(createConnection))
        create.frame = NSRect(x: 400, y: 20, width: 156, height: 32)
        create.keyEquivalent = "\r"
        create.identifier = NSUserInterfaceItemIdentifier("connection-create")
        panel.contentView?.addSubview(cancel)
        panel.contentView?.addSubview(create)
        source.nextKeyView = sourceSide
        sourceSide.nextKeyView = target
        target.nextKeyView = targetSide
        targetSide.nextKeyView = labelField
        labelField.nextKeyView = cancel
        cancel.nextKeyView = create
        create.nextKeyView = source
    }

    private func configure(_ popup: NSPopUpButton, label: String, id: String, y: CGFloat) {
        let field = NSTextField(labelWithString: label)
        field.font = CanvasTypography.font("sans", "m", scale: 12.5 / 16.0)
        field.textColor = CanvasTheme.primaryText
        field.frame = NSRect(x: 24, y: y + 4, width: 116, height: 22)
        popup.frame = NSRect(x: 148, y: y + 2, width: 408, height: 28)
        popup.identifier = NSUserInterfaceItemIdentifier(id)
        popup.setAccessibilityLabel(label)
        panel.contentView?.addSubview(field)
        panel.contentView?.addSubview(popup)
    }

    func present(on window: NSWindow) {
        window.beginSheet(panel)
        panel.makeFirstResponder(focusLabel ? labelField : target)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            createConnection()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelEditing()
            return true
        }
        return false
    }

    private func side(_ popup: NSPopUpButton) -> CanvasConnectionSide? {
        let index = popup.indexOfSelectedItem
        return index > 0 ? CanvasConnectionSide.allCases[index - 1] : nil
    }

    @objc private func createConnection() {
        guard objects.indices.contains(source.indexOfSelectedItem),
              objects.indices.contains(target.indexOfSelectedItem) else { return }
        if let fieldEditor = panel.fieldEditor(false, for: labelField) as? NSTextView,
           fieldEditor.hasMarkedText() {
            return
        }
        do {
            let labelValue = labelField.stringValue.isEmpty ? nil : labelField.stringValue
            try commit(
                objects[source.indexOfSelectedItem].id,
                side(sourceSide),
                objects[target.indexOfSelectedItem].id,
                side(targetSide),
                labelValue
            )
            dismiss()
        } catch {
            errorLabel.stringValue = error.localizedDescription
            errorLabel.isHidden = false
            if error.localizedDescription.localizedCaseInsensitiveContains("label") {
                panel.makeFirstResponder(labelField)
            } else {
                panel.makeFirstResponder(sourceSide)
            }
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
