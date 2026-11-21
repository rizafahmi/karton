import AppKit
import CanvasCore

@MainActor
public final class CodeSnippetEditorView: NSView, NSTextViewDelegate {
    @MainActor
    public final class CodeSourceTextView: NSTextView {
        var onFinish: (() -> Void)?
        var onExitToControls: (() -> Void)?
        var onSourceDidChange: (() -> Void)?

        public override func keyDown(with event: NSEvent) {
            if hasMarkedText() {
                super.keyDown(with: event)
                return
            }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])

            // Command-Return: exit text view to language/action controls (shared/CODE_SNIPPETS.md §4).
            if (event.keyCode == 36 || event.keyCode == 76) && flags == [.command] {
                onExitToControls?()
                return
            }
            // Escape: finish/commit valid draft (shared/CODE_SNIPPETS.md §4).
            if event.keyCode == 53 && flags.isEmpty {
                onFinish?()
                return
            }
            // Plain Return / Shift-Return: insert literal line ending (never finish or create node).
            if (event.keyCode == 36 || event.keyCode == 76) && (flags.isEmpty || flags == [.shift]) {
                insertPreferredLineEnding()
                return
            }
            // Tab: indent affected lines by 2 spaces.
            if event.keyCode == 48 && flags.isEmpty {
                applyIndentation(unindent: false)
                return
            }
            // Shift-Tab: unindent affected lines by 1 tab or up to 2 spaces.
            if event.keyCode == 48 && flags == [.shift] {
                applyIndentation(unindent: true)
                return
            }
            super.keyDown(with: event)
        }

        public override func insertNewline(_ sender: Any?) {
            if hasMarkedText() {
                super.insertNewline(sender)
                return
            }
            insertPreferredLineEnding()
        }

        public override func insertTab(_ sender: Any?) {
            applyIndentation(unindent: false)
        }

        public override func insertBacktab(_ sender: Any?) {
            applyIndentation(unindent: true)
        }

        private func insertPreferredLineEnding() {
            let sel = selectedRange()
            let newline = CanvasCodeSnippet.preferredLineEnding(in: string, atUTF16Offset: sel.location)
            if shouldChangeText(in: sel, replacementString: newline) {
                textStorage?.replaceCharacters(in: sel, with: newline)
                didChangeText()
                setSelectedRange(NSRange(location: sel.location + (newline as NSString).length, length: 0))
                onSourceDidChange?()
            }
        }

        private func applyIndentation(unindent: Bool) {
            let current = string
            let sel = selectedRange()
            let updated = unindent
                ? CanvasCodeSnippet.unindent(source: current, selection: sel)
                : CanvasCodeSnippet.indent(source: current, selection: sel)
            guard updated.text != current else { return }
            let fullRange = NSRange(location: 0, length: (current as NSString).length)
            if shouldChangeText(in: fullRange, replacementString: updated.text) {
                textStorage?.replaceCharacters(in: fullRange, with: updated.text)
                didChangeText()
                setSelectedRange(updated.selection)
                onSourceDidChange?()
            }
        }
    }

    private final class EditorControlButton: NSButton {
        var onEscape: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                onEscape?()
                return
            }
            super.keyDown(with: event)
        }
    }

    private final class EditorLanguagePopUp: NSPopUpButton {
        var onEscape: (() -> Void)?
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                onEscape?()
                return
            }
            super.keyDown(with: event)
        }
    }

    public struct DraftResult {
        public let source: String
        public let language: String?
        public let languageWasChanged: Bool
        public let fitToContent: Bool
    }

    public let targetNodeID: String?
    public let initialStoredLanguage: String?
    public private(set) var languageWasExplicitlyChanged: Bool = false

    private let titleLabel = NSTextField(labelWithString: "Code Snippet")
    private let languageLabel = NSTextField(labelWithString: "Language")
    private let languagePopUp = EditorLanguagePopUp(frame: .zero, pullsDown: false)
    private let metaLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView(frame: .zero)
    public let sourceTextView = CodeSourceTextView(frame: .zero)
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let copyButton = EditorControlButton(title: "Copy Code", target: nil, action: nil)
    private let fitCheckbox = EditorControlButton(checkboxWithTitle: "Fit to content", target: nil, action: nil)
    private let cancelButton = EditorControlButton(title: "Cancel", target: nil, action: nil)
    private let finishButton = EditorControlButton(title: "Finish", target: nil, action: nil)
    private var languageOptionIDs: [String] = []
    private let pasteboard: NSPasteboard
    private let draftUndoManager = UndoManager()

    public var validateDraft: ((String) -> String?)?
    public var onCommit: ((DraftResult) -> String?)?
    public var onCancel: (() -> Void)?
    public var onDraftDidChange: (() -> Void)?

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }

    public var currentSource: String {
        sourceTextView.string
    }

    public var isFitChecked: Bool {
        get { fitCheckbox.state == .on }
        set { fitCheckbox.state = newValue ? .on : .off }
    }

    public var hasMarkedText: Bool {
        sourceTextView.hasMarkedText()
    }

    public var selectedLanguageID: String {
        let idx = languagePopUp.indexOfSelectedItem
        if idx >= 0 && idx < languageOptionIDs.count {
            return languageOptionIDs[idx]
        }
        return initialStoredLanguage ?? CanvasCodeLanguage.auto.rawValue
    }

    public init(
        targetNodeID: String?,
        initialSource: String,
        initialStoredLanguage: String?,
        pasteboard: NSPasteboard = .general
    ) {
        self.targetNodeID = targetNodeID
        self.initialStoredLanguage = initialStoredLanguage
        self.pasteboard = pasteboard
        super.init(frame: NSRect(x: 0, y: 0, width: 560, height: 372))
        identifier = NSUserInterfaceItemIdentifier("code-snippet-editor")
        setAccessibilityRole(.group)
        setAccessibilityLabel(targetNodeID == nil ? "New code snippet editor" : "Code snippet editor")

        buildUI(initialSource: initialSource, initialStoredLanguage: initialStoredLanguage)
        refreshMetadataAndValidation()
    }

    public required init?(coder: NSCoder) {
        fatalError("CodeSnippetEditorView does not support NSCoder")
    }

    private func buildUI(initialSource: String, initialStoredLanguage: String?) {
        titleLabel.identifier = NSUserInterfaceItemIdentifier("code-editor-title")
        titleLabel.stringValue = targetNodeID == nil ? "New Code Block" : "Edit Code Block"
        titleLabel.font = CanvasTypography.font("heading", "s", scale: 13.0 / 12.0)
        titleLabel.textColor = CanvasTheme.primaryText

        languageLabel.font = .systemFont(ofSize: 12, weight: .medium)
        languageLabel.textColor = CanvasTheme.secondaryText

        languagePopUp.identifier = NSUserInterfaceItemIdentifier("code-editor-language")
        languagePopUp.font = .systemFont(ofSize: 12)
        languagePopUp.target = self
        languagePopUp.action = #selector(languageChanged(_:))
        languagePopUp.setAccessibilityLabel("Code language")
        languagePopUp.onEscape = { [weak self] in self?.attemptFinish() }
        populateLanguageMenu(storedLanguage: initialStoredLanguage)

        metaLabel.identifier = NSUserInterfaceItemIdentifier("code-editor-meta")
        metaLabel.font = CanvasTypography.font("mono", "s", scale: 10.5 / 12.0)
        metaLabel.textColor = CanvasTheme.mutedText
        metaLabel.alignment = .right

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        sourceTextView.identifier = NSUserInterfaceItemIdentifier("code-editor-source")
        sourceTextView.delegate = self
        sourceTextView.isEditable = true
        sourceTextView.isSelectable = true
        sourceTextView.isRichText = false
        sourceTextView.usesFontPanel = false
        sourceTextView.allowsUndo = true
        sourceTextView.isAutomaticQuoteSubstitutionEnabled = false
        sourceTextView.isAutomaticDashSubstitutionEnabled = false
        sourceTextView.isAutomaticTextReplacementEnabled = false
        sourceTextView.isAutomaticSpellingCorrectionEnabled = false
        sourceTextView.isContinuousSpellCheckingEnabled = false
        sourceTextView.isGrammarCheckingEnabled = false
        sourceTextView.smartInsertDeleteEnabled = false
        sourceTextView.font = CanvasTypography.font("mono", "m")
        sourceTextView.textColor = CanvasTheme.primaryText
        sourceTextView.backgroundColor = CanvasTheme.elevatedSurface
        sourceTextView.insertionPointColor = CanvasTheme.selectionCobalt
        sourceTextView.textContainerInset = NSSize(width: 8, height: 8)
        sourceTextView.isVerticallyResizable = true
        sourceTextView.isHorizontallyResizable = true
        sourceTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        sourceTextView.textContainer?.widthTracksTextView = false
        sourceTextView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        sourceTextView.string = initialSource
        sourceTextView.undoManager?.removeAllActions()
        sourceTextView.setAccessibilityLabel("Code source")
        sourceTextView.onFinish = { [weak self] in self?.attemptFinish() }
        sourceTextView.onExitToControls = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.languagePopUp)
        }
        sourceTextView.onSourceDidChange = { [weak self] in
            self?.refreshMetadataAndValidation()
            self?.onDraftDidChange?()
        }
        scrollView.documentView = sourceTextView

        errorLabel.identifier = NSUserInterfaceItemIdentifier("code-editor-error")
        errorLabel.font = .systemFont(ofSize: 12, weight: .medium)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true

        copyButton.identifier = NSUserInterfaceItemIdentifier("code-editor-copy")
        copyButton.target = self
        copyButton.action = #selector(copyCodeClicked(_:))
        copyButton.bezelStyle = .rounded
        copyButton.font = .systemFont(ofSize: 12, weight: .medium)
        copyButton.setAccessibilityLabel("Copy literal code")
        copyButton.onEscape = { [weak self] in self?.attemptFinish() }

        fitCheckbox.identifier = NSUserInterfaceItemIdentifier("code-editor-fit")
        fitCheckbox.target = self
        fitCheckbox.action = #selector(fitToggled(_:))
        fitCheckbox.state = .off // Always ephemeral & unchecked per editor session.
        fitCheckbox.font = .systemFont(ofSize: 12)
        fitCheckbox.setAccessibilityLabel("Fit box to content on finish")
        fitCheckbox.onEscape = { [weak self] in self?.attemptFinish() }

        cancelButton.identifier = NSUserInterfaceItemIdentifier("code-editor-cancel")
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))
        cancelButton.bezelStyle = .rounded
        cancelButton.font = .systemFont(ofSize: 12, weight: .medium)
        cancelButton.setAccessibilityLabel("Cancel code edit")
        cancelButton.onEscape = { [weak self] in self?.attemptFinish() }

        finishButton.identifier = NSUserInterfaceItemIdentifier("code-editor-finish")
        finishButton.target = self
        finishButton.action = #selector(finishClicked(_:))
        finishButton.bezelStyle = .rounded
        finishButton.font = .systemFont(ofSize: 12, weight: .semibold)
        finishButton.setAccessibilityLabel("Finish code edit")
        finishButton.onEscape = { [weak self] in self?.attemptFinish() }

        addSubview(titleLabel)
        addSubview(languageLabel)
        addSubview(languagePopUp)
        addSubview(metaLabel)
        addSubview(scrollView)
        addSubview(errorLabel)
        addSubview(copyButton)
        addSubview(fitCheckbox)
        addSubview(cancelButton)
        addSubview(finishButton)

        // Keyboard order: Source -> Language -> Copy -> Fit -> Cancel -> Finish
        sourceTextView.nextKeyView = languagePopUp
        languagePopUp.nextKeyView = copyButton
        copyButton.nextKeyView = fitCheckbox
        fitCheckbox.nextKeyView = cancelButton
        cancelButton.nextKeyView = finishButton
        finishButton.nextKeyView = sourceTextView

        layoutSubviews()
    }

    private func populateLanguageMenu(storedLanguage: String?) {
        languagePopUp.removeAllItems()
        languageOptionIDs.removeAll()

        if let storedLanguage, CanvasCodeLanguage(rawValue: storedLanguage) == nil {
            languagePopUp.addItem(withTitle: CanvasCodeLanguage.displayLabel(for: storedLanguage))
            languageOptionIDs.append(storedLanguage)
        }
        for lang in CanvasCodeLanguage.allCases {
            languagePopUp.addItem(withTitle: lang.displayName)
            languageOptionIDs.append(lang.rawValue)
        }

        let targetID = storedLanguage ?? CanvasCodeLanguage.auto.rawValue
        if let idx = languageOptionIDs.firstIndex(of: targetID) {
            languagePopUp.selectItem(at: idx)
        } else {
            languagePopUp.selectItem(at: 0)
        }
    }

    public func selectLanguage(_ languageID: String) {
        if let idx = languageOptionIDs.firstIndex(of: languageID) {
            languagePopUp.selectItem(at: idx)
            languageWasExplicitlyChanged = true
            refreshMetadataAndValidation()
            onDraftDidChange?()
        }
    }

    public func focusSourceEditor() {
        window?.makeFirstResponder(sourceTextView)
    }

    public func showError(_ message: String) {
        errorLabel.stringValue = message
        errorLabel.isHidden = message.isEmpty
        layoutSubviews()
        needsDisplay = true
    }

    @discardableResult
    public func attemptFinish() -> Bool {
        if sourceTextView.hasMarkedText() {
            showError("Finish active text composition before committing.")
            return false
        }
        let source = sourceTextView.string
        if let error = validateDraft?(source) {
            showError(error)
            return false
        }
        let result = DraftResult(
            source: source,
            language: selectedLanguageID,
            languageWasChanged: languageWasExplicitlyChanged,
            fitToContent: fitCheckbox.state == .on
        )
        if let commitError = onCommit?(result) {
            showError(commitError)
            return false
        }
        return true
    }

    public func copyLiteralSourceToPasteboard() {
        pasteboard.clearContents()
        let ok = pasteboard.setData(Data(sourceTextView.string.utf8), forType: .string)
        if ok {
            metaLabel.stringValue = "Copied \(sourceTextView.string.utf8.count) B"
        } else {
            showError("Could not copy code to the clipboard.")
        }
    }

    private func refreshMetadataAndValidation() {
        let source = sourceTextView.string
        let byteCount = source.utf8.count
        let langID = selectedLanguageID
        if langID == CanvasCodeLanguage.auto.rawValue {
            if let detected = CanvasCodeHighlighter.shared.detectLanguage(for: source) {
                metaLabel.stringValue = "Auto: \(detected.displayName) · \(byteCount) B"
            } else {
                metaLabel.stringValue = "Auto: Plain text · \(byteCount) B"
            }
        } else {
            metaLabel.stringValue = "\(CanvasCodeLanguage.displayLabel(for: langID)) · \(byteCount) B"
        }

        if let validationError = validateDraft?(source) {
            errorLabel.stringValue = validationError
            errorLabel.isHidden = false
        } else {
            errorLabel.stringValue = ""
            errorLabel.isHidden = true
        }
        layoutSubviews()
        needsDisplay = true
    }

    public func undoManager(for view: NSTextView) -> UndoManager? {
        draftUndoManager
    }

    public func textDidChange(_ notification: Notification) {
        refreshMetadataAndValidation()
        onDraftDidChange?()
    }

    public override func mouseDown(with event: NSEvent) {}
    public override func mouseDragged(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) {}

    public override func draw(_ dirtyRect: NSRect) {
        CanvasTheme.surface.setFill()
        bounds.fill()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        CanvasTheme.borderStrong.setStroke()
        border.stroke()

        let headerDivider = NSBezierPath()
        headerDivider.move(to: CGPoint(x: 0, y: 42))
        headerDivider.line(to: CGPoint(x: bounds.width, y: 42))
        headerDivider.lineWidth = 1
        CanvasTheme.borderSubtle.setStroke()
        headerDivider.stroke()
    }

    private func layoutSubviews() {
        let pad: CGFloat = 14
        let width = bounds.width
        titleLabel.frame = NSRect(x: pad, y: 12, width: 140, height: 20)
        languageLabel.frame = NSRect(x: 158, y: 14, width: 62, height: 18)
        languagePopUp.frame = NSRect(x: 222, y: 9, width: 138, height: 24)
        metaLabel.frame = NSRect(x: 366, y: 14, width: max(60, width - 366 - pad), height: 18)

        let bottomBarHeight: CGFloat = 42
        let errorHeight: CGFloat = errorLabel.isHidden ? 0 : 28
        let editorTop: CGFloat = 50
        let editorHeight = max(120, bounds.height - editorTop - bottomBarHeight - errorHeight - 8)
        scrollView.frame = NSRect(x: pad, y: editorTop, width: width - pad * 2, height: editorHeight)
        sourceTextView.minSize = NSSize(width: max(200, scrollView.contentSize.width), height: scrollView.contentSize.height)

        if !errorLabel.isHidden {
            errorLabel.frame = NSRect(
                x: pad,
                y: editorTop + editorHeight + 4,
                width: width - pad * 2,
                height: errorHeight - 2
            )
        }

        let barY = bounds.height - bottomBarHeight + 6
        copyButton.frame = NSRect(x: pad, y: barY, width: 92, height: 28)
        fitCheckbox.frame = NSRect(x: pad + 104, y: barY + 5, width: 120, height: 18)
        finishButton.frame = NSRect(x: width - pad - 76, y: barY, width: 76, height: 28)
        cancelButton.frame = NSRect(x: width - pad - 76 - 8 - 76, y: barY, width: 76, height: 28)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutSubviews()
    }

    @objc private func languageChanged(_ sender: Any?) {
        languageWasExplicitlyChanged = true
        refreshMetadataAndValidation()
        onDraftDidChange?()
    }

    @objc private func copyCodeClicked(_ sender: Any?) {
        copyLiteralSourceToPasteboard()
    }

    @objc private func fitToggled(_ sender: Any?) {
        // Ephemeral choice only; never commits on toggle (shared/CODE_SNIPPETS.md §4).
        onDraftDidChange?()
    }

    @objc private func cancelClicked(_ sender: Any?) {
        onCancel?()
    }

    @objc private func finishClicked(_ sender: Any?) {
        attemptFinish()
    }
}
