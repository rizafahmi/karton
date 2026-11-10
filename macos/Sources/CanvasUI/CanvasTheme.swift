import AppKit

/// Neo-Acid light-first color tokens for canvas rendering and the Welcome surface,
/// paired with native AppKit Aqua controls.
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

    /// Maps portable JSON color names to the light-mode Neo-Acid canvas palette.
    public static func palette(_ name: String) -> NSColor {
        switch name {
        case "none": return .clear
        case "surface": return surface
        case "accent": return acid
        case "gray": return gray
        case "blue": return sky
        case "green": return mint
        case "yellow": return yellow
        case "red": return red
        case "violet": return violet
        case "ink": return primaryText
        default: return primaryText
        }
    }

    /// Enforces the Highlighter Ink Rule: light/unfilled surfaces and highlighter
    /// swatches use Ebony Ink (`#0a0b0d`), while `ink` fills use elevated white (`#ffffff`).
    public static func textColor(onFill fill: String) -> NSColor {
        lightFillNames.contains(fill) ? highlighterInk : elevatedSurface
    }

    private static func srgb(_ red: UInt8, _ green: UInt8, _ blue: UInt8, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat(red) / 255.0,
            green: CGFloat(green) / 255.0,
            blue: CGFloat(blue) / 255.0,
            alpha: alpha
        )
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
        let kicker = "LOCAL-FIRST · V1/V2 JSON" as NSString
        kicker.draw(
            at: CGPoint(x: 96, y: 39),
            withAttributes: [
                .font: CanvasTypography.font("mono", "l", scale: 11.0 / 24.0),
                .foregroundColor: CanvasTheme.mutedText,
            ]
        )

        let headline = NSMutableAttributedString(
            string: "Elixir Canvas ",
            attributes: [
                .font: CanvasTypography.font("heading", "m", scale: 22.0 / 16.0),
                .foregroundColor: CanvasTheme.primaryText,
            ]
        )
        headline.append(
            NSAttributedString(
                string: "Local spatial thinking.",
                attributes: [
                    .font: CanvasTypography.font("heading", "m", scale: 22.0 / 16.0),
                    .foregroundColor: CanvasTheme.mutedText,
                ]
            )
        )
        headline.draw(at: CGPoint(x: 32, y: 84))

        let summary =
            "Create a blank version-2 canvas or open an existing JSON document.\nConnected files autosave safely; untitled work is recoverable across launches."
            as NSString
        summary.draw(
            in: CGRect(x: 32, y: 122, width: bounds.width - 64, height: 52),
            withAttributes: [
                .font: CanvasTypography.font("sans", "m", scale: 13.0 / 16.0),
                .foregroundColor: CanvasTheme.secondaryText,
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
