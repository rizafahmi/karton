import AppKit
import CanvasCore

@MainActor
final class AttachmentPreviewSheet: NSObject {
    private final class PreviewTextView: NSTextView {
        var onClose: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection([.command, .control, .option])
            if flags.isEmpty && (event.keyCode == 53 || event.keyCode == 36) {
                onClose?()
                return
            }
            super.keyDown(with: event)
        }
    }

    private let panel: NSPanel
    private let attachment: CanvasAttachment
    private let pasteboard: NSPasteboard
    private let contentView: PreviewTextView
    private let statusLabel: NSTextField
    private let completion: () -> Void
    var saveDestinationProvider: ((String) -> URL?)?

    init(
        attachment: CanvasAttachment,
        pasteboard: NSPasteboard = .general,
        saveDestinationProvider: ((String) -> URL?)? = nil,
        completion: @escaping () -> Void
    ) {
        self.attachment = attachment
        self.pasteboard = pasteboard
        self.saveDestinationProvider = saveDestinationProvider
        self.completion = completion
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 400),
                        styleMask: [.titled], backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: .aqua)
        panel.backgroundColor = CanvasTheme.canvasBackground
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = CanvasTheme.canvasBackground.cgColor
        panel.title = attachment.filename
        contentView = PreviewTextView(frame: NSRect(x: 0, y: 0, width: 532, height: 224))
        statusLabel = NSTextField(wrappingLabelWithString:
            attachment.utf8ByteCount == 0 ? "This attachment is empty." : "")
        super.init()

        let titleLabel = NSTextField(labelWithString: attachment.filename)
        titleLabel.identifier = NSUserInterfaceItemIdentifier("attachment-preview-title")
        titleLabel.font = CanvasTypography.font("heading", "s", scale: 15.0 / 12.0)
        titleLabel.textColor = CanvasTheme.primaryText
        titleLabel.frame = NSRect(x: 24, y: 356, width: 532, height: 22)

        let metaLabel = NSTextField(labelWithString:
            "\(attachment.mediaType) · \(attachment.encoding.uppercased()) · \(attachment.utf8ByteCount) bytes · Literal source, not rendered markup")
        metaLabel.identifier = NSUserInterfaceItemIdentifier("attachment-preview-meta")
        metaLabel.font = CanvasTypography.font("mono", "s", scale: 11.0 / 14.0)
        metaLabel.textColor = CanvasTheme.mutedText
        metaLabel.frame = NSRect(x: 24, y: 332, width: 532, height: 18)

        let scroll = NSScrollView(frame: NSRect(x: 24, y: 96, width: 532, height: 224))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        contentView.identifier = NSUserInterfaceItemIdentifier("attachment-preview-content")
        contentView.isEditable = false
        contentView.isSelectable = true
        contentView.isRichText = false
        contentView.font = CanvasTypography.font("mono", "m")
        contentView.textColor = CanvasTheme.primaryText
        contentView.backgroundColor = CanvasTheme.elevatedSurface
        contentView.textContainerInset = NSSize(width: 8, height: 8)
        contentView.isVerticallyResizable = true
        contentView.isHorizontallyResizable = false
        contentView.autoresizingMask = [.width]
        contentView.textContainer?.widthTracksTextView = true
        contentView.string = attachment.content
        contentView.setAccessibilityLabel("Attachment source")
        contentView.onClose = { [weak self] in self?.closePreview() }
        scroll.documentView = contentView

        statusLabel.identifier = NSUserInterfaceItemIdentifier("attachment-preview-status")
        statusLabel.font = CanvasTypography.font("sans", "s", scale: 12.0 / 14.0)
        statusLabel.textColor = CanvasTheme.secondaryText
        statusLabel.frame = NSRect(x: 24, y: 58, width: 532, height: 28)
        statusLabel.isHidden = statusLabel.stringValue.isEmpty

        let saveCopyButton = NeoAcidActionButton(title: "Save Copy…", variant: .secondary, target: self, action: #selector(saveCopy))
        saveCopyButton.identifier = NSUserInterfaceItemIdentifier("attachment-preview-save-copy")
        saveCopyButton.frame = NSRect(x: 24, y: 18, width: 114, height: 32)
        saveCopyButton.toolTip = "Save an exact literal UTF-8 copy of this attachment"
        saveCopyButton.setAccessibilityLabel("Save literal attachment copy")

        let copyButton = NeoAcidActionButton(title: "Copy Source", variant: .secondary, target: self, action: #selector(copySource))
        copyButton.identifier = NSUserInterfaceItemIdentifier("attachment-preview-copy")
        copyButton.frame = NSRect(x: 344, y: 18, width: 112, height: 32)

        let closeButton = NeoAcidActionButton(title: "Close", variant: .primary, target: self, action: #selector(closePreview))
        closeButton.identifier = NSUserInterfaceItemIdentifier("attachment-preview-close")
        closeButton.frame = NSRect(x: 464, y: 18, width: 92, height: 32)
        closeButton.keyEquivalent = "\u{1b}"

        panel.contentView?.addSubview(titleLabel)
        panel.contentView?.addSubview(metaLabel)
        panel.contentView?.addSubview(scroll)
        panel.contentView?.addSubview(statusLabel)
        panel.contentView?.addSubview(saveCopyButton)
        panel.contentView?.addSubview(copyButton)
        panel.contentView?.addSubview(closeButton)
    }

    func present(on window: NSWindow) {
        window.beginSheet(panel)
        panel.makeFirstResponder(contentView)
    }

    @objc private func saveCopy() {
        let destination: URL?
        if let provider = saveDestinationProvider {
            destination = provider(attachment.filename)
        } else {
            let savePanel = NSSavePanel()
            savePanel.nameFieldStringValue = attachment.filename
            savePanel.canCreateDirectories = true
            destination = savePanel.runModal() == .OK ? savePanel.url : nil
        }
        guard let destination else { return }
        do {
            try Data(attachment.content.utf8).write(to: destination, options: .atomic)
            statusLabel.stringValue = "Saved literal copy to \(destination.lastPathComponent)."
            statusLabel.isHidden = false
        } catch {
            statusLabel.stringValue = "Could not save copy: \(error.localizedDescription)"
            statusLabel.isHidden = false
        }
    }

    @objc private func copySource() {
        pasteboard.clearContents()
        pasteboard.setData(Data(attachment.content.utf8), forType: .string)
        statusLabel.stringValue = "Copied literal source to clipboard."
        statusLabel.isHidden = false
    }

    @objc private func closePreview() {
        let parent = panel.sheetParent
        parent?.endSheet(panel)
        panel.orderOut(nil)
        parent?.makeKeyAndOrderFront(nil)
        completion()
    }
}
