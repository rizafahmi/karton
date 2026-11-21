import Foundation

/// Curated language inventory for v2 `type: "code"` nodes (`shared/CODE_SNIPPETS.md §3`).
public enum CanvasCodeLanguage: String, CaseIterable, Equatable, Hashable, Sendable {
    case auto
    case plaintext
    case elixir
    case erlang
    case javascript
    case typescript
    case json
    case html
    case css
    case shell
    case python
    case sql
    case swift
    case rust

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .plaintext: return "Plain text"
        case .elixir: return "Elixir"
        case .erlang: return "Erlang"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .json: return "JSON"
        case .html: return "HTML"
        case .css: return "CSS"
        case .shell: return "Shell"
        case .python: return "Python"
        case .sql: return "SQL"
        case .swift: return "Swift"
        case .rust: return "Rust"
        }
    }

    /// Corresponding Highlight.js grammar identifier, or `nil` for `auto` / `plaintext`.
    public var highlightJSName: String? {
        switch self {
        case .auto, .plaintext: return nil
        case .html: return "xml"
        case .shell: return "bash"
        default: return rawValue
        }
    }

    /// Maps a Highlight.js detected language name back to the canonical contract ID.
    public static func fromHighlightJS(_ name: String) -> CanvasCodeLanguage? {
        switch name.lowercased() {
        case "xml", "html": return .html
        case "bash", "sh", "shell", "zsh": return .shell
        case "elixir": return .elixir
        case "erlang": return .erlang
        case "javascript", "js": return .javascript
        case "typescript", "ts": return .typescript
        case "json": return .json
        case "css": return .css
        case "python", "py": return .python
        case "sql": return .sql
        case "swift": return .swift
        case "rust", "rs": return .rust
        default: return nil
        }
    }

    /// Curated subset passed to Highlight.js `highlightAuto(code, subset)`.
    public static let detectableHighlightJSNames: [String] = [
        "elixir", "erlang", "javascript", "typescript", "json", "xml",
        "css", "bash", "python", "sql", "swift", "rust",
    ]

    /// Human-readable label for any stored `data.language` value (including unknown future IDs).
    public static func displayLabel(for storedLanguage: String?) -> String {
        guard let storedLanguage else { return CanvasCodeLanguage.auto.displayName }
        if let known = CanvasCodeLanguage(rawValue: storedLanguage) {
            return known.displayName
        }
        return "\(storedLanguage) (Plain text)"
    }
}

/// Literal source validation and editing helpers for v2 `type: "code"` nodes (`shared/CODE_SNIPPETS.md §2, §4`).
public enum CanvasCodeSnippet {
    public static let perNodeByteLimit = 262_144
    public static let canvasByteLimit = 1_048_576
    public static let defaultWidth: Double = 480
    public static let defaultHeight: Double = 240
    public static let minWidth: Double = 160
    public static let minHeight: Double = 80

    /// Validates literal UTF-8 code source against the per-node byte cap and forbidden control characters.
    /// Allows TAB (9), LF (10), CR (13), and BOM (U+FEFF); refuses all other C0/C1 controls and DEL.
    public static func validateSource(_ source: String) throws {
        let count = source.utf8.count
        guard count <= perNodeByteLimit else {
            throw CanvasDocumentError("Code source exceeds 262144 UTF-8 bytes.")
        }
        for scalar in source.unicodeScalars {
            let n = scalar.value
            if (n < 32 && n != 9 && n != 10 && n != 13) || (n >= 127 && n <= 159) {
                throw CanvasDocumentError("Code source contains a forbidden control character.")
            }
        }
    }

    /// Chooses the line terminator for Enter at `utf16Offset` per `shared/CODE_SNIPPETS.md §2`:
    /// current line's terminator, then nearest preceding terminator, then first existing terminator, else LF.
    public static func preferredLineEnding(in source: String, atUTF16Offset offset: Int) -> String {
        let ns = source as NSString
        let length = ns.length
        let clamped = max(0, min(offset, length))
        let lines = lineSpans(in: ns)
        // Find the line containing clamped
        var currentIndex = max(0, lines.count - 1)
        for (idx, span) in lines.enumerated() {
            if clamped >= span.start && clamped <= span.contentEnd {
                currentIndex = idx
                break
            }
            if clamped > span.contentEnd && clamped < span.end {
                // Inside a CRLF pair: treat as current line
                currentIndex = idx
                break
            }
        }
        if currentIndex < lines.count, !lines[currentIndex].terminator.isEmpty {
            return lines[currentIndex].terminator
        }
        if currentIndex > 0 {
            for idx in stride(from: currentIndex - 1, through: 0, by: -1) {
                if !lines[idx].terminator.isEmpty {
                    return lines[idx].terminator
                }
            }
        }
        for span in lines where !span.terminator.isEmpty {
            return span.terminator
        }
        return "\n"
    }

    /// Indents affected lines by two spaces (`"  "`).
    /// A non-empty selection ending at the next line's column 0 does not indent that next line.
    public static func indent(source: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = source as NSString
        let length = ns.length
        let start = max(0, min(selection.location, length))
        let end = max(start, min(selection.location + selection.length, length))

        if start == end {
            // Collapsed caret: insert two spaces at caret (or indent current line? Spec says:
            // "Tab / Shift-Tab | Indent by two spaces / remove one leading tab or up to two spaces per affected line").
            // At a collapsed caret, inserting two spaces at the caret indents naturally when at line start
            // and also works mid-line; wait — let's indent at the caret for collapsed selection or line start?
            // Let's match web `code_snippets.js` behavior: indent affected line(s) by prepending "  " to each line!
            // Actually, if collapsed at line start, both are identical; prepending "  " to the current line
            // and shifting caret by +2 always indents the current line cleanly!
            let spans = lineSpans(in: ns)
            let targetIndex = affectedLineIndices(spans: spans, start: start, end: end).first ?? 0
            let lineStart = spans[targetIndex].start
            let mutable = NSMutableString(string: source)
            mutable.insert("  ", at: lineStart)
            return (mutable as String, NSRange(location: start + 2, length: 0))
        }

        let spans = lineSpans(in: ns)
        let indices = affectedLineIndices(spans: spans, start: start, end: end)
        guard !indices.isEmpty else { return (source, selection) }

        let mutable = NSMutableString(string: source)
        var addedBeforeStart = 0
        var totalAdded = 0
        for idx in indices.reversed() {
            let lineStart = spans[idx].start
            mutable.insert("  ", at: lineStart)
            totalAdded += 2
            if lineStart <= start {
                addedBeforeStart += 2
            }
        }
        let newStart = start + addedBeforeStart
        let newEnd = end + totalAdded
        return (mutable as String, NSRange(location: newStart, length: max(0, newEnd - newStart)))
    }

    /// Unindents affected lines by removing one leading tab or up to two leading spaces per affected line.
    /// A non-empty selection ending at the next line's column 0 does not unindent that next line.
    public static func unindent(source: String, selection: NSRange) -> (text: String, selection: NSRange) {
        let ns = source as NSString
        let length = ns.length
        let start = max(0, min(selection.location, length))
        let end = max(start, min(selection.location + selection.length, length))

        let spans = lineSpans(in: ns)
        let indices = affectedLineIndices(spans: spans, start: start, end: end)
        guard !indices.isEmpty else { return (source, selection) }

        let mutable = NSMutableString(string: source)
        var removedBeforeStart = 0
        var totalRemoved = 0
        for idx in indices.reversed() {
            let span = spans[idx]
            let contentLen = span.contentEnd - span.start
            guard contentLen > 0 else { continue }
            let first = ns.character(at: span.start)
            let removeCount: Int
            if first == 9 { // '\t'
                removeCount = 1
            } else if first == 32 { // ' '
                if contentLen >= 2 && ns.character(at: span.start + 1) == 32 {
                    removeCount = 2
                } else {
                    removeCount = 1
                }
            } else {
                removeCount = 0
            }
            guard removeCount > 0 else { continue }
            mutable.deleteCharacters(in: NSRange(location: span.start, length: removeCount))
            totalRemoved += removeCount
            if span.start < start {
                removedBeforeStart += min(removeCount, start - span.start)
            }
        }
        guard totalRemoved > 0 else { return (source, selection) }
        let newStart = max(0, start - removedBeforeStart)
        let newEnd = max(newStart, end - totalRemoved)
        return (mutable as String, NSRange(location: newStart, length: max(0, newEnd - newStart)))
    }

    private struct LineSpan {
        let start: Int
        let contentEnd: Int
        let end: Int
        let terminator: String
    }

    private static func lineSpans(in ns: NSString) -> [LineSpan] {
        let length = ns.length
        if length == 0 {
            return [LineSpan(start: 0, contentEnd: 0, end: 0, terminator: "")]
        }
        var spans: [LineSpan] = []
        var pos = 0
        var lineStart = 0
        while pos < length {
            let ch = ns.character(at: pos)
            if ch == 13 { // '\r'
                if pos + 1 < length && ns.character(at: pos + 1) == 10 { // '\r\n'
                    spans.append(LineSpan(start: lineStart, contentEnd: pos, end: pos + 2, terminator: "\r\n"))
                    pos += 2
                    lineStart = pos
                } else {
                    spans.append(LineSpan(start: lineStart, contentEnd: pos, end: pos + 1, terminator: "\r"))
                    pos += 1
                    lineStart = pos
                }
            } else if ch == 10 { // '\n'
                spans.append(LineSpan(start: lineStart, contentEnd: pos, end: pos + 1, terminator: "\n"))
                pos += 1
                lineStart = pos
            } else {
                pos += 1
            }
        }
        // Trailing line (including empty line after final terminator)
        spans.append(LineSpan(start: lineStart, contentEnd: length, end: length, terminator: ""))
        return spans
    }

    private static func affectedLineIndices(spans: [LineSpan], start: Int, end: Int) -> [Int] {
        if start == end {
            for (idx, span) in spans.enumerated() {
                if start >= span.start && start <= span.contentEnd {
                    return [idx]
                }
                if start > span.contentEnd && start < span.end {
                    return [idx]
                }
            }
            return [max(0, spans.count - 1)]
        }
        var result: [Int] = []
        for (idx, span) in spans.enumerated() {
            // A selection ending at the next line's column 0 (end == span.start) does not affect that line.
            if span.start < end && span.end > start {
                result.append(idx)
            } else if span.start == span.end && span.start >= start && span.start < end {
                result.append(idx)
            }
        }
        return result
    }
}
