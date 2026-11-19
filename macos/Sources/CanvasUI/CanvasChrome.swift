import AppKit
import CanvasCore

public enum CanvasCreationTool: Equatable, Sendable {
    case select
    case shape(CanvasShapeKind)
    case line(CanvasLineKind)

    public var identifier: String {
        switch self {
        case .select: return "dock-tool-select"
        case .shape(.rectangle): return "dock-tool-rect"
        case .shape(.ellipse): return "dock-tool-ellipse"
        case .shape(.diamond): return "dock-tool-diamond"
        case .shape(.triangle): return "dock-tool-triangle"
        case .shape(.text): return "dock-tool-text"
        case .line(.line): return "dock-tool-line"
        case .line(.arrow): return "dock-tool-arrow"
        }
    }

    public var title: String {
        switch self {
        case .select: return "Select"
        case .shape(.rectangle): return "Rect"
        case .shape(.ellipse): return "Ellipse"
        case .shape(.diamond): return "Diamond"
        case .shape(.triangle): return "Triangle"
        case .shape(.text): return "Text"
        case .line(.line): return "Line"
        case .line(.arrow): return "Arrow"
        }
    }

    public var shortcutHint: String {
        switch self {
        case .select: return "V"
        case .shape(.rectangle): return "R"
        case .shape(.ellipse): return "O"
        case .shape(.diamond): return "D"
        case .shape(.triangle): return "I"
        case .shape(.text): return "T"
        case .line(.line): return "L"
        case .line(.arrow): return "A"
        }
    }

    public var helpBannerText: String {
        switch self {
        case .select:
            return ""
        case .shape(.text):
            return "Text tool armed · Click on canvas to type · Return: place at center · V / Escape: Select"
        case .shape(let kind):
            let label = kind == .rectangle ? "Rectangle" : kind.rawValue.capitalized
            return "\(label) tool armed · Click or drag on canvas to place · Return: center · V / Escape: Select"
        case .line(let kind):
            let label = kind == .arrow ? "Arrow" : "Line"
            return "\(label) tool armed · Click or drag endpoints on canvas · Return: center · V / Escape: Select"
        }
    }

    public static let allTools: [CanvasCreationTool] = [
        .select,
        .shape(.rectangle),
        .shape(.ellipse),
        .shape(.diamond),
        .shape(.triangle),
        .shape(.text),
        .line(.line),
        .line(.arrow),
    ]
}

public enum CanvasDockIconGlyph: String, Equatable, Sendable {
    case select
    case rectangle
    case ellipse
    case diamond
    case triangle
    case text
    case line
    case arrow
    case connect
    case thought
    case style
    case exportPNG
    case help
}

@MainActor
private final class NeoAcidDockButton: NSButton {
    var isActiveTool: Bool = false {
        didSet { needsDisplay = true }
    }
    var iconGlyph: CanvasDockIconGlyph? {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor
        if !isEnabled {
            fill = CanvasTheme.surface.withAlphaComponent(0.6)
        } else if isActiveTool {
            fill = CanvasTheme.acid
        } else if isHighlighted {
            fill = CanvasTheme.surface
        } else {
            fill = CanvasTheme.elevatedSurface
        }
        fill.setFill()
        bounds.fill()

        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = isActiveTool ? 1.5 : 1.0
        (isActiveTool ? CanvasTheme.borderStrong : CanvasTheme.borderSubtle).setStroke()
        border.stroke()

        let strokeColor = isEnabled ? CanvasTheme.highlighterInk : CanvasTheme.mutedText
        if let glyph = iconGlyph {
            drawIconGlyph(glyph, in: bounds, color: strokeColor)
            return
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: CanvasTypography.font("sans", "s", scale: 11.5 / 14.0),
            .foregroundColor: strokeColor,
            .paragraphStyle: paragraph,
        ]
        let text = title as NSString
        let size = text.size(withAttributes: attrs)
        let rect = CGRect(
            x: 2,
            y: floor((bounds.height - size.height) / 2),
            width: bounds.width - 4,
            height: size.height + 2
        )
        text.draw(in: rect, withAttributes: attrs)
    }

    private func drawIconGlyph(_ glyph: CanvasDockIconGlyph, in rect: NSRect, color: NSColor) {
        let cx = rect.midX
        let cy = rect.midY
        color.setStroke()
        color.setFill()

        switch glyph {
        case .select:
            let path = NSBezierPath()
            path.move(to: CGPoint(x: cx - 5, y: cy - 8))
            path.line(to: CGPoint(x: cx - 5, y: cy + 7))
            path.line(to: CGPoint(x: cx - 1, y: cy + 3.5))
            path.line(to: CGPoint(x: cx + 2.5, y: cy + 9))
            path.line(to: CGPoint(x: cx + 4.5, y: cy + 7.8))
            path.line(to: CGPoint(x: cx + 1, y: cy + 2.2))
            path.line(to: CGPoint(x: cx + 6, y: cy + 2.2))
            path.close()
            path.fill()

        case .rectangle:
            let path = NSBezierPath(rect: CGRect(x: cx - 8, y: cy - 6, width: 16, height: 12))
            path.lineWidth = 1.8
            path.stroke()

        case .ellipse:
            let path = NSBezierPath(ovalIn: CGRect(x: cx - 8, y: cy - 6, width: 16, height: 12))
            path.lineWidth = 1.8
            path.stroke()

        case .diamond:
            let path = NSBezierPath()
            path.move(to: CGPoint(x: cx, y: cy - 8))
            path.line(to: CGPoint(x: cx + 8, y: cy))
            path.line(to: CGPoint(x: cx, y: cy + 8))
            path.line(to: CGPoint(x: cx - 8, y: cy))
            path.close()
            path.lineWidth = 1.8
            path.stroke()

        case .triangle:
            let path = NSBezierPath()
            path.move(to: CGPoint(x: cx, y: cy - 7.5))
            path.line(to: CGPoint(x: cx + 8.5, y: cy + 7.5))
            path.line(to: CGPoint(x: cx - 8.5, y: cy + 7.5))
            path.close()
            path.lineWidth = 1.8
            path.stroke()

        case .text:
            let path = NSBezierPath()
            path.move(to: CGPoint(x: cx - 6.5, y: cy - 6.5))
            path.line(to: CGPoint(x: cx + 6.5, y: cy - 6.5))
            path.move(to: CGPoint(x: cx - 6.5, y: cy - 6.5))
            path.line(to: CGPoint(x: cx - 6.5, y: cy - 4))
            path.move(to: CGPoint(x: cx + 6.5, y: cy - 6.5))
            path.line(to: CGPoint(x: cx + 6.5, y: cy - 4))
            path.move(to: CGPoint(x: cx, y: cy - 6.5))
            path.line(to: CGPoint(x: cx, y: cy + 7))
            path.move(to: CGPoint(x: cx - 3, y: cy + 7))
            path.line(to: CGPoint(x: cx + 3, y: cy + 7))
            path.lineWidth = 1.8
            path.stroke()

        case .line:
            let path = NSBezierPath()
            path.move(to: CGPoint(x: cx - 6.5, y: cy + 6.5))
            path.line(to: CGPoint(x: cx + 6.5, y: cy - 6.5))
            path.lineWidth = 1.8
            path.stroke()
            NSBezierPath(ovalIn: CGRect(x: cx - 8.5, y: cy + 4.5, width: 4, height: 4)).fill()
            NSBezierPath(ovalIn: CGRect(x: cx + 4.5, y: cy - 8.5, width: 4, height: 4)).fill()

        case .arrow:
            let path = NSBezierPath()
            path.move(to: CGPoint(x: cx - 7, y: cy + 7))
            path.line(to: CGPoint(x: cx + 6.5, y: cy - 6.5))
            path.move(to: CGPoint(x: cx + 0.5, y: cy - 6.5))
            path.line(to: CGPoint(x: cx + 6.5, y: cy - 6.5))
            path.line(to: CGPoint(x: cx + 6.5, y: cy - 0.5))
            path.lineWidth = 1.8
            path.stroke()

        case .connect:
            let n1 = NSBezierPath(rect: CGRect(x: cx - 8, y: cy - 7, width: 6, height: 6))
            let n2 = NSBezierPath(rect: CGRect(x: cx + 2, y: cy + 1, width: 6, height: 6))
            n1.lineWidth = 1.6
            n2.lineWidth = 1.6
            n1.stroke()
            n2.stroke()
            let route = NSBezierPath()
            route.move(to: CGPoint(x: cx - 2, y: cy - 4))
            route.line(to: CGPoint(x: cx + 5, y: cy - 4))
            route.line(to: CGPoint(x: cx + 5, y: cy + 1))
            route.lineWidth = 1.6
            route.stroke()

        case .thought:
            let box = NSBezierPath(rect: CGRect(x: cx - 8, y: cy - 5, width: 10, height: 10))
            box.lineWidth = 1.6
            box.stroke()
            let plus = NSBezierPath()
            plus.move(to: CGPoint(x: cx + 5.5, y: cy - 3.5))
            plus.line(to: CGPoint(x: cx + 5.5, y: cy + 3.5))
            plus.move(to: CGPoint(x: cx + 2, y: cy))
            plus.line(to: CGPoint(x: cx + 9, y: cy))
            plus.lineWidth = 1.8
            plus.stroke()

        case .style:
            let path = NSBezierPath()
            path.move(to: CGPoint(x: cx - 8, y: cy - 4))
            path.line(to: CGPoint(x: cx + 8, y: cy - 4))
            path.move(to: CGPoint(x: cx - 8, y: cy + 4))
            path.line(to: CGPoint(x: cx + 8, y: cy + 4))
            path.lineWidth = 1.6
            path.stroke()
            NSBezierPath(ovalIn: CGRect(x: cx - 4, y: cy - 6.5, width: 5, height: 5)).fill()
            NSBezierPath(ovalIn: CGRect(x: cx + 1, y: cy + 1.5, width: 5, height: 5)).fill()

        case .exportPNG:
            let tray = NSBezierPath()
            tray.move(to: CGPoint(x: cx - 7, y: cy + 1))
            tray.line(to: CGPoint(x: cx - 7, y: cy + 7))
            tray.line(to: CGPoint(x: cx + 7, y: cy + 7))
            tray.line(to: CGPoint(x: cx + 7, y: cy + 1))
            tray.move(to: CGPoint(x: cx, y: cy + 3))
            tray.line(to: CGPoint(x: cx, y: cy - 7))
            tray.move(to: CGPoint(x: cx - 4, y: cy - 3))
            tray.line(to: CGPoint(x: cx, y: cy - 7))
            tray.line(to: CGPoint(x: cx + 4, y: cy - 3))
            tray.lineWidth = 1.8
            tray.stroke()

        case .help:
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: CanvasTypography.font("mono", "m", scale: 14.0 / 16.0),
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
            let q = "?" as NSString
            let size = q.size(withAttributes: attrs)
            q.draw(
                in: CGRect(x: rect.minX, y: floor((rect.height - size.height) / 2), width: rect.width, height: size.height + 2),
                withAttributes: attrs
            )
        }
    }
}

@MainActor
public final class CanvasToolDockView: NSView {
    public var onSelectTool: ((CanvasCreationTool) -> Void)?
    public var onConnect: (() -> Void)?
    public var onAdjacentThought: (() -> Void)?
    public var onToggleStyle: (() -> Void)?
    public var onExportPNG: (() -> Void)?
    public var onShowShortcuts: (() -> Void)?

    private var toolButtons: [String: NeoAcidDockButton] = [:]
    private let connectButton = NeoAcidDockButton(frame: .zero)
    private let thoughtButton = NeoAcidDockButton(frame: .zero)
    private let styleButton = NeoAcidDockButton(frame: .zero)
    private let exportButton = NeoAcidDockButton(frame: .zero)
    private let helpButton = NeoAcidDockButton(frame: .zero)
    private var dividerX: CGFloat = 0

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("canvas-tool-dock")
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Canvas tools")
        buildControls()
    }

    public required init?(coder: NSCoder) {
        fatalError("CanvasToolDockView does not support NSCoder")
    }

    public func iconGlyph(forButtonID id: String) -> CanvasDockIconGlyph? {
        if let btn = subviews.first(where: { $0.identifier?.rawValue == id }) as? NeoAcidDockButton {
            return btn.iconGlyph
        }
        return nil
    }

    private func glyph(for tool: CanvasCreationTool) -> CanvasDockIconGlyph {
        switch tool {
        case .select: return .select
        case .shape(.rectangle): return .rectangle
        case .shape(.ellipse): return .ellipse
        case .shape(.diamond): return .diamond
        case .shape(.triangle): return .triangle
        case .shape(.text): return .text
        case .line(.line): return .line
        case .line(.arrow): return .arrow
        }
    }

    private func buildControls() {
        var x: CGFloat = 6
        let y: CGFloat = 6
        let buttonSize: CGFloat = 34

        for tool in CanvasCreationTool.allTools {
            let tip = "\(tool.title) (\(tool.shortcutHint))"
            let button = makeIconButton(
                id: tool.identifier,
                glyph: glyph(for: tool),
                tooltip: tip,
                accessibilityLabel: "\(tool.title) tool (\(tool.shortcutHint))",
                frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize),
                action: #selector(handleToolButton(_:))
            )
            toolButtons[tool.identifier] = button
            addSubview(button)
            x += buttonSize + 4
        }

        dividerX = x + 2
        x += 8

        configureIconActionButton(
            connectButton,
            id: "dock-action-connect",
            glyph: .connect,
            tooltip: "Connect Objects (C)",
            accessibilityLabel: "Create or edit connection (C)",
            x: &x,
            y: y,
            size: buttonSize,
            action: #selector(handleConnect(_:))
        )
        configureIconActionButton(
            thoughtButton,
            id: "dock-action-thought",
            glyph: .thought,
            tooltip: "Adjacent Thought (N)",
            accessibilityLabel: "Adjacent thought (N)",
            x: &x,
            y: y,
            size: buttonSize,
            action: #selector(handleThought(_:))
        )
        configureIconActionButton(
            styleButton,
            id: "dock-action-style",
            glyph: .style,
            tooltip: "Style Inspector (S)",
            accessibilityLabel: "Style inspector (S)",
            x: &x,
            y: y,
            size: buttonSize,
            action: #selector(handleStyle(_:))
        )
        configureIconActionButton(
            exportButton,
            id: "dock-action-export",
            glyph: .exportPNG,
            tooltip: "Export Transparent PNG (⇧⌘E)",
            accessibilityLabel: "Export PNG (Shift-Command-E)",
            x: &x,
            y: y,
            size: buttonSize,
            action: #selector(handleExport(_:))
        )
        configureIconActionButton(
            helpButton,
            id: "dock-action-help",
            glyph: .help,
            tooltip: "Keyboard & Pointer Shortcuts (?)",
            accessibilityLabel: "Keyboard shortcuts reference (?)",
            x: &x,
            y: y,
            size: buttonSize,
            action: #selector(handleHelp(_:))
        )

        setFrameSize(NSSize(width: x + 2, height: 46))
    }

    private func makeIconButton(
        id: String,
        glyph: CanvasDockIconGlyph,
        tooltip: String,
        accessibilityLabel: String,
        frame: NSRect,
        action: Selector
    ) -> NeoAcidDockButton {
        let button = NeoAcidDockButton(frame: frame)
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.title = tooltip
        button.toolTip = tooltip
        button.iconGlyph = glyph
        button.target = self
        button.action = action
        button.isBordered = false
        button.setAccessibilityLabel(accessibilityLabel)
        return button
    }

    private func configureIconActionButton(
        _ button: NeoAcidDockButton,
        id: String,
        glyph: CanvasDockIconGlyph,
        tooltip: String,
        accessibilityLabel: String,
        x: inout CGFloat,
        y: CGFloat,
        size: CGFloat,
        action: Selector
    ) {
        button.frame = NSRect(x: x, y: y, width: size, height: size)
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.title = tooltip
        button.toolTip = tooltip
        button.iconGlyph = glyph
        button.target = self
        button.action = action
        button.isBordered = false
        button.setAccessibilityLabel(accessibilityLabel)
        addSubview(button)
        x += size + 4
    }

    public func update(
        activeTool: CanvasCreationTool,
        isReadOnly: Bool,
        canConnect: Bool,
        canInsertThought: Bool,
        isStyleOpen: Bool,
        canExport: Bool
    ) {
        for tool in CanvasCreationTool.allTools {
            guard let button = toolButtons[tool.identifier] else { continue }
            button.isActiveTool = (tool == activeTool)
            button.isEnabled = (tool == .select) ? true : !isReadOnly
        }
        connectButton.isEnabled = !isReadOnly && canConnect
        thoughtButton.isEnabled = !isReadOnly && canInsertThought
        styleButton.isActiveTool = isStyleOpen
        styleButton.isEnabled = true
        exportButton.isEnabled = canExport
        helpButton.isEnabled = true
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        CanvasTheme.surface.setFill()
        bounds.fill()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        CanvasTheme.borderStrong.setStroke()
        border.stroke()
        if dividerX > 0 {
            let div = NSBezierPath()
            div.move(to: CGPoint(x: dividerX, y: 8))
            div.line(to: CGPoint(x: dividerX, y: bounds.height - 8))
            div.lineWidth = 1.5
            CanvasTheme.borderSubtle.setStroke()
            div.stroke()
        }
    }

    @objc private func handleToolButton(_ sender: NSButton) {
        guard let rawID = sender.identifier?.rawValue,
              let tool = CanvasCreationTool.allTools.first(where: { $0.identifier == rawID }) else { return }
        onSelectTool?(tool)
    }

    @objc private func handleConnect(_ sender: Any?) {
        onConnect?()
    }

    @objc private func handleThought(_ sender: Any?) {
        onAdjacentThought?()
    }

    @objc private func handleStyle(_ sender: Any?) {
        onToggleStyle?()
    }

    @objc private func handleExport(_ sender: Any?) {
        onExportPNG?()
    }

    @objc private func handleHelp(_ sender: Any?) {
        onShowShortcuts?()
    }
}

extension CanvasAlignment {
    public var shortcutHint: String {
        switch self {
        case .left: return "⌥⌘←"
        case .centerHorizontal: return "⌃⌘H"
        case .right: return "⌥⌘→"
        case .top: return "⌥⌘↑"
        case .centerVertical: return "⌃⌘V"
        case .bottom: return "⌥⌘↓"
        case .distributeHorizontally: return "⇧⌃⌘H"
        case .distributeVertically: return "⇧⌃⌘V"
        }
    }

    public var tooltipText: String {
        "\(actionName) (\(shortcutHint))"
    }
}

@MainActor
final class NeoAcidAlignButton: NSButton {
    let alignmentKind: CanvasAlignment
    var onEscape: (() -> Void)?

    override var isFlipped: Bool { true }

    init(alignment: CanvasAlignment, frame: NSRect) {
        self.alignmentKind = alignment
        super.init(frame: frame)
        title = alignment.actionName
        toolTip = alignment.tooltipText
        isBordered = false
        setAccessibilityLabel(alignment.tooltipText)
    }

    required init?(coder: NSCoder) {
        fatalError("NeoAcidAlignButton does not support NSCoder")
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, let onEscape {
            onEscape()
            return
        }
        if event.modifierFlags.contains(.command) {
            superview?.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor
        if !isEnabled {
            fill = CanvasTheme.surface.withAlphaComponent(0.6)
        } else if isHighlighted {
            fill = CanvasTheme.acid
        } else {
            fill = CanvasTheme.elevatedSurface
        }
        fill.setFill()
        bounds.fill()

        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = isHighlighted ? 1.5 : 1.0
        (isHighlighted ? CanvasTheme.borderStrong : CanvasTheme.borderSubtle).setStroke()
        border.stroke()

        let color = isEnabled ? CanvasTheme.highlighterInk : CanvasTheme.mutedText
        Self.drawGlyph(alignmentKind, in: bounds, color: color)
    }

    static func drawGlyph(_ alignment: CanvasAlignment, in rect: NSRect, color: NSColor) {
        let cx = rect.midX
        let cy = rect.midY
        color.setStroke()
        color.setFill()

        let guide = NSBezierPath()
        guide.lineWidth = 1.8

        switch alignment {
        case .left:
            guide.move(to: CGPoint(x: cx - 7, y: cy - 7))
            guide.line(to: CGPoint(x: cx - 7, y: cy + 7))
            guide.stroke()
            NSBezierPath(rect: CGRect(x: cx - 4.5, y: cy - 5, width: 11, height: 3.6)).fill()
            NSBezierPath(rect: CGRect(x: cx - 4.5, y: cy + 1.4, width: 7.5, height: 3.6)).fill()

        case .centerHorizontal:
            guide.lineWidth = 1.6
            guide.move(to: CGPoint(x: cx, y: cy - 7.5))
            guide.line(to: CGPoint(x: cx, y: cy + 7.5))
            guide.stroke()
            NSBezierPath(rect: CGRect(x: cx - 6.5, y: cy - 5, width: 13, height: 3.6)).fill()
            NSBezierPath(rect: CGRect(x: cx - 4, y: cy + 1.4, width: 8, height: 3.6)).fill()

        case .right:
            guide.move(to: CGPoint(x: cx + 7, y: cy - 7))
            guide.line(to: CGPoint(x: cx + 7, y: cy + 7))
            guide.stroke()
            NSBezierPath(rect: CGRect(x: cx - 6.5, y: cy - 5, width: 11, height: 3.6)).fill()
            NSBezierPath(rect: CGRect(x: cx - 3, y: cy + 1.4, width: 7.5, height: 3.6)).fill()

        case .top:
            guide.move(to: CGPoint(x: cx - 7, y: cy - 7))
            guide.line(to: CGPoint(x: cx + 7, y: cy - 7))
            guide.stroke()
            NSBezierPath(rect: CGRect(x: cx - 5, y: cy - 4.5, width: 3.6, height: 11)).fill()
            NSBezierPath(rect: CGRect(x: cx + 1.4, y: cy - 4.5, width: 3.6, height: 7.5)).fill()

        case .centerVertical:
            guide.lineWidth = 1.6
            guide.move(to: CGPoint(x: cx - 7.5, y: cy))
            guide.line(to: CGPoint(x: cx + 7.5, y: cy))
            guide.stroke()
            NSBezierPath(rect: CGRect(x: cx - 5, y: cy - 6.5, width: 3.6, height: 13)).fill()
            NSBezierPath(rect: CGRect(x: cx + 1.4, y: cy - 4, width: 3.6, height: 8)).fill()

        case .bottom:
            guide.move(to: CGPoint(x: cx - 7, y: cy + 7))
            guide.line(to: CGPoint(x: cx + 7, y: cy + 7))
            guide.stroke()
            NSBezierPath(rect: CGRect(x: cx - 5, y: cy - 6.5, width: 3.6, height: 11)).fill()
            NSBezierPath(rect: CGRect(x: cx + 1.4, y: cy - 3, width: 3.6, height: 7.5)).fill()

        case .distributeHorizontally:
            guide.move(to: CGPoint(x: cx - 7, y: cy - 7))
            guide.line(to: CGPoint(x: cx - 7, y: cy + 7))
            guide.move(to: CGPoint(x: cx + 7, y: cy - 7))
            guide.line(to: CGPoint(x: cx + 7, y: cy + 7))
            guide.stroke()
            NSBezierPath(rect: CGRect(x: cx - 2.2, y: cy - 5, width: 4.4, height: 10)).fill()

        case .distributeVertically:
            guide.move(to: CGPoint(x: cx - 7, y: cy - 7))
            guide.line(to: CGPoint(x: cx + 7, y: cy - 7))
            guide.move(to: CGPoint(x: cx - 7, y: cy + 7))
            guide.line(to: CGPoint(x: cx + 7, y: cy + 7))
            guide.stroke()
            NSBezierPath(rect: CGRect(x: cx - 5, y: cy - 2.2, width: 10, height: 4.4)).fill()
        }
    }
}

@MainActor
public final class CanvasAlignBarView: NSView {
    public var onAlign: ((CanvasAlignment) -> Void)?

    private var buttons: [CanvasAlignment: NeoAcidAlignButton] = [:]
    private var dividerXs: [CGFloat] = []

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("canvas-align-bar")
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Align selected items")
        buildControls()
    }

    public required init?(coder: NSCoder) {
        fatalError("CanvasAlignBarView does not support NSCoder")
    }

    public override func mouseDown(with event: NSEvent) {}
    public override func mouseDragged(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) {}

    public func button(for alignment: CanvasAlignment) -> NSButton? {
        buttons[alignment]
    }

    private func buildControls() {
        let groups: [[CanvasAlignment]] = [
            [.left, .centerHorizontal, .right],
            [.top, .centerVertical, .bottom],
            [.distributeHorizontally, .distributeVertically]
        ]
        var x: CGFloat = 6
        let y: CGFloat = 6
        let buttonSize: CGFloat = 30

        for (groupIdx, group) in groups.enumerated() {
            if groupIdx > 0 {
                dividerXs.append(x + 2)
                x += 8
            }
            for alignment in group {
                let button = NeoAcidAlignButton(
                    alignment: alignment,
                    frame: NSRect(x: x, y: y, width: buttonSize, height: buttonSize)
                )
                button.identifier = NSUserInterfaceItemIdentifier("align-bar-\(alignment.rawValue)")
                button.target = self
                button.action = #selector(handleAlignButton(_:))
                addSubview(button)
                buttons[alignment] = button
                x += buttonSize + 4
            }
        }
        setFrameSize(NSSize(width: x + 2, height: 42))
    }

    public func update(canAlign: Bool, canDistribute: Bool) {
        for alignment in CanvasAlignment.allCases {
            guard let button = buttons[alignment] else { continue }
            button.isEnabled = alignment.minimumSelectionCount >= 3 ? canDistribute : canAlign
        }
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        CanvasTheme.surface.setFill()
        bounds.fill()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        CanvasTheme.borderStrong.setStroke()
        border.stroke()
        for divX in dividerXs {
            let div = NSBezierPath()
            div.move(to: CGPoint(x: divX, y: 8))
            div.line(to: CGPoint(x: divX, y: bounds.height - 8))
            div.lineWidth = 1.5
            CanvasTheme.borderSubtle.setStroke()
            div.stroke()
        }
    }

    @objc private func handleAlignButton(_ sender: NSButton) {
        guard let alignBtn = sender as? NeoAcidAlignButton else { return }
        onAlign?(alignBtn.alignmentKind)
    }
}

@MainActor
public final class CanvasStatusBannerView: NSView {
    public enum BannerKind: Equatable {
        case conflict(CanvasConflictReason)
        case readOnly(String)
        case saveError(String, canRetry: Bool)
        case recoveryError(String)
    }

    public private(set) var activeKind: BannerKind?
    public var onSaveAs: (() -> Void)?
    public var onReloadFromDisk: (() -> Void)?
    public var onKeepEditing: (() -> Void)?
    public var onRetrySave: (() -> Void)?
    public var onDismiss: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let saveAsButton = NeoAcidDockButton(frame: .zero)
    private let reloadButton = NeoAcidDockButton(frame: .zero)
    private let retryButton = NeoAcidDockButton(frame: .zero)
    private let dismissButton = NeoAcidDockButton(frame: .zero)

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect = NSRect(x: 0, y: 0, width: 680, height: 54)) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("canvas-status-banner")
        setAccessibilityRole(.group)
        setAccessibilityLabel("Document status banner")
        isHidden = true

        titleLabel.identifier = NSUserInterfaceItemIdentifier("banner-title")
        titleLabel.font = CanvasTypography.font("mono", "s", scale: 11.0 / 14.0)
        titleLabel.textColor = CanvasTheme.highlighterInk
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        detailLabel.identifier = NSUserInterfaceItemIdentifier("banner-detail")
        detailLabel.font = CanvasTypography.font("sans", "s", scale: 12.0 / 14.0)
        detailLabel.textColor = CanvasTheme.highlighterInk
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(detailLabel)

        for (btn, id, title, action) in [
            (retryButton, "banner-retry-save", "Retry Save", #selector(handleRetry(_:))),
            (saveAsButton, "banner-save-as", "Save As…", #selector(handleSaveAs(_:))),
            (reloadButton, "banner-reload", "Reload from Disk…", #selector(handleReload(_:))),
            (dismissButton, "banner-keep-editing", "Keep Editing", #selector(handleDismiss(_:))),
        ] {
            btn.identifier = NSUserInterfaceItemIdentifier(id)
            btn.title = title
            btn.target = self
            btn.action = action
            btn.isBordered = false
            btn.setAccessibilityLabel(title)
            addSubview(btn)
        }
    }

    public required init?(coder: NSCoder) {
        fatalError("CanvasStatusBannerView does not support NSCoder")
    }

    public func configure(kind: BannerKind?) {
        activeKind = kind
        guard let kind else {
            isHidden = true
            needsDisplay = true
            return
        }
        isHidden = false
        retryButton.isHidden = true
        saveAsButton.isHidden = false
        reloadButton.isHidden = true
        dismissButton.isHidden = false

        switch kind {
        case .conflict(let reason):
            titleLabel.stringValue = "CONFLICT · AUTOSAVE PAUSED"
            detailLabel.stringValue = reason.message
            if case .modifiedExternally = reason {
                reloadButton.isHidden = false
            }
            dismissButton.title = "Keep Editing"
            dismissButton.identifier = NSUserInterfaceItemIdentifier("banner-keep-editing")
        case .readOnly(let reason):
            titleLabel.stringValue = "READ-ONLY DOCUMENT"
            detailLabel.stringValue = reason
            dismissButton.title = "Dismiss"
            dismissButton.identifier = NSUserInterfaceItemIdentifier("banner-dismiss")
        case .saveError(let message, let canRetry):
            titleLabel.stringValue = "SAVE FAILED"
            detailLabel.stringValue = message
            retryButton.isHidden = !canRetry
            dismissButton.title = "Dismiss"
            dismissButton.identifier = NSUserInterfaceItemIdentifier("banner-dismiss")
        case .recoveryError(let message):
            titleLabel.stringValue = "RECOVERY WRITE WARNING"
            detailLabel.stringValue = message
            dismissButton.title = "Dismiss"
            dismissButton.identifier = NSUserInterfaceItemIdentifier("banner-dismiss")
        }
        layoutControls()
        needsDisplay = true
    }

    public func layoutControls(maxWidth: CGFloat = 760) {
        let width = max(420, min(maxWidth, 760))
        let height: CGFloat = 52
        setFrameSize(NSSize(width: width, height: height))

        var rightX = width - 10
        let buttonY: CGFloat = 12
        let buttonH: CGFloat = 28

        for button in [dismissButton, reloadButton, saveAsButton, retryButton] where !button.isHidden {
            let btnWidth = max(72, ceil((button.title as NSString).size(withAttributes: [
                .font: CanvasTypography.font("sans", "s", scale: 11.5 / 14.0)
            ]).width) + 16)
            rightX -= btnWidth
            button.frame = NSRect(x: rightX, y: buttonY, width: btnWidth, height: buttonH)
            rightX -= 6
        }

        let textWidth = max(120, rightX - 16)
        titleLabel.frame = NSRect(x: 12, y: 7, width: textWidth, height: 16)
        detailLabel.frame = NSRect(x: 12, y: 25, width: textWidth, height: 18)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let activeKind else { return }
        let bg: NSColor
        switch activeKind {
        case .conflict:
            bg = CanvasTheme.yellow
        case .readOnly:
            bg = CanvasTheme.sky
        case .saveError, .recoveryError:
            bg = CanvasTheme.red
        }
        bg.setFill()
        bounds.fill()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        CanvasTheme.borderStrong.setStroke()
        border.stroke()
    }

    @objc private func handleSaveAs(_ sender: Any?) {
        onSaveAs?()
    }

    @objc private func handleReload(_ sender: Any?) {
        onReloadFromDisk?()
    }

    @objc private func handleRetry(_ sender: Any?) {
        onRetrySave?()
    }

    @objc private func handleDismiss(_ sender: Any?) {
        if case .conflict = activeKind {
            onKeepEditing?()
        } else {
            onDismiss?()
        }
    }
}

@MainActor
public final class CanvasShortcutsSheet: NSObject {
    public let panel: NSPanel
    private let completion: () -> Void
    private weak var hostWindow: NSWindow?

    public init(completion: @escaping () -> Void) {
        self.completion = completion
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 452),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Keyboard & Pointer Shortcuts"
        panel.identifier = NSUserInterfaceItemIdentifier("shortcuts-sheet")
        panel.isReleasedWhenClosed = false
        self.panel = panel
        super.init()
        buildContent()
    }

    private func buildContent() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 452))
        content.wantsLayer = true
        content.layer?.backgroundColor = CanvasTheme.canvasBackground.cgColor

        let header = NSTextField(labelWithString: "Keyboard & Pointer Reference")
        header.identifier = NSUserInterfaceItemIdentifier("shortcuts-header")
        header.font = CanvasTypography.font("heading", "m", scale: 18.0 / 16.0)
        header.textColor = CanvasTheme.primaryText
        header.frame = NSRect(x: 24, y: 406, width: 532, height: 26)
        content.addSubview(header)

        let subtitle = NSTextField(labelWithString: "Single-key shortcuts apply when the canvas is focused outside an active text editor.")
        subtitle.font = CanvasTypography.font("sans", "s", scale: 12.0 / 14.0)
        subtitle.textColor = CanvasTheme.secondaryText
        subtitle.frame = NSRect(x: 24, y: 382, width: 532, height: 18)
        content.addSubview(subtitle)

        let sections: [(String, [(String, String)])] = [
            ("CREATE & CONNECT", [
                ("V / Esc", "Select tool / cancel active mode"),
                ("R / O / D / I / T", "Insert Rectangle, Ellipse, Diamond, Triangle, Text"),
                ("L / A", "Insert standalone Line or Arrow"),
                ("N then ↑ → ↓ ←", "Grow adjacent thought along cardinal ray"),
                ("C / Port drag", "Create or edit bound connection"),
            ]),
            ("SELECT & VIEWPORT", [
                ("Tab / ⇧Tab", "Traverse objects and connections"),
                ("Space (tap / drag)", "Toggle focused item / pan canvas"),
                ("Arrows / ⇧Arrows", "Move selection by 1 / 10 world units"),
                ("+ / - / ⇧1 / ⌘0", "Zoom in, zoom out, fit, actual size"),
                ("⌘A / Marquee", "Select all or box-select objects"),
            ]),
            ("EDIT & GEOMETRY", [
                ("Return / Double-click", "Edit text, connection label, or preview attachment"),
                ("G then Tab / Arrows", "Edit resize/rotation handles or line endpoints"),
                ("S", "Open/close floating Style inspector"),
                ("⌘L / ⇧⌘] / ⇧⌘[", "Lock/unlock or Bring to Front / Send to Back"),
                ("⌥⌘Arrows / ⌃⌘H·V", "Align edges/centers (⇧⌃⌘H·V distribute)"),
                ("⌘C / ⌘X / ⌘V / ⌘D", "Copy, Cut, Paste, Duplicate"),
            ]),
            ("DOCUMENT & EXPORT", [
                ("⌘S / ⇧⌘S", "Save JSON / Save As"),
                ("⇧⌘E", "Export transparent Keynote PNG"),
                ("⌘Z / ⇧⌘Z", "Undo / Redo"),
                ("? / ⌘/", "Show this keyboard reference"),
            ]),
        ]

        let colWidth: CGFloat = 258
        let rowHeight: CGFloat = 156
        for (idx, section) in sections.enumerated() {
            let col = idx % 2
            let row = idx / 2
            let cardX: CGFloat = 24 + CGFloat(col) * (colWidth + 16)
            let cardY: CGFloat = row == 0 ? 216 : 48
            let card = NSView(frame: NSRect(x: cardX, y: cardY, width: colWidth, height: rowHeight))
            card.wantsLayer = true
            card.layer?.backgroundColor = CanvasTheme.elevatedSurface.cgColor
            card.layer?.borderColor = CanvasTheme.borderStrong.cgColor
            card.layer?.borderWidth = 1.5

            let sectionTitle = NSTextField(labelWithString: section.0)
            sectionTitle.font = CanvasTypography.font("mono", "s", scale: 10.5 / 14.0)
            sectionTitle.textColor = CanvasTheme.mutedText
            sectionTitle.frame = NSRect(x: 10, y: rowHeight - 24, width: colWidth - 20, height: 16)
            card.addSubview(sectionTitle)

            var itemY = rowHeight - 44
            for (keys, desc) in section.1 {
                let line = NSTextField(labelWithString: "\(keys) — \(desc)")
                line.font = CanvasTypography.font("sans", "s", scale: 11.0 / 14.0)
                line.textColor = CanvasTheme.primaryText
                line.lineBreakMode = .byTruncatingTail
                line.frame = NSRect(x: 10, y: itemY, width: colWidth - 20, height: 16)
                card.addSubview(line)
                itemY -= 21
            }
            content.addSubview(card)
        }

        let closeButton = NSButton(title: "Done", target: self, action: #selector(closeSheet(_:)))
        closeButton.identifier = NSUserInterfaceItemIdentifier("shortcuts-close")
        closeButton.keyEquivalent = "\r"
        closeButton.frame = NSRect(x: 476, y: 12, width: 80, height: 28)
        content.addSubview(closeButton)

        let cancelButton = NSButton(title: "Close", target: self, action: #selector(closeSheet(_:)))
        cancelButton.identifier = NSUserInterfaceItemIdentifier("shortcuts-cancel")
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.isTransparent = true
        cancelButton.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        content.addSubview(cancelButton)

        panel.contentView = content
    }

    public func present(on window: NSWindow) {
        hostWindow = window
        window.beginSheet(panel) { [weak self] _ in
            self?.completion()
        }
    }

    @objc public func closeSheet(_ sender: Any?) {
        if let hostWindow, hostWindow.attachedSheet === panel {
            hostWindow.endSheet(panel)
        } else {
            panel.orderOut(nil)
            completion()
        }
    }
}

@MainActor
public final class CanvasRecentDocumentsStore {
    public let defaultsKey: String
    public let maxCount: Int
    private let defaults: UserDefaults

    public init(
        defaults: UserDefaults = .standard,
        defaultsKey: String = "local.elixircanvas.native.recentDocumentPaths",
        maxCount: Int = 10
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        self.maxCount = max(1, maxCount)
    }

    public var recentURLs: [URL] {
        let paths = defaults.stringArray(forKey: defaultsKey) ?? []
        var valid: [URL] = []
        var seen = Set<String>()
        for path in paths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard !seen.contains(url.path),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            seen.insert(url.path)
            valid.append(url)
            if valid.count >= maxCount { break }
        }
        return valid
    }

    public func record(_ url: URL) {
        let standardized = url.standardizedFileURL.path
        var paths = defaults.stringArray(forKey: defaultsKey) ?? []
        paths.removeAll { URL(fileURLWithPath: $0).standardizedFileURL.path == standardized }
        paths.insert(standardized, at: 0)
        if paths.count > maxCount {
            paths = Array(paths.prefix(maxCount))
        }
        defaults.set(paths, forKey: defaultsKey)
        NSDocumentController.shared.noteNewRecentDocumentURL(url.standardizedFileURL)
    }

    public func clear() {
        defaults.removeObject(forKey: defaultsKey)
        NSDocumentController.shared.clearRecentDocuments(nil)
    }
}
