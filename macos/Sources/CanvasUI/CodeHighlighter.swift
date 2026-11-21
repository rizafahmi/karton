import AppKit
import CanvasCore
import Highlighter
import JavaScriptCore

public struct CanvasHighlightedTokenRun: Equatable, Sendable {
    public let location: Int
    public let length: Int
    public let color: NSColor

    public var range: NSRange { NSRange(location: location, length: length) }
}

public struct CanvasHighlightedCode: Equatable, Sendable {
    public let runs: [CanvasHighlightedTokenRun]
    public let detectedLanguage: CanvasCodeLanguage?
    public let effectiveLanguage: CanvasCodeLanguage?
    public let isDarkTheme: Bool
    public let usedFallback: Bool
}

/// Native syntax highlighter and conservative Auto detector backed by `HighlighterSwift`
/// (`Highlight.js` via system `JavaScriptCore`, no webview).
///
/// Preserves literal UTF-8 source bytes: if highlighting fails or alters any character,
/// falls back cleanly to plain text with `usedFallback = true`.
@MainActor
public final class CanvasCodeHighlighter {
    public static let shared = CanvasCodeHighlighter()

    private struct CacheKey: Hashable {
        let source: String
        let language: String?
        let isDark: Bool
    }

    private var lightHighlighter: Highlighter?
    private var darkHighlighter: Highlighter?
    private var lightBaseSRGB: NSColor?
    private var darkBaseSRGB: NSColor?
    private var detectorHLJS: JSValue?
    private var didInitLight = false
    private var didInitDark = false
    private var didInitDetector = false
    private var cache: [CacheKey: CanvasHighlightedCode] = [:]
    private var cacheOrder: [CacheKey] = []
    private var detectCache: [String: CanvasCodeLanguage?] = [:]
    private var detectCacheOrder: [String] = []
    private let maxCacheEntries = 256

    public var isLightEngineLoaded: Bool { didInitLight && lightHighlighter != nil }
    public var isDarkEngineLoaded: Bool { didInitDark && darkHighlighter != nil }
    public var isDetectorLoaded: Bool { didInitDetector && detectorHLJS != nil }

    public var isAvailable: Bool {
        if didInitLight {
            return lightHighlighter != nil
        }
        return Self.locateHighlightMinJS() != nil
    }

    /// Lightweight initializer: defers `HighlighterSwift`/`JavaScriptCore` VM startup
    /// per engine (light, dark, auto-detector) until first actual code highlighting or detection.
    public init() {}

    private func ensureLightHighlighter() -> Highlighter? {
        if !didInitLight {
            didInitLight = true
            let light = Highlighter()
            light?.ignoreIllegals = true
            _ = light?.setTheme("github")
            lightHighlighter = light
            lightBaseSRGB = Self.sampleBaseColor(light)
        }
        return lightHighlighter
    }

    private func ensureDarkHighlighter() -> Highlighter? {
        if !didInitDark {
            didInitDark = true
            let dark = Highlighter()
            dark?.ignoreIllegals = true
            _ = dark?.setTheme("github-dark")
            darkHighlighter = dark
            darkBaseSRGB = Self.sampleBaseColor(dark)
        }
        return darkHighlighter
    }

    private func ensureDetectorHLJS() -> JSValue? {
        if !didInitDetector {
            didInitDetector = true
            detectorHLJS = Self.makeDetectorHLJS()
        }
        return detectorHLJS
    }

    private static func sampleBaseColor(_ engine: Highlighter?) -> NSColor? {
        guard let sample = engine?.highlight(" ", as: "elixir", doFastRender: true),
              sample.length > 0,
              let color = sample.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor else {
            return nil
        }
        return color.usingColorSpace(.sRGB)
    }

    /// Returns whether a code block with the given fill and slide theme should use dark token colors,
    /// matching `CanvasTheme.textColor(onFill:theme:)` polarity across light and dark Keynote slides.
    public static func usesDarkTokenPalette(fill: String, theme: CanvasPNGExportTheme = .light) -> Bool {
        guard let srgb = CanvasTheme.textColor(onFill: fill, theme: theme).usingColorSpace(.sRGB) else {
            return fill == "ink"
        }
        let luma = 0.2126 * srgb.redComponent + 0.7152 * srgb.greenComponent + 0.0722 * srgb.blueComponent
        return luma > 0.5
    }

    /// Runs conservative curated-subset Auto detection (`shared/CODE_SNIPPETS.md §3`).
    /// Requires `relevance >= 3` and `best >= 1.25 * secondBest`; otherwise returns `nil` (Plain text).
    public func detectLanguage(for source: String) -> CanvasCodeLanguage? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let cached = detectCache[source] {
            return cached
        }
        guard let hljs = ensureDetectorHLJS() else { return nil }
        let result = hljs.invokeMethod(
            "highlightAuto",
            withArguments: [source, CanvasCodeLanguage.detectableHighlightJSNames]
        )
        var detected: CanvasCodeLanguage? = nil
        if let result, !result.isUndefined, !result.isNull,
           let langVal = result.objectForKeyedSubscript("language"),
           !langVal.isUndefined, !langVal.isNull,
           let rawLang = langVal.toString(),
           let canonical = CanvasCodeLanguage.fromHighlightJS(rawLang) {
            let relevance = result.objectForKeyedSubscript("relevance")?.toInt32() ?? 0
            if relevance >= 3 {
                var passesMargin = true
                if let secondBest = result.objectForKeyedSubscript("secondBest"),
                   !secondBest.isUndefined, !secondBest.isNull {
                    let secondRelevance = secondBest.objectForKeyedSubscript("relevance")?.toInt32() ?? 0
                    if secondRelevance > 0 && Double(relevance) < 1.25 * Double(secondRelevance) {
                        passesMargin = false
                    }
                }
                if passesMargin {
                    detected = canonical
                }
            }
        }
        if detectCacheOrder.count >= maxCacheEntries, let oldest = detectCacheOrder.first {
            detectCacheOrder.removeFirst()
            detectCache.removeValue(forKey: oldest)
        }
        detectCache[source] = detected
        detectCacheOrder.append(source)
        return detected
    }

    /// Highlights `source` for the given stored `data.language` (`nil` or `"auto"` = Auto) and palette polarity.
    public func highlight(
        source: String,
        language storedLanguage: String?,
        isDark: Bool
    ) -> CanvasHighlightedCode {
        let key = CacheKey(source: source, language: storedLanguage, isDark: isDark)
        if let cached = cache[key] {
            return cached
        }

        let result = computeHighlight(source: source, storedLanguage: storedLanguage, isDark: isDark)
        if cacheOrder.count >= maxCacheEntries, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        cache[key] = result
        cacheOrder.append(key)
        return result
    }

    /// Produces a ready-to-draw `NSAttributedString` using bundled `Monaspace Neon` and cached token colors.
    public func attributedString(
        source: String,
        language storedLanguage: String?,
        size: String,
        fill: String,
        theme: CanvasPNGExportTheme = .light,
        scale: CGFloat = 1.0
    ) -> (attributed: NSAttributedString, result: CanvasHighlightedCode) {
        let isDark = Self.usesDarkTokenPalette(fill: fill, theme: theme)
        let result = highlight(source: source, language: storedLanguage, isDark: isDark)
        let monoFont = CanvasTypography.font("mono", size, scale: scale)
        let baseColor = CanvasTheme.textColor(onFill: fill, theme: theme)
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineBreakMode = .byWordWrapping

        let mutable = NSMutableAttributedString(
            string: source,
            attributes: [
                .font: monoFont,
                .foregroundColor: baseColor,
                .paragraphStyle: style,
            ]
        )
        let totalLength = mutable.length
        for run in result.runs {
            guard run.location >= 0, run.length > 0, run.location + run.length <= totalLength else {
                continue
            }
            mutable.addAttribute(.foregroundColor, value: run.color, range: run.range)
        }
        return (mutable, result)
    }

    /// Measures the full unwrapped-preferred box dimensions for **Fit to content**.
    public static func fittedBoxSize(for source: String, size: String) -> CGSize {
        let inset: CGFloat = 10
        let monoFont = CanvasTypography.font("mono", size)
        let display = source.isEmpty ? " " : source
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byClipping

        // Measure line-by-line max width so Fit expands horizontally to avoid unnecessary wrapping,
        // capped at a reasonable canvas width (1200) if a single line is huge.
        let maxUnwrappedWidth: CGFloat = 1200
        let natural = (display as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: monoFont, .paragraphStyle: paragraph]
        )
        let contentWidth = min(maxUnwrappedWidth, ceil(natural.width) + 4)
        let targetWidth = max(CGFloat(CanvasCodeSnippet.minWidth), contentWidth + inset * 2)

        // Now measure wrapped height at targetWidth so even >1200px lines never clip vertically.
        let wrapStyle = NSMutableParagraphStyle()
        wrapStyle.alignment = .left
        wrapStyle.lineBreakMode = .byWordWrapping
        let wrapped = (display as NSString).boundingRect(
            with: CGSize(width: max(1, targetWidth - inset * 2), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: monoFont, .paragraphStyle: wrapStyle]
        )
        let targetHeight = max(CGFloat(CanvasCodeSnippet.minHeight), ceil(wrapped.height) + 4 + inset * 2)
        return CGSize(width: targetWidth, height: targetHeight)
    }

    /// Returns `true` when `source` overflows the code block's interior box height at `size`.
    public static func hasClippedOverflow(source: String, box: CGRect, size: String) -> Bool {
        guard !source.isEmpty else { return false }
        let inset: CGFloat = 10
        let interiorWidth = max(1, box.width - inset * 2)
        let interiorHeight = max(1, box.height - inset * 2)
        let monoFont = CanvasTypography.font("mono", size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byWordWrapping
        let measured = (source as NSString).boundingRect(
            with: CGSize(width: interiorWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: monoFont, .paragraphStyle: paragraph]
        )
        return ceil(measured.height) > interiorHeight + 1
    }

    public func clearCache() {
        cache.removeAll()
        cacheOrder.removeAll()
        detectCache.removeAll()
        detectCacheOrder.removeAll()
    }

    private func computeHighlight(
        source: String,
        storedLanguage: String?,
        isDark: Bool
    ) -> CanvasHighlightedCode {
        guard !source.isEmpty else {
            let explicit = storedLanguage.flatMap(CanvasCodeLanguage.init(rawValue:))
            return CanvasHighlightedCode(
                runs: [],
                detectedLanguage: nil,
                effectiveLanguage: explicit == .auto ? nil : explicit,
                isDarkTheme: isDark,
                usedFallback: false
            )
        }

        let targetLanguage: CanvasCodeLanguage?
        let detectedLanguage: CanvasCodeLanguage?
        if storedLanguage == nil || storedLanguage == CanvasCodeLanguage.auto.rawValue {
            let detected = detectLanguage(for: source)
            detectedLanguage = detected
            targetLanguage = detected
        } else if let known = CanvasCodeLanguage(rawValue: storedLanguage!) {
            detectedLanguage = nil
            targetLanguage = known == .plaintext ? nil : known
        } else {
            // Unknown future language ID: preserve stored ID and render as plain text.
            detectedLanguage = nil
            targetLanguage = nil
        }

        guard let targetLanguage, let hljsName = targetLanguage.highlightJSName else {
            return CanvasHighlightedCode(
                runs: [],
                detectedLanguage: detectedLanguage,
                effectiveLanguage: targetLanguage,
                isDarkTheme: isDark,
                usedFallback: false
            )
        }

        guard let engine = isDark ? ensureDarkHighlighter() : ensureLightHighlighter(),
              let attributed = engine.highlight(source, as: hljsName, doFastRender: true),
              attributed.string == source else {
            return CanvasHighlightedCode(
                runs: [],
                detectedLanguage: detectedLanguage,
                effectiveLanguage: targetLanguage,
                isDarkTheme: isDark,
                usedFallback: true
            )
        }

        var runs: [CanvasHighlightedTokenRun] = []
        let fullRange = NSRange(location: 0, length: attributed.length)
        // Unclassified plain tokens inherit our Neo-Acid base text color (Ebony Ink on light, Silver White on dark).
        let themeBaseSRGB = isDark ? darkBaseSRGB : lightBaseSRGB
        attributed.enumerateAttribute(.foregroundColor, in: fullRange, options: []) { value, range, _ in
            guard range.length > 0, let color = value as? NSColor else { return }
            if let base = themeBaseSRGB, let candidate = color.usingColorSpace(.sRGB),
               abs(base.redComponent - candidate.redComponent) < 0.01,
               abs(base.greenComponent - candidate.greenComponent) < 0.01,
               abs(base.blueComponent - candidate.blueComponent) < 0.01 {
                return
            }
            runs.append(CanvasHighlightedTokenRun(location: range.location, length: range.length, color: color))
        }
        return CanvasHighlightedCode(
            runs: runs,
            detectedLanguage: detectedLanguage,
            effectiveLanguage: targetLanguage,
            isDarkTheme: isDark,
            usedFallback: false
        )
    }

    private static func makeDetectorHLJS() -> JSValue? {
        guard let jsPath = locateHighlightMinJS(),
              let script = try? String(contentsOfFile: jsPath, encoding: .utf8),
              let context = JSContext() else {
            return nil
        }
        _ = context.evaluateScript(script)
        guard let hljs = context.globalObject.objectForKeyedSubscript("hljs"),
              !hljs.isUndefined, !hljs.isNull else {
            return nil
        }
        return hljs
    }

    private static func locateHighlightMinJS() -> String? {
        let bundleName = "Highlighter_Highlighter.bundle"
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent(bundleName))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(bundleName))
        let executableURL = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
        let execDir = executableURL.deletingLastPathComponent()
        candidates.append(execDir.appendingPathComponent(bundleName))
        candidates.append(
            execDir
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/\(bundleName)")
        )
        for bundle in Bundle.allBundles {
            if let path = bundle.path(forResource: "highlight.min", ofType: "js") {
                return path
            }
            if let url = bundle.resourceURL?.appendingPathComponent(bundleName) {
                candidates.append(url)
            }
        }
        for bundleURL in candidates {
            if let bundle = Bundle(url: bundleURL),
               let path = bundle.path(forResource: "highlight.min", ofType: "js") {
                return path
            }
            let direct = bundleURL.appendingPathComponent("highlight.min.js").path
            if FileManager.default.fileExists(atPath: direct) {
                return direct
            }
        }
        return nil
    }
}
