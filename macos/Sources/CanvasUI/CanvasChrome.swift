import AppKit
import CanvasCore

public enum CanvasCreationTool: Equatable, Sendable {
    case select
    case shape(CanvasShapeKind)
    case line(CanvasLineKind)
    case code

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
        case .code: return "dock-tool-code"
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
        case .code: return "Code"
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
        case .code: return "K"
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
        case .code:
            return "Code tool armed · Click or drag on canvas to place code block · Return: center · V / Escape: Select"
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
        .code,
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
    case code
    case connect
    case thought
    case style
    case exportPNG
    case help
}

@MainActor
enum CanvasFloatingElevation {
    static func apply(to view: NSView) {
        view.wantsLayer = true
        view.layer?.masksToBounds = false
        view.layer?.shadowColor = CanvasTheme.borderStrong.cgColor
        view.layer?.shadowOpacity = 0.16
        view.layer?.shadowOffset = CGSize(width: 3, height: -3)
        view.layer?.shadowRadius = 0
    }
}

@MainActor
public final class NeoAcidActionButton: NSButton {
    public enum Variant {
        case primary
        case secondary
        case subtle
    }

    public var variant: Variant {
        didSet { needsDisplay = true }
    }
    public var onEscape: (() -> Void)?
    private var isHovered: Bool = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    public override var isFlipped: Bool { true }
    public override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    public init(
        title: String,
        variant: Variant = .secondary,
        target: AnyObject? = nil,
        action: Selector? = nil
    ) {
        self.variant = variant
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        self.isBordered = false
    }

    public required init?(coder: NSCoder) {
        fatalError("NeoAcidActionButton does not support NSCoder")
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false }

    public override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        needsDisplay = true
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        needsDisplay = true
        return ok
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           let onEscape {
            onEscape()
            return
        }
        super.keyDown(with: event)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let isFocused = window?.firstResponder === self
        let fill: NSColor
        let borderColor: NSColor
        let borderWidth: CGFloat

        if !isEnabled {
            fill = CanvasTheme.surface.withAlphaComponent(0.75)
            borderColor = CanvasTheme.borderSubtle
            borderWidth = 1.0
        } else {
            switch variant {
            case .primary:
                if isHighlighted {
                    fill = CanvasTheme.acid.blended(withFraction: 0.18, of: CanvasTheme.highlighterInk) ?? CanvasTheme.acid
                } else if isHovered {
                    fill = CanvasTheme.acid.blended(withFraction: 0.08, of: CanvasTheme.elevatedSurface) ?? CanvasTheme.acid
                } else {
                    fill = CanvasTheme.acid
                }
                borderColor = CanvasTheme.borderStrong
                borderWidth = 1.75
            case .secondary:
                if isHighlighted {
                    fill = CanvasTheme.acid.withAlphaComponent(0.6)
                } else if isHovered {
                    fill = CanvasTheme.surface
                } else {
                    fill = CanvasTheme.elevatedSurface
                }
                borderColor = CanvasTheme.borderStrong
                borderWidth = 1.5
            case .subtle:
                if isHighlighted {
                    fill = CanvasTheme.acid.withAlphaComponent(0.45)
                } else if isHovered {
                    fill = CanvasTheme.elevatedSurface
                } else {
                    fill = CanvasTheme.surface
                }
                borderColor = (isHovered || isHighlighted) ? CanvasTheme.borderStrong : CanvasTheme.borderSubtle
                borderWidth = (isHovered || isHighlighted) ? 1.25 : 1.0
            }
        }

        fill.setFill()
        bounds.fill()

        let strokeRect = bounds.insetBy(dx: isFocused ? 1.0 : borderWidth / 2.0, dy: isFocused ? 1.0 : borderWidth / 2.0)
        let border = NSBezierPath(rect: strokeRect)
        if isFocused {
            border.lineWidth = 2.0
            CanvasTheme.selectionCobalt.setStroke()
        } else {
            border.lineWidth = borderWidth
            borderColor.setStroke()
        }
        border.stroke()

        let textColor = isEnabled ? CanvasTheme.highlighterInk : CanvasTheme.mutedText
        let font: NSFont = variant == .primary
            ? CanvasTypography.font("sans", "l", scale: 12.5 / 24.0)
            : CanvasTypography.font("sans", "m", scale: 12.0 / 16.0)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
        let label = title as NSString
        let size = label.size(withAttributes: attrs)
        let textRect = CGRect(
            x: 8,
            y: floor((bounds.height - size.height) / 2.0),
            width: max(0, bounds.width - 16),
            height: size.height + 2
        )
        label.draw(in: textRect, withAttributes: attrs)
    }
}

@MainActor
public final class NeoAcidRecentRowButton: NSButton {
    public let filenameTitle: String
    public let directorySubtitle: String
    private var isHovered: Bool = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    public override var isFlipped: Bool { true }
    public override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    public init(url: URL, target: AnyObject?, action: Selector?) {
        self.filenameTitle = url.lastPathComponent
        let parent = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        self.directorySubtitle = parent
        super.init(frame: .zero)
        self.title = url.lastPathComponent
        self.toolTip = url.path
        self.target = target
        self.action = action
        self.isBordered = false
        setAccessibilityLabel("Open recent canvas \(url.lastPathComponent)")
    }

    public required init?(coder: NSCoder) {
        fatalError("NeoAcidRecentRowButton does not support NSCoder")
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false }

    public override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        needsDisplay = true
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        needsDisplay = true
        return ok
    }

    public override func draw(_ dirtyRect: NSRect) {
        let isFocused = window?.firstResponder === self
        let fill: NSColor
        if isHighlighted {
            fill = CanvasTheme.acid.withAlphaComponent(0.55)
        } else if isHovered {
            fill = CanvasTheme.surface
        } else {
            fill = CanvasTheme.elevatedSurface
        }
        fill.setFill()
        bounds.fill()

        let border = NSBezierPath(rect: bounds.insetBy(dx: isFocused ? 1.0 : 0.5, dy: isFocused ? 1.0 : 0.5))
        if isFocused {
            border.lineWidth = 2.0
            CanvasTheme.selectionCobalt.setStroke()
        } else if isHovered || isHighlighted {
            border.lineWidth = 1.25
            CanvasTheme.borderStrong.setStroke()
        } else {
            border.lineWidth = 1.0
            CanvasTheme.borderSubtle.setStroke()
        }
        border.stroke()

        // Small Neo-Acid document square marker
        let marker = CGRect(x: 10, y: floor((bounds.height - 8) / 2), width: 8, height: 8)
        (isHovered ? CanvasTheme.acid : CanvasTheme.surface).setFill()
        marker.fill()
        let markerBorder = NSBezierPath(rect: marker)
        markerBorder.lineWidth = 1.0
        CanvasTheme.borderStrong.setStroke()
        markerBorder.stroke()

        let nameStyle = NSMutableParagraphStyle()
        nameStyle.lineBreakMode = .byTruncatingMiddle
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: CanvasTypography.font("sans", "l", scale: 12.0 / 24.0),
            .foregroundColor: CanvasTheme.primaryText,
            .paragraphStyle: nameStyle,
        ]
        let pathStyle = NSMutableParagraphStyle()
        pathStyle.alignment = .right
        pathStyle.lineBreakMode = .byTruncatingHead
        let pathAttrs: [NSAttributedString.Key: Any] = [
            .font: CanvasTypography.font("mono", "s", scale: 10.0 / 14.0),
            .foregroundColor: CanvasTheme.mutedText,
            .paragraphStyle: pathStyle,
        ]

        let nameText = filenameTitle as NSString
        let pathText = directorySubtitle as NSString
        let nameMeasured = min(bounds.width * 0.54, ceil(nameText.size(withAttributes: nameAttrs).width) + 4)
        let nameRect = CGRect(
            x: 26,
            y: floor((bounds.height - 16) / 2),
            width: nameMeasured,
            height: 17
        )
        nameText.draw(in: nameRect, withAttributes: nameAttrs)

        let pathX = nameRect.maxX + 10
        let pathW = max(0, bounds.width - pathX - 10)
        if pathW > 36 {
            let pathRect = CGRect(
                x: pathX,
                y: floor((bounds.height - 14) / 2) + 0.5,
                width: pathW,
                height: 15
            )
            pathText.draw(in: pathRect, withAttributes: pathAttrs)
        }
    }
}

@MainActor
public final class NeoAcidCheckboxButton: NSButton {
    public var onEscape: (() -> Void)?
    private var isHovered: Bool = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    public override var isFlipped: Bool { true }
    public override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    public init(title: String, target: AnyObject? = nil, action: Selector? = nil) {
        super.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        self.target = target
        self.action = action
        self.isBordered = false
    }

    public required init?(coder: NSCoder) {
        fatalError("NeoAcidCheckboxButton does not support NSCoder")
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false }

    public override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        needsDisplay = true
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        needsDisplay = true
        return ok
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           let onEscape {
            onEscape()
            return
        }
        super.keyDown(with: event)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let isFocused = window?.firstResponder === self
        let checked = state == .on
        let boxSize: CGFloat = 15
        let boxY = floor((bounds.height - boxSize) / 2.0)
        let boxRect = CGRect(x: 2, y: boxY, width: boxSize, height: boxSize)

        let boxFill: NSColor
        if !isEnabled {
            boxFill = CanvasTheme.surface
        } else if checked {
            boxFill = CanvasTheme.acid
        } else if isHovered {
            boxFill = CanvasTheme.surface
        } else {
            boxFill = CanvasTheme.elevatedSurface
        }
        boxFill.setFill()
        boxRect.fill()

        let boxBorder = NSBezierPath(rect: boxRect.insetBy(dx: 0.75, dy: 0.75))
        boxBorder.lineWidth = isFocused ? 2.0 : 1.5
        (isFocused ? CanvasTheme.selectionCobalt : (isEnabled ? CanvasTheme.borderStrong : CanvasTheme.borderSubtle)).setStroke()
        boxBorder.stroke()

        if checked {
            let check = NSBezierPath()
            check.move(to: CGPoint(x: boxRect.minX + 3.5, y: boxRect.midY + 0.5))
            check.line(to: CGPoint(x: boxRect.minX + 6.5, y: boxRect.maxY - 3.8))
            check.line(to: CGPoint(x: boxRect.maxX - 3.2, y: boxRect.minY + 3.8))
            check.lineWidth = 2.0
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            CanvasTheme.highlighterInk.setStroke()
            check.stroke()
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: CanvasTypography.font("sans", "m", scale: 12.0 / 16.0),
            .foregroundColor: isEnabled ? CanvasTheme.primaryText : CanvasTheme.mutedText,
        ]
        let label = title as NSString
        let size = label.size(withAttributes: attrs)
        let labelRect = CGRect(
            x: boxRect.maxX + 7,
            y: floor((bounds.height - size.height) / 2.0),
            width: max(0, bounds.width - boxRect.maxX - 8),
            height: size.height + 2
        )
        label.draw(in: labelRect, withAttributes: attrs)
    }
}

@MainActor
public final class NeoAcidPopUpButton: NSPopUpButton {
    public var onEscape: (() -> Void)?
    public var forwardCommandKeyToSuperview: Bool = false
    private var isHovered: Bool = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    public override var isFlipped: Bool { true }
    public override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    public override func mouseEntered(with event: NSEvent) { isHovered = true }
    public override func mouseExited(with event: NSEvent) { isHovered = false }

    public override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds, cursor: .pointingHand) }
    }

    public override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        needsDisplay = true
        return ok
    }

    public override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        needsDisplay = true
        return ok
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           let onEscape {
            onEscape()
            return
        }
        if forwardCommandKeyToSuperview && event.modifierFlags.contains(.command) {
            superview?.keyDown(with: event)
            return
        }
        super.keyDown(with: event)
    }

    public override func draw(_ dirtyRect: NSRect) {
        let isFocused = window?.firstResponder === self
        let fill: NSColor
        if !isEnabled {
            fill = CanvasTheme.surface.withAlphaComponent(0.75)
        } else if isHighlighted {
            fill = CanvasTheme.acid.withAlphaComponent(0.45)
        } else if isHovered {
            fill = CanvasTheme.surface
        } else {
            fill = CanvasTheme.elevatedSurface
        }
        fill.setFill()
        bounds.fill()

        let strokeInset: CGFloat = isFocused ? 1.0 : 0.75
        let border = NSBezierPath(rect: bounds.insetBy(dx: strokeInset, dy: strokeInset))
        if isFocused {
            border.lineWidth = 2.0
            CanvasTheme.selectionCobalt.setStroke()
        } else if isHovered || isHighlighted {
            border.lineWidth = 1.5
            CanvasTheme.borderStrong.setStroke()
        } else {
            border.lineWidth = 1.0
            CanvasTheme.borderSubtle.setStroke()
        }
        border.stroke()

        var textX: CGFloat = 8
        if let image = selectedItem?.image {
            let imgSize = image.size
            let drawW = min(16, imgSize.width)
            let drawH = min(14, imgSize.height)
            let imgRect = CGRect(
                x: textX,
                y: floor((bounds.height - drawH) / 2.0),
                width: drawW,
                height: drawH
            )
            image.draw(in: imgRect, from: .zero, operation: .sourceOver, fraction: isEnabled ? 1.0 : 0.45, respectFlipped: true, hints: nil)
            textX = imgRect.maxX + 6
        }

        let currentTitle = selectedItem?.title ?? ""
        let isMixed = currentTitle == "Mixed"
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let textColor: NSColor
        if !isEnabled {
            textColor = CanvasTheme.mutedText
        } else if isMixed {
            textColor = CanvasTheme.mutedText
        } else {
            textColor = CanvasTheme.primaryText
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: CanvasTypography.font("sans", "m", scale: 12.0 / 16.0),
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
        let label = currentTitle as NSString
        let size = label.size(withAttributes: attrs)
        let textWidth = max(0, bounds.width - textX - 22)
        let textRect = CGRect(
            x: textX,
            y: floor((bounds.height - size.height) / 2.0),
            width: textWidth,
            height: size.height + 2
        )
        label.draw(in: textRect, withAttributes: attrs)

        // Crisp double-chevron indicator on the right
        let cx = bounds.maxX - 11
        let cy = bounds.midY
        let chevrons = NSBezierPath()
        chevrons.move(to: CGPoint(x: cx - 3, y: cy - 1.5))
        chevrons.line(to: CGPoint(x: cx, y: cy - 4.5))
        chevrons.line(to: CGPoint(x: cx + 3, y: cy - 1.5))
        chevrons.move(to: CGPoint(x: cx - 3, y: cy + 1.5))
        chevrons.line(to: CGPoint(x: cx, y: cy + 4.5))
        chevrons.line(to: CGPoint(x: cx + 3, y: cy + 1.5))
        chevrons.lineWidth = 1.4
        chevrons.lineCapStyle = .round
        chevrons.lineJoinStyle = .round
        (isEnabled ? CanvasTheme.secondaryText : CanvasTheme.mutedText).setStroke()
        chevrons.stroke()
    }
}

@MainActor
enum CanvasStyleGlyphs {
    static func colorSwatch(name: String) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        return NSImage(size: size, flipped: true) { rect in
            let box = rect.insetBy(dx: 1, dy: 1)
            if name == "none" {
                CanvasTheme.elevatedSurface.setFill()
                box.fill()
                let slash = NSBezierPath()
                slash.move(to: CGPoint(x: box.minX + 1.5, y: box.maxY - 1.5))
                slash.line(to: CGPoint(x: box.maxX - 1.5, y: box.minY + 1.5))
                slash.lineWidth = 1.6
                CanvasTheme.red.setStroke()
                slash.stroke()
            } else {
                CanvasTheme.palette(name).setFill()
                box.fill()
            }
            let border = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1.0
            CanvasTheme.borderStrong.setStroke()
            border.stroke()
            return true
        }
    }

    static func mixedColorSwatch() -> NSImage {
        let size = NSSize(width: 14, height: 14)
        return NSImage(size: size, flipped: true) { rect in
            let box = rect.insetBy(dx: 1, dy: 1)
            let halfW = box.width / 2
            let halfH = box.height / 2
            CanvasTheme.acid.setFill()
            CGRect(x: box.minX, y: box.minY, width: halfW, height: halfH).fill()
            CanvasTheme.sky.setFill()
            CGRect(x: box.minX + halfW, y: box.minY, width: halfW, height: halfH).fill()
            CanvasTheme.violet.setFill()
            CGRect(x: box.minX, y: box.minY + halfH, width: halfW, height: halfH).fill()
            CanvasTheme.mint.setFill()
            CGRect(x: box.minX + halfW, y: box.minY + halfH, width: halfW, height: halfH).fill()
            let border = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1.0
            CanvasTheme.borderStrong.setStroke()
            border.stroke()
            return true
        }
    }

    static func strokeWidthGlyph(_ width: Int) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 12), flipped: true) { rect in
            let line = NSBezierPath()
            line.move(to: CGPoint(x: 1, y: rect.midY))
            line.line(to: CGPoint(x: rect.width - 1, y: rect.midY))
            line.lineWidth = CGFloat(max(1, min(4, width)))
            line.lineCapStyle = .butt
            CanvasTheme.primaryText.setStroke()
            line.stroke()
            return true
        }
    }

    static func strokeDashGlyph(dashed: Bool) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 12), flipped: true) { rect in
            let line = NSBezierPath()
            line.move(to: CGPoint(x: 1, y: rect.midY))
            line.line(to: CGPoint(x: rect.width - 1, y: rect.midY))
            line.lineWidth = 2.0
            if dashed {
                let pattern: [CGFloat] = [3.5, 2.5]
                line.setLineDash(pattern, count: pattern.count, phase: 0)
            }
            CanvasTheme.primaryText.setStroke()
            line.stroke()
            return true
        }
    }

    static func cornerRadiusGlyph(rounded: Bool) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: true) { rect in
            let box = rect.insetBy(dx: 2, dy: 2)
            let path = rounded
                ? NSBezierPath(roundedRect: box, xRadius: 3.5, yRadius: 3.5)
                : NSBezierPath(rect: box)
            path.lineWidth = 1.6
            CanvasTheme.primaryText.setStroke()
            path.stroke()
            return true
        }
    }

    static func arrowGlyph(_ mode: String) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 12), flipped: true) { rect in
            let cy = rect.midY
            let path = NSBezierPath()
            path.move(to: CGPoint(x: 2, y: cy))
            path.line(to: CGPoint(x: 14, y: cy))
            if mode == "end" || mode == "both" {
                path.move(to: CGPoint(x: 10.5, y: cy - 3.5))
                path.line(to: CGPoint(x: 14, y: cy))
                path.line(to: CGPoint(x: 10.5, y: cy + 3.5))
            }
            if mode == "both" {
                path.move(to: CGPoint(x: 5.5, y: cy - 3.5))
                path.line(to: CGPoint(x: 2, y: cy))
                path.line(to: CGPoint(x: 5.5, y: cy + 3.5))
            }
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            CanvasTheme.primaryText.setStroke()
            path.stroke()
            return true
        }
    }

    static func pathGlyph(_ style: String) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 12), flipped: true) { _ in
            let path = NSBezierPath()
            switch style {
            case "straight":
                path.move(to: CGPoint(x: 2, y: 10))
                path.line(to: CGPoint(x: 14, y: 2))
            case "step":
                path.move(to: CGPoint(x: 2, y: 10))
                path.line(to: CGPoint(x: 8, y: 10))
                path.line(to: CGPoint(x: 8, y: 2))
                path.line(to: CGPoint(x: 14, y: 2))
            case "smooth":
                path.move(to: CGPoint(x: 2, y: 10))
                path.line(to: CGPoint(x: 6, y: 10))
                path.curve(to: CGPoint(x: 8, y: 8), controlPoint1: CGPoint(x: 7.5, y: 10), controlPoint2: CGPoint(x: 8, y: 9.5))
                path.line(to: CGPoint(x: 8, y: 4))
                path.curve(to: CGPoint(x: 10, y: 2), controlPoint1: CGPoint(x: 8, y: 2.5), controlPoint2: CGPoint(x: 8.5, y: 2))
                path.line(to: CGPoint(x: 14, y: 2))
            default: // bezier
                path.move(to: CGPoint(x: 2, y: 10))
                path.curve(to: CGPoint(x: 14, y: 2), controlPoint1: CGPoint(x: 8, y: 10), controlPoint2: CGPoint(x: 8, y: 2))
            }
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            CanvasTheme.primaryText.setStroke()
            path.stroke()
            return true
        }
    }

    static func markerGlyph(_ marker: String) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 12), flipped: true) { rect in
            let cy = rect.midY
            let line = NSBezierPath()
            line.move(to: CGPoint(x: 1.5, y: cy))
            line.line(to: CGPoint(x: marker == "dot" ? 11 : 13.5, y: cy))
            line.lineWidth = 1.6
            line.lineCapStyle = .round
            CanvasTheme.primaryText.setStroke()
            line.stroke()
            if marker == "arrow" {
                let head = NSBezierPath()
                head.move(to: CGPoint(x: 10, y: cy - 3.5))
                head.line(to: CGPoint(x: 14, y: cy))
                head.line(to: CGPoint(x: 10, y: cy + 3.5))
                head.lineWidth = 1.6
                head.lineCapStyle = .round
                head.lineJoinStyle = .round
                head.stroke()
            } else if marker == "dot" {
                CanvasTheme.primaryText.setFill()
                NSBezierPath(ovalIn: CGRect(x: 10, y: cy - 2.5, width: 5, height: 5)).fill()
            }
            return true
        }
    }

    static func alignGlyph(_ align: String) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 12), flipped: true) { _ in
            CanvasTheme.primaryText.setStroke()
            let rows: [(CGFloat, CGFloat)] = [(2.5, 11), (6.0, 7.5), (9.5, 9.5)]
            for (y, w) in rows {
                let x: CGFloat
                switch align {
                case "center": x = (14 - w) / 2
                case "right": x = 14 - 1.5 - w
                default: x = 1.5
                }
                let line = NSBezierPath()
                line.move(to: CGPoint(x: x, y: y))
                line.line(to: CGPoint(x: x + w, y: y))
                line.lineWidth = 1.5
                line.lineCapStyle = .round
                line.stroke()
            }
            return true
        }
    }

    static func paperGlyph(_ pattern: String) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: true) { rect in
            let box = rect.insetBy(dx: 1, dy: 1)
            CanvasTheme.canvasBackground.setFill()
            box.fill()
            CanvasTheme.mutedText.setFill()
            CanvasTheme.mutedText.setStroke()
            switch pattern {
            case "dots":
                for x in [4.5, 9.5] {
                    for y in [4.5, 9.5] {
                        NSBezierPath(ovalIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)).fill()
                    }
                }
            case "lines":
                let p = NSBezierPath()
                for c in [5.0, 9.0] {
                    p.move(to: CGPoint(x: box.minX + 1, y: c))
                    p.line(to: CGPoint(x: box.maxX - 1, y: c))
                    p.move(to: CGPoint(x: c, y: box.minY + 1))
                    p.line(to: CGPoint(x: c, y: box.maxY - 1))
                }
                p.lineWidth = 0.8
                p.stroke()
            case "cross":
                let p = NSBezierPath()
                for (x, y) in [(5.0, 5.0), (9.0, 9.0)] {
                    p.move(to: CGPoint(x: x - 1.5, y: y))
                    p.line(to: CGPoint(x: x + 1.5, y: y))
                    p.move(to: CGPoint(x: x, y: y - 1.5))
                    p.line(to: CGPoint(x: x, y: y + 1.5))
                }
                p.lineWidth = 1.0
                p.stroke()
            default:
                break
            }
            let border = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1.0
            CanvasTheme.borderStrong.setStroke()
            border.stroke()
            return true
        }
    }
}

@MainActor
private final class NeoAcidDockButton: NSButton {
    var isActiveTool: Bool = false {
        didSet { needsDisplay = true }
    }
    var iconGlyph: CanvasDockIconGlyph? {
        didSet { needsDisplay = true }
    }
    var usesMonospaceTitle: Bool = false {
        didSet { needsDisplay = true }
    }
    private var isHovered: Bool = false {
        didSet {
            if oldValue != isHovered {
                needsDisplay = true
            }
        }
    }

    override var isFlipped: Bool { true }
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        needsDisplay = true
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        needsDisplay = true
        return ok
    }

    override func draw(_ dirtyRect: NSRect) {
        let isFocused = window?.firstResponder === self
        let fill: NSColor
        if !isEnabled {
            fill = CanvasTheme.surface.withAlphaComponent(0.6)
        } else if isActiveTool {
            fill = CanvasTheme.acid
        } else if isHighlighted {
            fill = CanvasTheme.acid.withAlphaComponent(0.65)
        } else if isHovered {
            fill = CanvasTheme.surface
        } else {
            fill = CanvasTheme.elevatedSurface
        }
        fill.setFill()
        bounds.fill()

        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        if isFocused {
            border.lineWidth = 2.0
            CanvasTheme.selectionCobalt.setStroke()
        } else if isActiveTool || (isHovered && isEnabled) || isHighlighted {
            border.lineWidth = isActiveTool ? 1.5 : 1.25
            CanvasTheme.borderStrong.setStroke()
        } else {
            border.lineWidth = 1.0
            CanvasTheme.borderSubtle.setStroke()
        }
        border.stroke()

        let strokeColor = isEnabled ? CanvasTheme.highlighterInk : CanvasTheme.mutedText
        if let glyph = iconGlyph {
            drawIconGlyph(glyph, in: bounds, color: strokeColor)
            return
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let titleFont: NSFont = usesMonospaceTitle
            ? CanvasTypography.font("mono", "s", scale: 11.0 / 14.0)
            : CanvasTypography.font("sans", "s", scale: 11.5 / 14.0)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: titleFont,
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
            path.move(to: CGPoint(x: cx - 5.2, y: cy - 8.2))
            path.line(to: CGPoint(x: cx - 5.2, y: cy + 6.4))
            path.line(to: CGPoint(x: cx - 1.4, y: cy + 3.0))
            path.line(to: CGPoint(x: cx + 1.8, y: cy + 8.2))
            path.line(to: CGPoint(x: cx + 3.9, y: cy + 7.1))
            path.line(to: CGPoint(x: cx + 0.8, y: cy + 2.0))
            path.line(to: CGPoint(x: cx + 5.8, y: cy + 2.0))
            path.close()
            path.lineJoinStyle = .miter
            path.fill()

        case .rectangle:
            let path = NSBezierPath(rect: CGRect(x: cx - 7.5, y: cy - 5.5, width: 15, height: 11))
            path.lineWidth = 1.75
            path.lineJoinStyle = .miter
            path.stroke()

        case .ellipse:
            let path = NSBezierPath(ovalIn: CGRect(x: cx - 7.5, y: cy - 5.5, width: 15, height: 11))
            path.lineWidth = 1.75
            path.stroke()

        case .diamond:
            let path = NSBezierPath()
            path.move(to: CGPoint(x: cx, y: cy - 7.5))
            path.line(to: CGPoint(x: cx + 7.5, y: cy))
            path.line(to: CGPoint(x: cx, y: cy + 7.5))
            path.line(to: CGPoint(x: cx - 7.5, y: cy))
            path.close()
            path.lineWidth = 1.75
            path.lineJoinStyle = .round
            path.stroke()

        case .triangle:
            let path = NSBezierPath()
            path.move(to: CGPoint(x: cx, y: cy - 7.0))
            path.line(to: CGPoint(x: cx + 7.8, y: cy + 6.8))
            path.line(to: CGPoint(x: cx - 7.8, y: cy + 6.8))
            path.close()
            path.lineWidth = 1.75
            path.lineJoinStyle = .round
            path.stroke()

        case .text:
            let path = NSBezierPath()
            path.move(to: CGPoint(x: cx - 6.0, y: cy - 4.0))
            path.line(to: CGPoint(x: cx - 6.0, y: cy - 6.5))
            path.line(to: CGPoint(x: cx + 6.0, y: cy - 6.5))
            path.line(to: CGPoint(x: cx + 6.0, y: cy - 4.0))
            path.move(to: CGPoint(x: cx, y: cy - 6.5))
            path.line(to: CGPoint(x: cx, y: cy + 6.8))
            path.move(to: CGPoint(x: cx - 3.0, y: cy + 6.8))
            path.line(to: CGPoint(x: cx + 3.0, y: cy + 6.8))
            path.lineWidth = 1.75
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

        case .line:
            let path = NSBezierPath()
            path.move(to: CGPoint(x: cx - 6.2, y: cy + 6.2))
            path.line(to: CGPoint(x: cx + 6.2, y: cy - 6.2))
            path.lineWidth = 1.75
            path.lineCapStyle = .round
            path.stroke()
            NSBezierPath(ovalIn: CGRect(x: cx - 8.2, y: cy + 4.2, width: 4, height: 4)).fill()
            NSBezierPath(ovalIn: CGRect(x: cx + 4.2, y: cy - 8.2, width: 4, height: 4)).fill()

        case .arrow:
            let path = NSBezierPath()
            path.move(to: CGPoint(x: cx - 6.5, y: cy + 6.5))
            path.line(to: CGPoint(x: cx + 6.2, y: cy - 6.2))
            path.move(to: CGPoint(x: cx + 0.5, y: cy - 6.2))
            path.line(to: CGPoint(x: cx + 6.2, y: cy - 6.2))
            path.line(to: CGPoint(x: cx + 6.2, y: cy - 0.5))
            path.lineWidth = 1.75
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

        case .code:
            let path = NSBezierPath()
            path.move(to: CGPoint(x: cx - 4.5, y: cy - 4.6))
            path.line(to: CGPoint(x: cx - 8.6, y: cy))
            path.line(to: CGPoint(x: cx - 4.5, y: cy + 4.6))
            path.move(to: CGPoint(x: cx + 4.5, y: cy - 4.6))
            path.line(to: CGPoint(x: cx + 8.6, y: cy))
            path.line(to: CGPoint(x: cx + 4.5, y: cy + 4.6))
            path.move(to: CGPoint(x: cx + 1.8, y: cy - 6.2))
            path.line(to: CGPoint(x: cx - 1.8, y: cy + 6.2))
            path.lineWidth = 1.7
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()

        case .connect:
            let n1 = NSBezierPath(rect: CGRect(x: cx - 7.5, y: cy - 6.5, width: 5.5, height: 5.5))
            let n2 = NSBezierPath(rect: CGRect(x: cx + 2.0, y: cy + 1.0, width: 5.5, height: 5.5))
            n1.lineWidth = 1.6
            n2.lineWidth = 1.6
            n1.stroke()
            n2.stroke()
            let route = NSBezierPath()
            route.move(to: CGPoint(x: cx - 2.0, y: cy - 3.75))
            route.line(to: CGPoint(x: cx + 4.75, y: cy - 3.75))
            route.line(to: CGPoint(x: cx + 4.75, y: cy + 1.0))
            route.lineWidth = 1.6
            route.lineCapStyle = .round
            route.lineJoinStyle = .round
            route.stroke()

        case .thought:
            let box = NSBezierPath(rect: CGRect(x: cx - 7.5, y: cy - 5.0, width: 9.5, height: 10.0))
            box.lineWidth = 1.6
            box.stroke()
            let plus = NSBezierPath()
            plus.move(to: CGPoint(x: cx + 5.5, y: cy - 3.5))
            plus.line(to: CGPoint(x: cx + 5.5, y: cy + 3.5))
            plus.move(to: CGPoint(x: cx + 2.0, y: cy))
            plus.line(to: CGPoint(x: cx + 9.0, y: cy))
            plus.lineWidth = 1.75
            plus.lineCapStyle = .round
            plus.stroke()

        case .style:
            let path = NSBezierPath()
            path.move(to: CGPoint(x: cx - 7.5, y: cy - 4.0))
            path.line(to: CGPoint(x: cx + 7.5, y: cy - 4.0))
            path.move(to: CGPoint(x: cx - 7.5, y: cy + 4.0))
            path.line(to: CGPoint(x: cx + 7.5, y: cy + 4.0))
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.stroke()
            NSBezierPath(ovalIn: CGRect(x: cx - 4.0, y: cy - 6.5, width: 5, height: 5)).fill()
            NSBezierPath(ovalIn: CGRect(x: cx + 0.5, y: cy + 1.5, width: 5, height: 5)).fill()

        case .exportPNG:
            let tray = NSBezierPath()
            tray.move(to: CGPoint(x: cx - 6.8, y: cy + 1.5))
            tray.line(to: CGPoint(x: cx - 6.8, y: cy + 6.8))
            tray.line(to: CGPoint(x: cx + 6.8, y: cy + 6.8))
            tray.line(to: CGPoint(x: cx + 6.8, y: cy + 1.5))
            tray.move(to: CGPoint(x: cx, y: cy + 2.8))
            tray.line(to: CGPoint(x: cx, y: cy - 6.8))
            tray.move(to: CGPoint(x: cx - 3.8, y: cy - 3.0))
            tray.line(to: CGPoint(x: cx, y: cy - 6.8))
            tray.line(to: CGPoint(x: cx + 3.8, y: cy - 3.0))
            tray.lineWidth = 1.75
            tray.lineCapStyle = .round
            tray.lineJoinStyle = .round
            tray.stroke()

        case .help:
            let q = NSBezierPath()
            q.move(to: CGPoint(x: cx - 3.2, y: cy - 3.8))
            q.curve(
                to: CGPoint(x: cx + 3.4, y: cy - 3.6),
                controlPoint1: CGPoint(x: cx - 3.2, y: cy - 7.8),
                controlPoint2: CGPoint(x: cx + 3.4, y: cy - 7.8)
            )
            q.curve(
                to: CGPoint(x: cx, y: cy + 1.8),
                controlPoint1: CGPoint(x: cx + 3.4, y: cy - 0.6),
                controlPoint2: CGPoint(x: cx, y: cy - 0.8)
            )
            q.lineWidth = 1.75
            q.lineCapStyle = .round
            q.lineJoinStyle = .round
            q.stroke()
            NSBezierPath(ovalIn: CGRect(x: cx - 1.15, y: cy + 4.4, width: 2.3, height: 2.3)).fill()
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
        CanvasFloatingElevation.apply(to: self)
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
        case .code: return .code
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
    private var isHovered: Bool = false {
        didSet {
            if oldValue != isHovered {
                needsDisplay = true
            }
        }
    }

    override var isFlipped: Bool { true }
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        needsDisplay = true
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        needsDisplay = true
        return ok
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
        let isFocused = window?.firstResponder === self
        let fill: NSColor
        if !isEnabled {
            fill = CanvasTheme.surface.withAlphaComponent(0.6)
        } else if isHighlighted {
            fill = CanvasTheme.acid
        } else if isHovered {
            fill = CanvasTheme.surface
        } else {
            fill = CanvasTheme.elevatedSurface
        }
        fill.setFill()
        bounds.fill()

        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        if isFocused {
            border.lineWidth = 2.0
            CanvasTheme.selectionCobalt.setStroke()
        } else if isHighlighted || (isHovered && isEnabled) {
            border.lineWidth = isHighlighted ? 1.5 : 1.25
            CanvasTheme.borderStrong.setStroke()
        } else {
            border.lineWidth = 1.0
            CanvasTheme.borderSubtle.setStroke()
        }
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
        CanvasFloatingElevation.apply(to: self)
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
public final class CanvasZoomControlView: NSView {
    public var onZoomOut: (() -> Void)?
    public var onResetZoom: (() -> Void)?
    public var onZoomIn: (() -> Void)?

    private let zoomOutButton = NeoAcidDockButton(frame: .zero)
    private let resetButton = NeoAcidDockButton(frame: .zero)
    private let zoomInButton = NeoAcidDockButton(frame: .zero)
    private var isCompact: Bool = false

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect = .zero) {
        super.init(frame: frameRect)
        identifier = NSUserInterfaceItemIdentifier("canvas-zoom-control")
        setAccessibilityRole(.group)
        setAccessibilityLabel("Canvas zoom controls")
        CanvasFloatingElevation.apply(to: self)
        buildControls()
    }

    public required init?(coder: NSCoder) {
        fatalError("CanvasZoomControlView does not support NSCoder")
    }

    public override func mouseDown(with event: NSEvent) {}
    public override func mouseDragged(with event: NSEvent) {}
    public override func mouseUp(with event: NSEvent) {}

    private func buildControls() {
        zoomOutButton.identifier = NSUserInterfaceItemIdentifier("zoom-control-out")
        zoomOutButton.title = "−"
        zoomOutButton.toolTip = "Zoom Out (−)"
        zoomOutButton.target = self
        zoomOutButton.action = #selector(handleZoomOut(_:))
        zoomOutButton.isBordered = false
        zoomOutButton.setAccessibilityLabel("Zoom out")
        addSubview(zoomOutButton)

        resetButton.identifier = NSUserInterfaceItemIdentifier("zoom-control-reset")
        resetButton.title = "100%"
        resetButton.usesMonospaceTitle = true
        resetButton.toolTip = "Actual Size (⌘0) · Press ⇧1 to Zoom to Fit"
        resetButton.target = self
        resetButton.action = #selector(handleResetZoom(_:))
        resetButton.isBordered = false
        resetButton.setAccessibilityLabel("Zoom level 100 percent, click for actual size")
        addSubview(resetButton)

        zoomInButton.identifier = NSUserInterfaceItemIdentifier("zoom-control-in")
        zoomInButton.title = "+"
        zoomInButton.toolTip = "Zoom In (+)"
        zoomInButton.target = self
        zoomInButton.action = #selector(handleZoomIn(_:))
        zoomInButton.isBordered = false
        zoomInButton.setAccessibilityLabel("Zoom in")
        addSubview(zoomInButton)

        layoutControls(compact: false)
    }

    public func update(zoomScale: CGFloat, compact: Bool) {
        let percent = max(10, Int((zoomScale * 100).rounded()))
        let label = "\(percent)%"
        if resetButton.title != label {
            resetButton.title = label
            resetButton.setAccessibilityLabel("Zoom level \(percent) percent, click for actual size")
            resetButton.needsDisplay = true
        }
        // Keep zoom readout visually calm so Acid Lime remains reserved for active tools.
        resetButton.isActiveTool = false
        zoomOutButton.isEnabled = zoomScale > 0.105
        zoomInButton.isEnabled = zoomScale < 3.995
        if compact != isCompact {
            layoutControls(compact: compact)
        }
    }

    private func layoutControls(compact: Bool) {
        isCompact = compact
        let h: CGFloat = 34
        let y: CGFloat = 6
        if compact {
            zoomOutButton.isHidden = true
            zoomInButton.isHidden = true
            resetButton.frame = NSRect(x: 6, y: y, width: 48, height: h)
            setFrameSize(NSSize(width: 60, height: 46))
        } else {
            zoomOutButton.isHidden = false
            zoomInButton.isHidden = false
            zoomOutButton.frame = NSRect(x: 6, y: y, width: 28, height: h)
            resetButton.frame = NSRect(x: 38, y: y, width: 52, height: h)
            zoomInButton.frame = NSRect(x: 94, y: y, width: 28, height: h)
            setFrameSize(NSSize(width: 128, height: 46))
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
    }

    @objc private func handleZoomOut(_ sender: Any?) { onZoomOut?() }
    @objc private func handleResetZoom(_ sender: Any?) { onResetZoom?() }
    @objc private func handleZoomIn(_ sender: Any?) { onZoomIn?() }
}

@MainActor
public final class CanvasStatusBannerView: NSView {
    public enum BannerKind: Equatable {
        case conflict(CanvasConflictReason)
        case readOnly(String)
        case saveError(String, canRetry: Bool)
        case recoveryError(String)
        case v1CodeNotice(String)
        case importError(String)
    }

    public private(set) var activeKind: BannerKind?
    public var onSaveAs: (() -> Void)?
    public var onSaveVersion2Copy: (() -> Void)?
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
        CanvasFloatingElevation.apply(to: self)
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
            saveAsButton.title = "Save As…"
            saveAsButton.identifier = NSUserInterfaceItemIdentifier("banner-save-as")
            dismissButton.title = "Dismiss"
            dismissButton.identifier = NSUserInterfaceItemIdentifier("banner-dismiss")
        case .v1CodeNotice(let message):
            titleLabel.stringValue = "VERSION 1 CANVAS · CODE REQUIRES VERSION 2"
            detailLabel.stringValue = message
            saveAsButton.title = "Save v2 Copy…"
            saveAsButton.identifier = NSUserInterfaceItemIdentifier("banner-save-v2-copy")
            dismissButton.title = "Dismiss"
            dismissButton.identifier = NSUserInterfaceItemIdentifier("banner-dismiss")
        case .importError(let message):
            titleLabel.stringValue = "CANNOT ATTACH FILE"
            detailLabel.stringValue = message
            saveAsButton.isHidden = true
            dismissButton.title = "Dismiss"
            dismissButton.identifier = NSUserInterfaceItemIdentifier("banner-dismiss")
        }
        if case .v1CodeNotice = kind {
            // saveAsButton already titled "Save v2 Copy…"
        } else if case .importError = kind {
            // saveAsButton stays hidden
        } else {
            saveAsButton.title = "Save As…"
            saveAsButton.identifier = NSUserInterfaceItemIdentifier("banner-save-as")
        }
        layoutControls()
        needsDisplay = true
    }

    public func layoutControls(maxWidth: CGFloat = 760) {
        let width = max(360, min(maxWidth, 760))
        let height: CGFloat = 52
        setFrameSize(NSSize(width: width, height: height))

        var rightX = width - 10
        let buttonY: CGFloat = 12
        let buttonH: CGFloat = 28

        for button in [dismissButton, reloadButton, saveAsButton, retryButton] where !button.isHidden {
            let btnWidth = max(68, ceil((button.title as NSString).size(withAttributes: [
                .font: CanvasTypography.font("sans", "s", scale: 11.5 / 14.0)
            ]).width) + 14)
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
        case .saveError, .recoveryError, .importError:
            bg = CanvasTheme.red
        case .v1CodeNotice:
            bg = CanvasTheme.acid
        }
        bg.setFill()
        bounds.fill()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        CanvasTheme.borderStrong.setStroke()
        border.stroke()
    }

    @objc private func handleSaveAs(_ sender: Any?) {
        if case .v1CodeNotice = activeKind {
            onSaveVersion2Copy?()
        } else {
            onSaveAs?()
        }
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
private final class NeoAcidKeycapView: NSView {
    private let text: String
    private let font: NSFont

    override var isFlipped: Bool { true }

    init(frame: NSRect, text: String, font: NSFont) {
        self.text = text
        self.font = font
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("NeoAcidKeycapView does not support NSCoder")
    }

    override func draw(_ dirtyRect: NSRect) {
        CanvasTheme.surface.setFill()
        bounds.fill()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1.0
        CanvasTheme.borderSubtle.setStroke()
        border.stroke()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CanvasTheme.primaryText,
            .paragraphStyle: paragraph,
        ]
        let ns = text as NSString
        let size = ns.size(withAttributes: attrs)
        ns.draw(
            in: CGRect(x: 0, y: floor((bounds.height - size.height) / 2.0), width: bounds.width, height: size.height + 2),
            withAttributes: attrs
        )
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
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 504),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.appearance = NSAppearance(named: .aqua)
        panel.title = "Keyboard & Pointer Shortcuts"
        panel.identifier = NSUserInterfaceItemIdentifier("shortcuts-sheet")
        panel.isReleasedWhenClosed = false
        self.panel = panel
        super.init()
        buildContent()
    }

    private func buildContent() {
        let sheetWidth: CGFloat = 740
        let sheetHeight: CGFloat = 504
        let content = NSView(frame: NSRect(x: 0, y: 0, width: sheetWidth, height: sheetHeight))
        content.wantsLayer = true
        content.layer?.backgroundColor = CanvasTheme.canvasBackground.cgColor

        let header = NSTextField(labelWithString: "Keyboard & Pointer Reference")
        header.identifier = NSUserInterfaceItemIdentifier("shortcuts-header")
        header.font = CanvasTypography.font("heading", "m", scale: 18.0 / 16.0)
        header.textColor = CanvasTheme.primaryText
        header.frame = NSRect(x: 24, y: sheetHeight - 48, width: sheetWidth - 48, height: 26)
        content.addSubview(header)

        let subtitle = NSTextField(labelWithString: "Single-key shortcuts apply when the canvas is focused outside an active text or code editor.")
        subtitle.font = CanvasTypography.font("sans", "s", scale: 12.0 / 14.0)
        subtitle.textColor = CanvasTheme.secondaryText
        subtitle.frame = NSRect(x: 24, y: sheetHeight - 72, width: sheetWidth - 48, height: 18)
        content.addSubview(subtitle)

        let sections: [(String, [(String, String)])] = [
            ("CREATE & CONNECT", [
                ("V / Esc", "Select tool / cancel active mode"),
                ("R O D I T", "Rect, Ellipse, Diamond, Triangle, Text"),
                ("L / A / K", "Line, Arrow, or v2 Code Block"),
                ("N → Arrows", "Adjacent thought along cardinal ray"),
                ("C / Port drag", "Create or edit bound connection"),
                ("Drop file", "Attach UTF-8 text file card"),
            ]),
            ("SELECT & VIEWPORT", [
                ("Tab / ⇧Tab", "Traverse objects and connections"),
                ("Space", "Tap to toggle focus · Hold+drag to pan"),
                ("Arrows", "Move by 1 unit (⇧Arrows: 10 units)"),
                ("+ − ⇧1 ⌘0", "Zoom in, zoom out, fit, actual size"),
                ("⌘A / Drag", "Select all or marquee box-select"),
            ]),
            ("EDIT & GEOMETRY", [
                ("Return / 2×Click", "Edit text, code, edge, or preview file"),
                ("G → Tab/Arrows", "Resize, rotate, or move line ends"),
                ("S", "Toggle floating Style inspector"),
                ("⌘L · ⇧⌘] / [", "Lock/unlock · Bring Front / Send Back"),
                ("⌥⌘Arrows", "Align edges (⌃⌘H·V center, ⇧ dist.)"),
                ("⌘C ⌘X ⌘V ⌘D", "Copy, Cut, Paste, Duplicate"),
            ]),
            ("DOCUMENT & EXPORT", [
                ("⌘N / ⌘O", "New v2 canvas / Open JSON"),
                ("⌘S / ⇧⌘S", "Save JSON / Save As"),
                ("⇧⌘E", "Export transparent Keynote PNG"),
                ("⌘Z / ⇧⌘Z", "Undo / Redo"),
                ("? / ⌘/", "Show this keyboard reference"),
            ]),
        ]

        let colWidth: CGFloat = 338
        let rowHeight: CGFloat = 186
        let keyColWidth: CGFloat = 122
        for (idx, section) in sections.enumerated() {
            let col = idx % 2
            let row = idx / 2
            let cardX: CGFloat = 24 + CGFloat(col) * (colWidth + 16)
            let cardY: CGFloat = row == 0 ? 246 : 52
            let card = NSView(frame: NSRect(x: cardX, y: cardY, width: colWidth, height: rowHeight))
            card.wantsLayer = true
            card.layer?.backgroundColor = CanvasTheme.elevatedSurface.cgColor
            card.layer?.borderColor = CanvasTheme.borderStrong.cgColor
            card.layer?.borderWidth = 1.5

            let sectionTitle = NSTextField(labelWithString: section.0)
            sectionTitle.font = CanvasTypography.font("mono", "s", scale: 10.0 / 14.0)
            sectionTitle.textColor = CanvasTheme.mutedText
            sectionTitle.frame = NSRect(x: 12, y: rowHeight - 25, width: colWidth - 24, height: 16)
            card.addSubview(sectionTitle)

            var itemY = rowHeight - 50
            for (keys, desc) in section.1 {
                let keyFont = CanvasTypography.font("mono", "s", scale: 9.8 / 14.0)
                let measuredKeyW = ceil((keys as NSString).size(withAttributes: [.font: keyFont]).width) + 12
                let chipW = min(keyColWidth, max(26, measuredKeyW))
                let chip = NeoAcidKeycapView(
                    frame: NSRect(x: 12, y: itemY - 2, width: chipW, height: 18),
                    text: keys,
                    font: keyFont
                )
                card.addSubview(chip)

                let descLabel = NSTextField(labelWithString: desc)
                descLabel.font = CanvasTypography.font("sans", "s", scale: 11.0 / 14.0)
                descLabel.textColor = CanvasTheme.secondaryText
                descLabel.lineBreakMode = .byTruncatingTail
                descLabel.frame = NSRect(x: 12 + keyColWidth + 8, y: itemY - 1, width: colWidth - 32 - keyColWidth, height: 16)
                card.addSubview(descLabel)

                itemY -= 23
            }
            content.addSubview(card)
        }

        let closeButton = NeoAcidActionButton(title: "Done", variant: .primary, target: self, action: #selector(closeSheet(_:)))
        closeButton.identifier = NSUserInterfaceItemIdentifier("shortcuts-close")
        closeButton.keyEquivalent = "\r"
        closeButton.frame = NSRect(x: sheetWidth - 24 - 84, y: 12, width: 84, height: 30)
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
