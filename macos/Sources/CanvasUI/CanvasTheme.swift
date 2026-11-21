import AppKit

/// Target Keynote slide theme for transparent PNG export.
/// Exported PNGs always preserve true alpha transparency; the theme selects
/// light-slide (dark ink) or dark-slide (light ink) semantic palette resolution
/// without modifying document JSON or the light-first editor chrome.
public enum CanvasPNGExportTheme: String, Equatable, Sendable, CaseIterable {
    case light
    case dark

    public var displayTitle: String {
        switch self {
        case .light: return "Light slides (dark ink)"
        case .dark: return "Dark slides (light ink)"
        }
    }

    public var summaryNote: String {
        switch self {
        case .light: return "Dark ink for light slides"
        case .dark: return "Light ink for dark slides"
        }
    }

    public static let userDefaultsKey = "local.elixircanvas.native.pngExportTheme"

    public static func loadDefault(from defaults: UserDefaults = .standard) -> CanvasPNGExportTheme {
        guard let raw = defaults.string(forKey: userDefaultsKey),
              let theme = CanvasPNGExportTheme(rawValue: raw) else {
            return .light
        }
        return theme
    }

    public func saveDefault(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.userDefaultsKey)
    }
}

/// Neo-Acid light-first color tokens for canvas rendering and the Welcome surface,
/// paired with native AppKit Aqua controls and optional dark-slide PNG export tokens.
public enum CanvasTheme {
    // MARK: - Base Light Surfaces & Ink (DESIGN.md §2)

    /// Raw Gallery Plaster (`#f7f7f5` / `--bg-canvas`)
    public static let canvasBackground = srgb(0xF7, 0xF7, 0xF5)

    /// Plaster Alt (`#ecece6` / `--bg-surface`)
    public static let surface = srgb(0xEC, 0xEC, 0xE6)

    /// Elevated White (`#ffffff` / `--bg-elevated`)
    public static let elevatedSurface = srgb(0xFF, 0xFF, 0xFF)

    /// Ebony Ink (`#0a0b0d` / `--text-primary`)
    public static let primaryText = srgb(0x0A, 0x0B, 0x0D)

    /// Secondary Ink (`#3f454d` / `--text-secondary`)
    public static let secondaryText = srgb(0x3F, 0x45, 0x4D)

    /// Slate Light (`#6e7882` / `--text-muted`)
    public static let mutedText = srgb(0x6E, 0x78, 0x82)

    /// Strong border (`#0a0b0d` / `--border-strong-color`)
    public static let borderStrong = srgb(0x0A, 0x0B, 0x0D)

    /// Subtle border (`#d8dad3` / `--border-subtle-color`)
    public static let borderSubtle = srgb(0xD8, 0xDA, 0xD3)

    /// Ebony Ink (`#0a0b0d` / `--hl-ink`) — pinned text color on light/highlighter fills
    public static let highlighterInk = srgb(0x0A, 0x0B, 0x0D)

    // MARK: - Obsidian Dark-Slide Export Tokens (DESIGN.md §2)

    /// Obsidian Clay (`#121519` / `--raw-obsidian`) — simulated dark slide backdrop
    public static let darkCanvasBackground = srgb(0x12, 0x15, 0x19)

    /// Obsidian Surface (`#1b2026` / `--raw-obsidian-alt`)
    public static let darkSurface = srgb(0x1B, 0x20, 0x26)

    /// Obsidian Elevated (`#222831` / `--raw-obsidian-elevated`) — dark `surface` fill & edge label pills
    public static let darkElevatedSurface = srgb(0x22, 0x28, 0x31)

    /// Silver White (`#e7ecf2` / `--raw-silver`) — dark `ink` strokes, fills, and unfilled text
    public static let darkPrimaryText = srgb(0xE7, 0xEC, 0xF2)

    /// Obsidian Strong Border (`#434a56` / `--border-strong-color` in dark mode) — dark `gray` fill/stroke & pill border
    public static let darkBorderStrong = srgb(0x43, 0x4A, 0x56)

    /// Obsidian Subtle Border (`#262c36` / `--border-subtle-color` in dark mode)
    public static let darkBorderSubtle = srgb(0x26, 0x2C, 0x36)

    // MARK: - Semantic Highlighter & Accent Swatches

    /// Acid (`#c5f82a` / `--hl-acid`)
    public static let acid = srgb(0xC5, 0xF8, 0x2A)

    /// Violet (`#a984ff` / `--hl-violet`)
    public static let violet = srgb(0xA9, 0x84, 0xFF)

    /// Mint (`#5ae67a` / `--hl-mint`)
    public static let mint = srgb(0x5A, 0xE6, 0x7A)

    /// Sky (`#8ce0ff` / `--hl-sky`)
    public static let sky = srgb(0x8C, 0xE0, 0xFF)

    /// Magenta (`#ff6ed4` / `--hl-magenta`)
    public static let magenta = srgb(0xFF, 0x6E, 0xD4)

    /// Yellow (`#ffe66d` / `--hakushi-shape-yellow`)
    public static let yellow = srgb(0xFF, 0xE6, 0x6D)

    /// Red (`#ff7770` / `--hakushi-shape-red`)
    public static let red = srgb(0xFF, 0x77, 0x70)

    /// Gray (`#d8dad3` / `--hakushi-shape-gray`)
    public static let gray = srgb(0xD8, 0xDA, 0xD3)

    /// Cobalt (`#1a3bf5` / `--accent-cobalt`)
    public static let selectionCobalt = srgb(0x1A, 0x3B, 0xF5)

    private static let lightFillNames: Set<String> = [
        "none", "surface", "accent", "gray", "blue", "green", "yellow", "red", "violet"
    ]

    private static let darkBackgroundFillNames: Set<String> = [
        "none", "surface", "gray"
    ]

    /// Maps portable JSON color names to the requested Neo-Acid canvas palette.
    public static func palette(_ name: String, theme: CanvasPNGExportTheme = .light) -> NSColor {
        switch name {
        case "none": return .clear
        case "surface": return theme == .dark ? darkElevatedSurface : surface
        case "accent": return acid
        case "gray": return theme == .dark ? darkBorderStrong : gray
        case "blue": return sky
        case "green": return mint
        case "yellow": return yellow
        case "red": return red
        case "violet": return violet
        case "ink": return theme == .dark ? darkPrimaryText : primaryText
        default: return theme == .dark ? darkPrimaryText : primaryText
        }
    }

    /// Enforces the Highlighter Ink Rule across light and dark export themes:
    /// - Highlighter swatches always pin Ebony Ink (`#0a0b0d`).
    /// - In light theme, unfilled/surface/gray use Ebony Ink and `ink` fills use white.
    /// - In dark theme, unfilled/surface/gray use Silver White (`#e7ecf2`) and `ink` fills
    ///   (which resolve to Silver White) use Ebony Ink (`#0a0b0d`).
    public static func textColor(onFill fill: String, theme: CanvasPNGExportTheme = .light) -> NSColor {
        switch theme {
        case .light:
            return lightFillNames.contains(fill) ? highlighterInk : elevatedSurface
        case .dark:
            return darkBackgroundFillNames.contains(fill) ? darkPrimaryText : highlighterInk
        }
    }

    public static func edgeLabelFill(theme: CanvasPNGExportTheme = .light) -> NSColor {
        theme == .dark ? darkElevatedSurface : elevatedSurface
    }

    public static func edgeLabelBorder(theme: CanvasPNGExportTheme = .light) -> NSColor {
        theme == .dark ? darkBorderStrong : borderSubtle
    }

    public static func edgeLabelText(theme: CanvasPNGExportTheme = .light) -> NSColor {
        theme == .dark ? darkPrimaryText : primaryText
    }

    public static func previewBackdrop(theme: CanvasPNGExportTheme) -> NSColor {
        theme == .dark ? darkCanvasBackground : canvasBackground
    }

    private static func srgb(_ red: UInt8, _ green: UInt8, _ blue: UInt8, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255.0,
            green: CGFloat(green) / 255.0,
            blue: CGFloat(blue) / 255.0,
            alpha: alpha
        )
    }

    /// Renders the Neo-Acid Canvas brand badge (`36×36` Acid Lime `#c5f82a` square with
    /// Ebony Ink `#0a0b0d` border, two connected nodes, and orthogonal connector) into an
    /// explicit-pixel sRGB PNG at `pixelSize × pixelSize`.
    public static func appIconPNGData(pixelSize: Int = 512) -> Data? {
        guard pixelSize > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: pixelSize,
                  height: pixelSize,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        let scale = CGFloat(pixelSize) / 36.0
        ctx.translateBy(x: 0, y: CGFloat(pixelSize))
        ctx.scaleBy(x: scale, y: -scale)

        let badge = CGRect(x: 0, y: 0, width: 36, height: 36)
        ctx.setFillColor(acid.cgColor)
        ctx.fill(badge)

        ctx.setStrokeColor(borderStrong.cgColor)
        ctx.setLineWidth(2)
        ctx.setLineJoin(.miter)
        ctx.setLineCap(.butt)
        ctx.stroke(badge.insetBy(dx: 1, dy: 1))

        ctx.setStrokeColor(highlighterInk.cgColor)
        ctx.setLineWidth(2)
        ctx.stroke(CGRect(x: 8, y: 8, width: 8, height: 8))
        ctx.stroke(CGRect(x: 20, y: 20, width: 8, height: 8))

        ctx.beginPath()
        ctx.move(to: CGPoint(x: 16, y: 12))
        ctx.addLine(to: CGPoint(x: 24, y: 12))
        ctx.addLine(to: CGPoint(x: 24, y: 20))
        ctx.strokePath()

        guard let cgImage = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage).retagging(with: .sRGB) ?? NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }
    public static func appIconImage(pixelSize: Int = 512) -> NSImage? {
        guard let data = appIconPNGData(pixelSize: pixelSize) else { return nil }
        return NSImage(data: data)
    }
}

public final class WelcomeContentView: NSView {
    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        CanvasTheme.canvasBackground.setFill()
        bounds.fill()

        let footerHeight: CGFloat = 68
        let bodyHeight = bounds.height - footerHeight
        CanvasTheme.mutedText.withAlphaComponent(0.32).setFill()
        var x: CGFloat = 20
        while x < bounds.width {
            var y: CGFloat = 20
            while y < bodyHeight {
                NSBezierPath(ovalIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)).fill()
                y += 20
            }
            x += 20
        }

        let badge = CGRect(x: 32, y: 28, width: 36, height: 36)
        CanvasTheme.acid.setFill()
        badge.fill()
        let badgeBorder = NSBezierPath(rect: badge.insetBy(dx: 1, dy: 1))
        badgeBorder.lineWidth = 2
        CanvasTheme.borderStrong.setStroke()
        badgeBorder.stroke()
        let glyph = NSBezierPath()
        glyph.appendRect(CGRect(x: badge.minX + 8, y: badge.minY + 8, width: 8, height: 8))
        glyph.appendRect(CGRect(x: badge.maxX - 16, y: badge.maxY - 16, width: 8, height: 8))
        glyph.move(to: CGPoint(x: badge.minX + 16, y: badge.minY + 12))
        glyph.line(to: CGPoint(x: badge.maxX - 12, y: badge.minY + 12))
        glyph.line(to: CGPoint(x: badge.maxX - 12, y: badge.maxY - 16))
        glyph.lineWidth = 2
        CanvasTheme.highlighterInk.setStroke()
        glyph.stroke()

        let dot = CGRect(x: 82, y: 42, width: 8, height: 8)
        CanvasTheme.mint.setFill()
        dot.fill()
        let dotBorder = NSBezierPath(rect: dot)
        dotBorder.lineWidth = 1
        CanvasTheme.borderStrong.setStroke()
        dotBorder.stroke()
        let kicker = "LOCAL-FIRST · .KARTON / JSON" as NSString
        kicker.draw(
            at: CGPoint(x: 96, y: 39),
            withAttributes: [
                .font: CanvasTypography.font("mono", "l", scale: 11.0 / 24.0),
                .foregroundColor: CanvasTheme.mutedText,
            ]
        )

        let title = "Karton" as NSString
        title.draw(
            in: CGRect(x: 32, y: 78, width: bounds.width - 64, height: 30),
            withAttributes: [
                .font: CanvasTypography.font("heading", "m", scale: 22.0 / 16.0),
                .foregroundColor: CanvasTheme.primaryText,
            ]
        )

        let subtitle = "Local spatial thinking." as NSString
        subtitle.draw(
            in: CGRect(x: 32, y: 110, width: bounds.width - 64, height: 22),
            withAttributes: [
                .font: CanvasTypography.font("sans", "l", scale: 15.0 / 24.0),
                .foregroundColor: CanvasTheme.mutedText,
            ]
        )

        let summaryStyle = NSMutableParagraphStyle()
        summaryStyle.lineSpacing = 2.5
        let summary =
            "Create a blank .karton board or open an existing .karton / .json file.\nConnected files autosave safely; untitled work recovers across launches."
            as NSString
        summary.draw(
            in: CGRect(x: 32, y: 138, width: bounds.width - 64, height: 54),
            withAttributes: [
                .font: CanvasTypography.font("sans", "m", scale: 13.0 / 16.0),
                .foregroundColor: CanvasTheme.secondaryText,
                .paragraphStyle: summaryStyle,
            ]
        )

        let footer = CGRect(x: 0, y: bodyHeight, width: bounds.width, height: footerHeight)
        CanvasTheme.surface.setFill()
        footer.fill()
        let divider = NSBezierPath()
        divider.move(to: CGPoint(x: 0, y: bodyHeight))
        divider.line(to: CGPoint(x: bounds.width, y: bodyHeight))
        divider.lineWidth = 2
        CanvasTheme.borderStrong.setStroke()
        divider.stroke()
    }
}

public final class AboutContentView: NSView {
    private let versionLabel: String

    public override var isFlipped: Bool { true }

    public init(frame: NSRect, versionLabel: String) {
        self.versionLabel = versionLabel
        super.init(frame: frame)
    }

    public required init?(coder: NSCoder) {
        fatalError("AboutContentView does not support NSCoder")
    }

    public override func draw(_ dirtyRect: NSRect) {
        CanvasTheme.canvasBackground.setFill()
        bounds.fill()

        let footerHeight: CGFloat = 44
        let bodyHeight = bounds.height - footerHeight

        // Subtle Neo-Acid dot grid in body
        CanvasTheme.mutedText.withAlphaComponent(0.28).setFill()
        var x: CGFloat = 20
        while x < bounds.width {
            var y: CGFloat = 20
            while y < bodyHeight {
                NSBezierPath(ovalIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)).fill()
                y += 20
            }
            x += 20
        }

        // 48×48 Neo-Acid brand badge centered
        let badgeSize: CGFloat = 48
        let badge = CGRect(x: floor((bounds.width - badgeSize) / 2), y: 24, width: badgeSize, height: badgeSize)
        CanvasTheme.acid.setFill()
        badge.fill()
        let badgeBorder = NSBezierPath(rect: badge.insetBy(dx: 1, dy: 1))
        badgeBorder.lineWidth = 2
        CanvasTheme.borderStrong.setStroke()
        badgeBorder.stroke()

        let scale = badgeSize / 36.0
        let glyph = NSBezierPath()
        glyph.appendRect(CGRect(x: badge.minX + 8 * scale, y: badge.minY + 8 * scale, width: 8 * scale, height: 8 * scale))
        glyph.appendRect(CGRect(x: badge.minX + 20 * scale, y: badge.minY + 20 * scale, width: 8 * scale, height: 8 * scale))
        glyph.move(to: CGPoint(x: badge.minX + 16 * scale, y: badge.minY + 12 * scale))
        glyph.line(to: CGPoint(x: badge.minX + 24 * scale, y: badge.minY + 12 * scale))
        glyph.line(to: CGPoint(x: badge.minX + 24 * scale, y: badge.minY + 20 * scale))
        glyph.lineWidth = 2.2
        CanvasTheme.highlighterInk.setStroke()
        glyph.stroke()

        let centerStyle = NSMutableParagraphStyle()
        centerStyle.alignment = .center

        let title = "Karton" as NSString
        title.draw(
            in: CGRect(x: 24, y: 84, width: bounds.width - 48, height: 28),
            withAttributes: [
                .font: CanvasTypography.font("heading", "m", scale: 20.0 / 16.0),
                .foregroundColor: CanvasTheme.primaryText,
                .paragraphStyle: centerStyle,
            ]
        )

        // Version badge chip (strip redundant "Karton " / "Canvas " prefix below the heading)
        let displayVersion: String
        if versionLabel.hasPrefix("Karton ") {
            displayVersion = "VERSION " + versionLabel.dropFirst("Karton ".count)
        } else if versionLabel.hasPrefix("Canvas ") {
            displayVersion = "VERSION " + versionLabel.dropFirst("Canvas ".count)
        } else {
            displayVersion = versionLabel
        }
        let versionAttrs: [NSAttributedString.Key: Any] = [
            .font: CanvasTypography.font("mono", "s", scale: 10.5 / 14.0),
            .foregroundColor: CanvasTheme.primaryText,
            .paragraphStyle: centerStyle,
        ]
        let versionStr = displayVersion as NSString
        let vw = ceil(versionStr.size(withAttributes: versionAttrs).width) + 20
        let vChip = CGRect(x: floor((bounds.width - vw) / 2), y: 116, width: vw, height: 22)
        CanvasTheme.elevatedSurface.setFill()
        vChip.fill()
        let vBorder = NSBezierPath(rect: vChip.insetBy(dx: 0.75, dy: 0.75))
        vBorder.lineWidth = 1.25
        CanvasTheme.borderStrong.setStroke()
        vBorder.stroke()
        versionStr.draw(in: CGRect(x: vChip.minX, y: vChip.minY + 4, width: vChip.width, height: 16), withAttributes: versionAttrs)

        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.alignment = .center
        bodyStyle.lineSpacing = 3
        let desc = "Local-first spatial thinking for macOS.\nPortable .karton & JSON files, highlighted code,\ntext attachments, and Keynote PNG export." as NSString
        desc.draw(
            in: CGRect(x: 24, y: 150, width: bounds.width - 48, height: 74),
            withAttributes: [
                .font: CanvasTypography.font("sans", "m", scale: 12.5 / 16.0),
                .foregroundColor: CanvasTheme.secondaryText,
                .paragraphStyle: bodyStyle,
            ]
        )

        let footer = CGRect(x: 0, y: bodyHeight, width: bounds.width, height: footerHeight)
        CanvasTheme.surface.setFill()
        footer.fill()
        let divider = NSBezierPath()
        divider.move(to: CGPoint(x: 0, y: bodyHeight))
        divider.line(to: CGPoint(x: bounds.width, y: bodyHeight))
        divider.lineWidth = 1.5
        CanvasTheme.borderStrong.setStroke()
        divider.stroke()

        let foot = "NEO-ACID × LEVER  ·  NATIVE APPKIT" as NSString
        foot.draw(
            in: CGRect(x: 20, y: bodyHeight + 14, width: bounds.width - 40, height: 16),
            withAttributes: [
                .font: CanvasTypography.font("mono", "s", scale: 10.0 / 14.0),
                .foregroundColor: CanvasTheme.mutedText,
                .paragraphStyle: centerStyle,
            ]
        )
    }
}
