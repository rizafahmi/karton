import AppKit
import CanvasCore
import CoreText
import UniformTypeIdentifiers

/// Bundled Neo-Acid and Amatic SC typography resolution with CoreText system glyph fallback,
/// shared between on-screen `CanvasView` layout/editing and offscreen PNG export.
public enum CanvasTypography {
    public static let requiredPostScriptNames: [String] = [
        "MonaSansExtraLight-Regular",
        "MonaSansExtraLight-Bold",
        "MonaspaceNeon-Regular",
        "MonaspaceNeon-Bold",
        "Unbounded-ExtraBold",
        "AmaticSC-Bold",
    ]

    private static let fontFilenames: [String] = [
        "mona-sans-latin-400-normal.woff2",
        "mona-sans-latin-700-normal.woff2",
        "monaspace-neon-latin-400-normal.woff2",
        "monaspace-neon-latin-700-normal.woff2",
        "unbounded-latin-800-normal.woff2",
        "AmaticSC-Bold.ttf",
    ]

    public nonisolated(unsafe) static var customFontDirectoryURL: URL?
    public nonisolated(unsafe) static private(set) var registeredFontDirectoryURL: URL?
    private nonisolated(unsafe) static var didAttemptRegistration = false
    private nonisolated(unsafe) static var allFacesAvailable = false
    private static let lock = NSLock()

    /// Ensures the six bundled Neo-Acid and Amatic SC font faces are registered with CoreText
    /// before any canvas text measurement, inline editor sizing, or PNG export runs.
    @discardableResult
    public static func ensureRegistered() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if didAttemptRegistration && allFacesAvailable {
            return true
        }
        didAttemptRegistration = true

        for directory in candidateFontDirectories() {
            var registeredCount = 0
            for filename in fontFilenames {
                let url = directory.appendingPathComponent(filename)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                registeredCount += 1
            }
            if registeredCount == fontFilenames.count && registeredFontDirectoryURL == nil {
                registeredFontDirectoryURL = directory
            }
        }

        allFacesAvailable = requiredPostScriptNames.allSatisfy { name in
            guard let resolved = NSFont(name: name, size: 16) else { return false }
            return (CTFontCopyPostScriptName(resolved as CTFont) as String) == name
        }
        return allFacesAvailable
    }

    private static func candidateFontDirectories() -> [URL] {
        var directories: [URL] = []
        if let bundleFonts = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true) {
            directories.append(bundleFonts)
        }
        let executableURL = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
        let appBundleFonts = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts", isDirectory: true)
        directories.append(appBundleFonts)
        if let customFontDirectoryURL {
            directories.append(customFontDirectoryURL)
        }
        return directories
    }

    /// Maps portable JSON role (`sans`, `heading`, `mono`, `handwritten`) and size (`s`, `m`, `l`)
    /// to the canonical bundled PostScript font name (DESIGN.md §3).
    public static func postScriptName(role: String, size: String) -> String {
        let isLarge = size == "l"
        switch role {
        case "mono":
            return isLarge ? "MonaspaceNeon-Bold" : "MonaspaceNeon-Regular"
        case "heading":
            return "Unbounded-ExtraBold"
        case "handwritten":
            return "AmaticSC-Bold"
        default:
            return isLarge ? "MonaSansExtraLight-Bold" : "MonaSansExtraLight-Regular"
        }
    }

    /// Resolves the `NSFont` for a semantic role and size, attaching a CoreText system
    /// cascade list so non-Latin scripts and emoji render with native glyph fallback.
    public static func font(_ role: String, _ size: String, scale: CGFloat = 1.0) -> NSFont {
        _ = ensureRegistered()
        let points: CGFloat = max(4, (size == "s" ? 12 : size == "l" ? 24 : 16) * scale)
        let psName = postScriptName(role: role, size: size)
        let fallbackWeight: NSFont.Weight =
            role == "heading" ? .heavy : (size == "l" || role == "handwritten" ? .bold : .regular)
        let systemFallback: NSFont =
            role == "mono"
            ? .monospacedSystemFont(ofSize: points, weight: fallbackWeight)
            : .systemFont(ofSize: points, weight: fallbackWeight)

        let descriptor = NSFontDescriptor(fontAttributes: [
            .name: psName,
            .cascadeList: [systemFallback.fontDescriptor],
        ])
        if let resolved = NSFont(descriptor: descriptor, size: points),
           (CTFontCopyPostScriptName(resolved as CTFont) as String) == psName {
            return resolved
        }
        return systemFallback
    }

    /// Returns the PostScript font names chosen by CoreText across glyph runs for `text`,
    /// allowing verification of both primary Neo-Acid faces and CJK/emoji cascade fallback.
    public static func glyphRunPostScriptNames(
        for text: String, role: String, size: String = "m"
    ) -> [String] {
        let resolvedFont = font(role, size)
        let attributed = NSAttributedString(string: text, attributes: [.font: resolvedFont])
        let line = CTLineCreateWithAttributedString(attributed)
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return [] }
        return runs.compactMap { run in
            guard let attrs = CTRunGetAttributes(run) as? [String: Any],
                  let runFont = attrs[kCTFontAttributeName as String] else { return nil }
            return CTFontCopyPostScriptName(runFont as! CTFont) as String
        }
    }
}

/// Output sizing modes for native transparent PNG export (`macos/SPEC.md §7`, `TASKS.md:837`).
public enum CanvasPNGExportSizing: Equatable, Sendable {
    public static let defaultLongestSide = 2_048
    public static let defaultPadding: Double = 32
    public static let maxSidePixels = 8_192
    public static let maxTotalPixels = 16_777_216

    /// Proportional output where the longest side equals the given pixel count and the
    /// shorter dimension is rounded up to at least 1 pixel.
    case longestSide(Int)
    /// Exact pixel dimensions; content is fitted proportionally with transparent letterboxing,
    /// never stretched.
    case exact(width: Int, height: Int)
}

/// Content scope for native transparent PNG export.
public enum CanvasPNGExportScope: Equatable, Hashable, Sendable {
    /// Export the current selection if any items are selected; otherwise export the entire canvas.
    case automatic
    /// Export the entire canvas regardless of current selection.
    case entireCanvas
    /// Export only the currently selected items.
    case selection
}

/// Validated world-to-pixel export layout for an immutable canvas snapshot.
public struct CanvasPNGExportPlan: Equatable, Sendable {
    public let contentWorldBounds: CGRect
    public let paddedWorldBounds: CGRect
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scale: CGFloat
    public let offsetX: CGFloat
    public let offsetY: CGFloat

    public static func resolve(
        contentWorldBounds: CGRect,
        sizing: CanvasPNGExportSizing = .longestSide(CanvasPNGExportSizing.defaultLongestSide),
        padding: Double = CanvasPNGExportSizing.defaultPadding
    ) throws -> CanvasPNGExportPlan {
        guard !contentWorldBounds.isNull,
              !contentWorldBounds.isEmpty,
              contentWorldBounds.origin.x.isFinite,
              contentWorldBounds.origin.y.isFinite,
              contentWorldBounds.width.isFinite,
              contentWorldBounds.height.isFinite,
              contentWorldBounds.width > 0,
              contentWorldBounds.height > 0 else {
            throw CanvasDocumentError("Cannot export an empty canvas.")
        }
        guard padding.isFinite, padding >= 0 else {
            throw CanvasDocumentError("PNG export padding must be a non-negative finite number.")
        }
        let pad = CGFloat(padding)
        let padded = contentWorldBounds.insetBy(dx: -pad, dy: -pad)
        guard padded.width.isFinite, padded.height.isFinite, padded.width > 0, padded.height > 0 else {
            throw CanvasDocumentError("Invalid export content bounds.")
        }

        let pixelWidth: Int
        let pixelHeight: Int
        switch sizing {
        case .longestSide(let longest):
            guard longest >= 1 else {
                throw CanvasDocumentError("PNG longest side must be at least 1 pixel.")
            }
            guard longest <= CanvasPNGExportSizing.maxSidePixels else {
                throw CanvasDocumentError(
                    "PNG dimensions cannot exceed \(CanvasPNGExportSizing.maxSidePixels) pixels per side."
                )
            }
            if padded.width >= padded.height {
                pixelWidth = longest
                let rawHeight = Double(longest) * Double(padded.height / padded.width)
                pixelHeight = max(1, Int(ceil(rawHeight - 1e-9)))
            } else {
                pixelHeight = longest
                let rawWidth = Double(longest) * Double(padded.width / padded.height)
                pixelWidth = max(1, Int(ceil(rawWidth - 1e-9)))
            }
        case .exact(let width, let height):
            guard width >= 1, height >= 1 else {
                throw CanvasDocumentError("PNG width and height must be at least 1 pixel.")
            }
            guard width <= CanvasPNGExportSizing.maxSidePixels,
                  height <= CanvasPNGExportSizing.maxSidePixels else {
                throw CanvasDocumentError(
                    "PNG dimensions cannot exceed \(CanvasPNGExportSizing.maxSidePixels) pixels per side."
                )
            }
            pixelWidth = width
            pixelHeight = height
        }

        guard pixelWidth <= CanvasPNGExportSizing.maxSidePixels,
              pixelHeight <= CanvasPNGExportSizing.maxSidePixels else {
            throw CanvasDocumentError(
                "PNG dimensions cannot exceed \(CanvasPNGExportSizing.maxSidePixels) pixels per side."
            )
        }
        let totalPixels = Int64(pixelWidth) * Int64(pixelHeight)
        guard totalPixels <= Int64(CanvasPNGExportSizing.maxTotalPixels) else {
            throw CanvasDocumentError(
                "PNG total area (\(pixelWidth)×\(pixelHeight) = \(totalPixels) pixels) cannot exceed \(CanvasPNGExportSizing.maxTotalPixels) pixels."
            )
        }

        let scale = min(CGFloat(pixelWidth) / padded.width, CGFloat(pixelHeight) / padded.height)
        let drawnWidth = padded.width * scale
        let drawnHeight = padded.height * scale
        let offsetX = (CGFloat(pixelWidth) - drawnWidth) / 2
        let offsetY = (CGFloat(pixelHeight) - drawnHeight) / 2

        return CanvasPNGExportPlan(
            contentWorldBounds: contentWorldBounds,
            paddedWorldBounds: padded,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            scale: scale,
            offsetX: offsetX,
            offsetY: offsetY
        )
    }
}

@MainActor
final class PNGExportPreviewView: NSView {
    var theme: CanvasPNGExportTheme = .light {
        didSet { needsDisplay = true }
    }
    var previewImage: NSImage? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let backdrop = CanvasTheme.previewBackdrop(theme: theme)
        backdrop.setFill()
        bounds.fill()

        // Subtle dot pattern on the simulated slide backdrop so transparency reads clearly.
        let dotColor = (theme == .dark ? CanvasTheme.darkPrimaryText : CanvasTheme.mutedText)
            .withAlphaComponent(theme == .dark ? 0.14 : 0.20)
        dotColor.setFill()
        var gx: CGFloat = 14
        while gx < bounds.width - 8 {
            var gy: CGFloat = 14
            while gy < bounds.height - 8 {
                NSBezierPath(ovalIn: CGRect(x: gx - 0.6, y: gy - 0.6, width: 1.2, height: 1.2)).fill()
                gy += 16
            }
            gx += 16
        }

        if let image = previewImage, image.size.width > 0, image.size.height > 0 {
            let inset = bounds.insetBy(dx: 12, dy: 12)
            let scale = min(inset.width / image.size.width, inset.height / image.size.height)
            let drawSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let drawRect = NSRect(
                x: inset.minX + (inset.width - drawSize.width) / 2,
                y: inset.minY + (inset.height - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height
            )
            image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        }

        let badgeText = (theme == .dark ? "DARK SLIDE PREVIEW" : "LIGHT SLIDE PREVIEW") as NSString
        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: CanvasTypography.font("mono", "s", scale: 9.5 / 12.0),
            .foregroundColor: theme == .dark ? CanvasTheme.darkPrimaryText : CanvasTheme.secondaryText,
        ]
        let textSize = badgeText.size(withAttributes: badgeAttrs)
        let badgeRect = NSRect(
            x: bounds.width - textSize.width - 18,
            y: bounds.height - textSize.height - 10,
            width: textSize.width + 10,
            height: textSize.height + 4
        )
        let badgeBg = (theme == .dark ? CanvasTheme.darkElevatedSurface : CanvasTheme.elevatedSurface)
            .withAlphaComponent(0.92)
        badgeBg.setFill()
        badgeRect.fill()
        let badgeBorder = NSBezierPath(rect: badgeRect.insetBy(dx: 0.5, dy: 0.5))
        badgeBorder.lineWidth = 1
        (theme == .dark ? CanvasTheme.darkBorderStrong : CanvasTheme.borderSubtle).setStroke()
        badgeBorder.stroke()
        badgeText.draw(at: NSPoint(x: badgeRect.minX + 5, y: badgeRect.minY + 2), withAttributes: badgeAttrs)

        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        (theme == .dark ? CanvasTheme.darkBorderStrong : CanvasTheme.borderStrong).setStroke()
        border.stroke()
    }
}

@MainActor
final class PNGExportSheet: NSObject, NSTextFieldDelegate {
    private final class SubmitTextField: NSTextField {
        var onSubmit: (() -> Void)?
        var onCancel: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            if let editor = currentEditor() as? NSTextView, !editor.hasMarkedText() {
                if event.keyCode == 36 || event.keyCode == 76 {
                    onSubmit?()
                    return
                }
                if event.keyCode == 53 {
                    onCancel?()
                    return
                }
            }
            super.keyDown(with: event)
        }
    }

    private struct PreviewKey: Hashable {
        let theme: CanvasPNGExportTheme
        let scope: CanvasPNGExportScope
    }

    let panel: NSPanel
    private let fullContentWorldBounds: CGRect
    private let selectionContentWorldBounds: CGRect?
    private let selectionSummaryTitle: String
    private let defaultFilename: String
    private let previewView = PNGExportPreviewView()
    private let scopePopup = NSPopUpButton()
    private let themePopup = NSPopUpButton()
    private let modePopup = NSPopUpButton()
    private let longestLabel = NSTextField(labelWithString: "Longest side (px)")
    private let longestField = SubmitTextField()
    private let widthLabel = NSTextField(labelWithString: "Width (px)")
    private let widthField = SubmitTextField()
    private let heightLabel = NSTextField(labelWithString: "Height (px)")
    private let heightField = SubmitTextField()
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let renderPreview: (CanvasPNGExportTheme, CanvasPNGExportScope) -> NSImage?
    private let chooseDestination: (String) -> URL?
    private let performExport: (CanvasPNGExportSizing, CanvasPNGExportTheme, CanvasPNGExportScope, URL) throws -> Void
    private let completion: () -> Void
    private var previewCache: [PreviewKey: NSImage] = [:]
    private var lastAutoExactSize: (width: Int, height: Int)

    init(
        fullContentWorldBounds: CGRect,
        selectionContentWorldBounds: CGRect? = nil,
        selectionSummaryTitle: String? = nil,
        defaultFilename: String = "canvas.png",
        initialTheme: CanvasPNGExportTheme = .light,
        renderPreview: @escaping (CanvasPNGExportTheme, CanvasPNGExportScope) -> NSImage?,
        chooseDestination: @escaping (String) -> URL?,
        performExport: @escaping (CanvasPNGExportSizing, CanvasPNGExportTheme, CanvasPNGExportScope, URL) throws -> Void,
        completion: @escaping () -> Void
    ) {
        self.fullContentWorldBounds = fullContentWorldBounds
        self.selectionContentWorldBounds = selectionContentWorldBounds
        self.selectionSummaryTitle = selectionSummaryTitle ?? "Selected items"
        self.defaultFilename = defaultFilename
        self.renderPreview = renderPreview
        self.chooseDestination = chooseDestination
        self.performExport = performExport
        self.completion = completion
        let hasSelection = selectionContentWorldBounds != nil
        let scopeRowOffset: CGFloat = hasSelection ? 40 : 0
        let initialBounds = selectionContentWorldBounds ?? fullContentWorldBounds
        let defaultPlan = try? CanvasPNGExportPlan.resolve(
            contentWorldBounds: initialBounds,
            sizing: .longestSide(CanvasPNGExportSizing.defaultLongestSide)
        )
        let initialWidth = defaultPlan?.pixelWidth ?? CanvasPNGExportSizing.defaultLongestSide
        let initialHeight = defaultPlan?.pixelHeight ?? CanvasPNGExportSizing.defaultLongestSide
        self.lastAutoExactSize = (initialWidth, initialHeight)
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 500 + scopeRowOffset),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        panel.title = "Export Transparent PNG"
        super.init()

        let titleField = NSTextField(labelWithString: "Export PNG for Keynote")
        titleField.font = .systemFont(ofSize: 15, weight: .bold)
        titleField.frame = NSRect(x: 24, y: 456 + scopeRowOffset, width: 472, height: 22)
        panel.contentView?.addSubview(titleField)

        previewView.frame = NSRect(x: 24, y: 290 + scopeRowOffset, width: 472, height: 152)
        previewView.identifier = NSUserInterfaceItemIdentifier("export-png-preview")
        previewView.setAccessibilityLabel("Slide export preview")
        panel.contentView?.addSubview(previewView)

        if hasSelection {
            let scopeLabel = NSTextField(labelWithString: "Export scope")
            scopeLabel.frame = NSRect(x: 24, y: 291, width: 132, height: 22)
            scopePopup.frame = NSRect(x: 164, y: 286, width: 332, height: 32)
            scopePopup.identifier = NSUserInterfaceItemIdentifier("export-png-scope")
            scopePopup.setAccessibilityLabel("Export scope")
            scopePopup.addItems(withTitles: [
                self.selectionSummaryTitle,
                "Entire canvas",
            ])
            scopePopup.selectItem(at: 0)
            scopePopup.target = self
            scopePopup.action = #selector(scopeChanged)
            panel.contentView?.addSubview(scopeLabel)
            panel.contentView?.addSubview(scopePopup)
        }

        let themeLabel = NSTextField(labelWithString: "Slide theme")
        themeLabel.frame = NSRect(x: 24, y: 251, width: 132, height: 22)
        themePopup.frame = NSRect(x: 164, y: 246, width: 332, height: 32)
        themePopup.identifier = NSUserInterfaceItemIdentifier("export-png-theme")
        themePopup.setAccessibilityLabel("Slide theme")
        for theme in CanvasPNGExportTheme.allCases {
            themePopup.addItem(withTitle: theme.displayTitle)
        }
        themePopup.selectItem(at: initialTheme == .dark ? 1 : 0)
        themePopup.target = self
        themePopup.action = #selector(themeChanged)
        panel.contentView?.addSubview(themeLabel)
        panel.contentView?.addSubview(themePopup)

        let modeLabel = NSTextField(labelWithString: "Sizing mode")
        modeLabel.frame = NSRect(x: 24, y: 211, width: 132, height: 22)
        modePopup.frame = NSRect(x: 164, y: 206, width: 332, height: 32)
        modePopup.identifier = NSUserInterfaceItemIdentifier("export-png-mode")
        modePopup.setAccessibilityLabel("Sizing mode")
        modePopup.addItems(withTitles: [
            "Longest side (proportional)",
            "Exact dimensions (letterboxed)",
        ])
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        panel.contentView?.addSubview(modeLabel)
        panel.contentView?.addSubview(modePopup)

        longestLabel.frame = NSRect(x: 24, y: 169, width: 132, height: 22)
        configureField(
            longestField,
            id: "export-png-longest",
            label: "Longest side in pixels",
            value: "\(CanvasPNGExportSizing.defaultLongestSide)",
            frame: NSRect(x: 164, y: 166, width: 140, height: 28)
        )
        panel.contentView?.addSubview(longestLabel)
        panel.contentView?.addSubview(longestField)

        widthLabel.frame = NSRect(x: 24, y: 169, width: 132, height: 22)
        configureField(
            widthField,
            id: "export-png-width",
            label: "Width in pixels",
            value: "\(initialWidth)",
            frame: NSRect(x: 164, y: 166, width: 120, height: 28)
        )
        heightLabel.frame = NSRect(x: 300, y: 169, width: 76, height: 22)
        configureField(
            heightField,
            id: "export-png-height",
            label: "Height in pixels",
            value: "\(initialHeight)",
            frame: NSRect(x: 376, y: 166, width: 120, height: 28)
        )
        panel.contentView?.addSubview(widthLabel)
        panel.contentView?.addSubview(widthField)
        panel.contentView?.addSubview(heightLabel)
        panel.contentView?.addSubview(heightField)

        summaryLabel.identifier = NSUserInterfaceItemIdentifier("export-png-summary")
        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.frame = NSRect(x: 24, y: 112, width: 472, height: 44)
        panel.contentView?.addSubview(summaryLabel)

        errorLabel.identifier = NSUserInterfaceItemIdentifier("export-png-error")
        errorLabel.font = .systemFont(ofSize: 12)
        errorLabel.textColor = .systemRed
        errorLabel.frame = NSRect(x: 24, y: 62, width: 472, height: 44)
        errorLabel.isHidden = true
        panel.contentView?.addSubview(errorLabel)

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancelExport))
        cancelBtn.identifier = NSUserInterfaceItemIdentifier("export-png-cancel")
        cancelBtn.frame = NSRect(x: 264, y: 20, width: 92, height: 32)
        cancelBtn.keyEquivalent = "\u{1b}"

        let exportBtn = NSButton(title: "Export PNG…", target: self, action: #selector(confirmExport))
        exportBtn.identifier = NSUserInterfaceItemIdentifier("export-png-confirm")
        exportBtn.frame = NSRect(x: 364, y: 20, width: 132, height: 32)
        exportBtn.keyEquivalent = "\r"

        panel.contentView?.addSubview(cancelBtn)
        panel.contentView?.addSubview(exportBtn)

        updateModeVisibility()
        refreshPreview()
        refreshSummary()
    }

    var selectedTheme: CanvasPNGExportTheme {
        themePopup.indexOfSelectedItem == 1 ? .dark : .light
    }

    var selectedScope: CanvasPNGExportScope {
        selectionContentWorldBounds != nil && scopePopup.indexOfSelectedItem == 0
            ? .selection
            : .entireCanvas
    }

    private var activeContentWorldBounds: CGRect {
        if selectedScope == .selection, let selectionBounds = selectionContentWorldBounds {
            return selectionBounds
        }
        return fullContentWorldBounds
    }

    private func configureField(
        _ field: SubmitTextField, id: String, label: String, value: String, frame: NSRect
    ) {
        field.frame = frame
        field.identifier = NSUserInterfaceItemIdentifier(id)
        field.setAccessibilityLabel(label)
        field.stringValue = value
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.delegate = self
        field.onSubmit = { [weak self] in self?.confirmExport() }
        field.onCancel = { [weak self] in self?.cancelExport() }
    }

    func present(on window: NSWindow) {
        window.beginSheet(panel)
        panel.makeFirstResponder(modePopup.indexOfSelectedItem == 0 ? longestField : widthField)
    }

    func controlTextDidChange(_ obj: Notification) {
        errorLabel.isHidden = true
        refreshSummary()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            confirmExport()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelExport()
            return true
        }
        return false
    }

    @objc private func scopeChanged() {
        errorLabel.isHidden = true
        if widthField.stringValue == "\(lastAutoExactSize.width)" &&
            heightField.stringValue == "\(lastAutoExactSize.height)",
           let updatedPlan = try? CanvasPNGExportPlan.resolve(
               contentWorldBounds: activeContentWorldBounds,
               sizing: .longestSide(CanvasPNGExportSizing.defaultLongestSide)
           ) {
            widthField.stringValue = "\(updatedPlan.pixelWidth)"
            heightField.stringValue = "\(updatedPlan.pixelHeight)"
            lastAutoExactSize = (updatedPlan.pixelWidth, updatedPlan.pixelHeight)
        }
        refreshPreview()
        refreshSummary()
    }

    @objc private func themeChanged() {
        errorLabel.isHidden = true
        refreshPreview()
        refreshSummary()
    }

    @objc private func modeChanged() {
        errorLabel.isHidden = true
        updateModeVisibility()
        refreshSummary()
        panel.makeFirstResponder(modePopup.indexOfSelectedItem == 0 ? longestField : widthField)
    }

    private func updateModeVisibility() {
        let isLongest = modePopup.indexOfSelectedItem == 0
        longestLabel.isHidden = !isLongest
        longestField.isHidden = !isLongest
        widthLabel.isHidden = isLongest
        widthField.isHidden = isLongest
        heightLabel.isHidden = isLongest
        heightField.isHidden = isLongest
    }

    private func refreshPreview() {
        let theme = selectedTheme
        let scope = selectedScope
        let key = PreviewKey(theme: theme, scope: scope)
        if previewCache[key] == nil, let rendered = renderPreview(theme, scope) {
            previewCache[key] = rendered
        }
        previewView.theme = theme
        previewView.previewImage = previewCache[key]
    }

    private func parsePositiveInt(_ raw: String, fieldName: String) throws -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let value = Int(trimmed) else {
            throw CanvasDocumentError("Enter a whole pixel number for \(fieldName).")
        }
        return value
    }

    private func parsedSizing() throws -> CanvasPNGExportSizing {
        if modePopup.indexOfSelectedItem == 0 {
            let longest = try parsePositiveInt(longestField.stringValue, fieldName: "longest side")
            return .longestSide(longest)
        } else {
            let width = try parsePositiveInt(widthField.stringValue, fieldName: "width")
            let height = try parsePositiveInt(heightField.stringValue, fieldName: "height")
            return .exact(width: width, height: height)
        }
    }

    private func refreshSummary() {
        let themeNote = selectedTheme.summaryNote
        let scopePrefix = selectedScope == .selection ? "\(selectionSummaryTitle) · " : ""
        do {
            let sizing = try parsedSizing()
            let plan = try CanvasPNGExportPlan.resolve(
                contentWorldBounds: activeContentWorldBounds,
                sizing: sizing
            )
            let fitNote = modePopup.indexOfSelectedItem == 0
                ? "Proportional aspect ratio"
                : "Proportional fit with transparent letterboxing"
            summaryLabel.stringValue =
                "Output: \(plan.pixelWidth) × \(plan.pixelHeight) px · \(scopePrefix)\(fitNote)\nTransparent sRGB alpha · \(themeNote) · 32 world-unit padding · Max 8,192 px/side"
        } catch {
            summaryLabel.stringValue =
                "\(scopePrefix)Transparent sRGB alpha · \(themeNote) · 32 world-unit padding · Max 8,192 px/side"
        }
    }

    @objc func confirmExport() {
        for field in [longestField, widthField, heightField] {
            if let editor = panel.fieldEditor(false, for: field) as? NSTextView,
               editor.hasMarkedText() {
                return
            }
        }
        do {
            let sizing = try parsedSizing()
            let scope = selectedScope
            _ = try CanvasPNGExportPlan.resolve(
                contentWorldBounds: activeContentWorldBounds,
                sizing: sizing
            )
            guard let destinationURL = chooseDestination(defaultFilename) else {
                // Destination dialog cancelled; keep session and sheet state intact.
                return
            }
            try performExport(sizing, selectedTheme, scope, destinationURL)
            dismiss()
        } catch {
            errorLabel.stringValue = error.localizedDescription
            errorLabel.isHidden = false
            panel.makeFirstResponder(modePopup.indexOfSelectedItem == 0 ? longestField : widthField)
        }
    }

    @objc func cancelExport() {
        dismiss()
    }

    private func dismiss() {
        let parent = panel.sheetParent
        parent?.endSheet(panel)
        panel.orderOut(nil)
        parent?.makeKeyAndOrderFront(nil)
        completion()
    }
}
