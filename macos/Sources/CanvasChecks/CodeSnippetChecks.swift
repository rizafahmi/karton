import AppKit
import CanvasCore
import CanvasUI

@MainActor
func runCodeSnippetChecks() throws {
    // 1. Literal line-ending & indentation helpers
    try require(
        CanvasCodeSnippet.preferredLineEnding(in: "a\r\nb\r\nc", atUTF16Offset: 1) == "\r\n" &&
        CanvasCodeSnippet.preferredLineEnding(in: "a\rb", atUTF16Offset: 2) == "\r" &&
        CanvasCodeSnippet.preferredLineEnding(in: "plain", atUTF16Offset: 2) == "\n",
        "preferredLineEnding did not preserve existing line terminators"
    )
    let crlfSource = "line1\r\nline2\r\nline3"
    // Selection ending at column 0 of line3 ("line1\r\nline2\r\n") must NOT indent line3
    let col0Range = NSRange(location: 0, length: ("line1\r\nline2\r\n" as NSString).length)
    let indented = CanvasCodeSnippet.indent(source: crlfSource, selection: col0Range)
    try require(
        indented.text == "  line1\r\n  line2\r\nline3",
        "Tab indent did not preserve CRLF or wrongly indented line ending at col 0: \(indented.text.debugDescription)"
    )
    let unindented = CanvasCodeSnippet.unindent(source: "\tline1\r\n  line2\r\n  line3", selection: NSRange(location: 0, length: ("\tline1\r\n  line2\r\n" as NSString).length))
    try require(
        unindented.text == "line1\r\nline2\r\n  line3",
        "Shift-Tab unindent did not remove 1 tab / 2 spaces or wrongly unindented col-0 line: \(unindented.text.debugDescription)"
    )

    // 2. HighlighterSwift: all 12 curated languages, literal preservation, light/dark themes, Auto & unknown fallback
    let highlighter = CanvasCodeHighlighter.shared
    try require(highlighter.isAvailable, "CanvasCodeHighlighter failed to initialize HighlighterSwift")

    let samples: [(CanvasCodeLanguage, String)] = [
        (.elixir, "defmodule Demo do\r\n  def run(x), do: IO.puts(\"ok #{x}\")\r\nend\r\n"),
        (.erlang, "-module(demo).\n-export([run/1]).\nrun(X) -> {ok, X}.\n"),
        (.javascript, "export function greet(name) {\n  return `hi ${name}`;\n}\n"),
        (.typescript, "interface User { id: number; name: string }\nconst u: User = { id: 1, name: \"Ada\" };\n"),
        (.json, "{\n  \"version\": 2,\n  \"enabled\": true,\n  \"count\": 42\n}\n"),
        (.html, "<div class=\"card\">\n  <h1>Hello &amp; Welcome</h1>\n</div>\n"),
        (.css, "/* theme */\n@media (min-width: 640px) {\n  .canvas-node { color: #0a0b0d; border: 2px solid #d4ff00; }\n}\n"),
        (.shell, "#!/bin/sh\nset -eu\nfor f in *.json; do echo \"$f\"; done\n"),
        (.python, "def fib(n: int) -> int:\n    return n if n <= 1 else fib(n - 1) + fib(n - 2)\n"),
        (.sql, "SELECT id, title FROM canvases WHERE version = 2 ORDER BY id DESC;\n"),
        (.swift, "struct Point: Equatable {\n    let x: Double\n    let y: Double\n}\n"),
        (.rust, "pub fn add(a: i64, b: i64) -> i64 {\n    // sum\n    a + b\n}\n"),
    ]
    for (lang, sample) in samples {
        let light = highlighter.highlight(source: sample, language: lang.rawValue, isDark: false)
        let dark = highlighter.highlight(source: sample, language: lang.rawValue, isDark: true)
        try require(!light.usedFallback && !dark.usedFallback, "Highlighter fell back for \(lang.rawValue)")
        let lightColors = Set(light.runs.map { $0.color.usingColorSpace(.sRGB)?.description ?? "" })
        let darkColors = Set(dark.runs.map { $0.color.usingColorSpace(.sRGB)?.description ?? "" })
        try require(lightColors.count >= 2 && darkColors.count >= 2, "Expected multiple token colors for \(lang.rawValue)")
        let (attr, _) = highlighter.attributedString(source: sample, language: lang.rawValue, size: "m", fill: "none")
        try require(attr.string == sample, "Attributed string altered literal bytes for \(lang.rawValue)")
    }

    // BOM + leading/trailing whitespace + mixed line endings preserved verbatim
    let literalEdge = "\u{feff}  def f, do: \"<a>\"\r\n\t# note\r  "
    let (bomAttr, bomResult) = highlighter.attributedString(source: literalEdge, language: "elixir", size: "m", fill: "ink")
    try require(bomAttr.string == literalEdge && !bomResult.usedFallback, "Highlighter altered BOM/whitespace/mixed endings")
    try require(bomResult.isDarkTheme, "Ink fill did not select dark token palette")

    // Plain text & unknown language ID produce zero syntax runs without Auto detection
    let plainRes = highlighter.highlight(source: samples[0].1, language: "plaintext", isDark: false)
    let unknownRes = highlighter.highlight(source: samples[0].1, language: "future-language", isDark: false)
    try require(plainRes.runs.isEmpty && unknownRes.runs.isEmpty, "Plaintext or unknown language unexpectedly highlighted")

    // Conservative Auto detection: clear Elixir/SQL detected; ambiguous short prose stays nil (Plain text)
    try require(highlighter.detectLanguage(for: samples[0].1) == .elixir, "Auto did not detect clear Elixir sample")
    try require(highlighter.detectLanguage(for: "hello world") == nil, "Auto over-classified plain prose")

    // 3. v1 refusal & visible banner guidance (no silent upgrade, stays in Select mode)
    let v1Doc = try CanvasDocument(data: Data(#"{"version":1,"nodes":[],"edges":[]}"#.utf8))
    let v1Session = CanvasSession(document: v1Doc)
    let v1View = CanvasView(session: v1Session)
    v1View.armCreationTool(.code)
    try require(
        v1View.activeCreationTool == .select &&
        !v1View.hasActiveCodeEditor &&
        !v1View.statusBanner.isHidden &&
        v1Session.version == 1 &&
        (v1Session.root["nodes"] as? [[String: Any]])?.isEmpty == true,
        "v1 canvas did not refuse Code tool visibly while staying v1 and in Select mode"
    )
    if case .v1CodeNotice = v1View.statusBanner.activeKind {
        // expected
    } else {
        throw CheckFailure(description: "v1 Code refusal did not show v1CodeNotice banner")
    }

    // 4. v2 authoring, local draft cancellation, Finish, Undo/Redo, Enter/Tab/Escape, Fit, Copy Code
    let v2Doc = try CanvasDocument.blank()
    let session = CanvasSession(document: v2Doc)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    let view = CanvasView(session: session)
    let testPasteboard = NSPasteboard.withUniqueName()
    defer { testPasteboard.releaseGlobally() }
    view.codePasteboard = testPasteboard
    view.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
    window.contentView = view
    window.makeFirstResponder(view)

    // Cancel before insertion leaves zero nodes and no history
    view.beginNewCodeBlock()
    try require(view.hasActiveCodeEditor, "beginNewCodeBlock did not open code editor")
    view.activeCodeEditor?.sourceTextView.string = "discard me"
    view.cancelCodeEditor()
    try require(
        !view.hasActiveCodeEditor &&
        (session.root["nodes"] as? [[String: Any]])?.isEmpty == true &&
        view.undoManager?.canUndo != true,
        "Cancelling new code block left a node or history entry"
    )

    // Create new code block with explicit language + BOM/CRLF + Tab indent + Copy Code
    let customBox = CanvasGeometry(x: 120, y: 80, width: 320, height: 140, rotation: nil)
    view.beginNewCodeBlock(at: customBox)
    guard let editor = view.activeCodeEditor else {
        throw CheckFailure(description: "Missing active code editor")
    }
    try require(!editor.isFitChecked, "Fit checkbox did not start unchecked")
    editor.sourceTextView.string = "\u{feff}defmodule Hello do\r\ndef greet, do: :ok\r\nend"
    // Select second line and indent with Tab
    let line2Start = "\u{feff}defmodule Hello do\r\n".utf16.count
    editor.sourceTextView.setSelectedRange(NSRange(location: line2Start, length: 0))
    editor.sourceTextView.insertTab(nil)
    try require(
        editor.currentSource == "\u{feff}defmodule Hello do\r\n  def greet, do: :ok\r\nend",
        "Editor Tab indent failed: \(editor.currentSource.debugDescription)"
    )
    // Copy literal code from editor without committing (check raw UTF-8 bytes to verify BOM preservation)
    editor.copyLiteralSourceToPasteboard()
    let copiedBytes = testPasteboard.data(forType: .string) ?? Data()
    try require(
        view.hasActiveCodeEditor &&
        copiedBytes.elementsEqual(editor.currentSource.utf8),
        "Copy Code from editor committed prematurely or altered literal bytes"
    )
    // Toggling Fit never commits
    editor.isFitChecked = true
    try require(view.hasActiveCodeEditor, "Toggling Fit checkbox committed editor")
    editor.isFitChecked = false

    // Finish commits one v2 code node with language: "auto"
    try require(editor.attemptFinish() && !view.hasActiveCodeEditor, "Finish failed for valid new code block")
    guard let createdID = view.selectedNodeID,
          let createdNode = (session.root["nodes"] as? [[String: Any]])?.first(where: { $0["id"] as? String == createdID }),
          let createdData = createdNode["data"] as? [String: Any] else {
        throw CheckFailure(description: "New code block was not committed to session")
    }
    try require(
        createdNode["type"] as? String == "code" &&
        createdData["content"] as? String == "\u{feff}defmodule Hello do\r\n  def greet, do: :ok\r\nend" &&
        createdData["language"] as? String == "auto" &&
        createdData["fit"] == nil,
        "Committed code block JSON did not match v2 contract"
    )
    // Undo/Redo restores identity and content atomically
    view.undoMove(nil)
    try require((session.root["nodes"] as? [[String: Any]])?.isEmpty == true, "Undo did not remove new code block")
    view.redoMove(nil)
    try require(session.codeContent(of: createdID) == "\u{feff}defmodule Hello do\r\n  def greet, do: :ok\r\nend", "Redo did not restore code block")

    // 5. Source-only edit preserves omitted language & unknown metadata; invalid draft refuses Save/Export
    let rawWithMeta: [String: Any] = [
        "version": 2,
        "nodes": [
            [
                "id": "omitted-lang",
                "type": "code",
                "x": 40, "y": 40, "width": 200, "height": 50,
                "custom_node": "keep",
                "data": [
                    "content": "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8",
                    "custom_data": 99,
                ],
            ] as [String: Any],
            [
                "id": "future-lang",
                "type": "code",
                "x": 300, "y": 40, "width": 240, "height": 90,
                "data": [
                    "content": "fn main() {}",
                    "language": "future-language",
                ],
            ] as [String: Any],
        ],
        "edges": [],
    ]
    let metaDoc = try CanvasDocument(data: try CanvasDocument.encode(rawWithMeta))
    let metaSession = CanvasSession(document: metaDoc)
    let metaView = CanvasView(session: metaSession)
    metaView.codePasteboard = testPasteboard
    metaView.frame = NSRect(x: 0, y: 0, width: 1000, height: 700)
    window.contentView = metaView
    window.makeFirstResponder(metaView)

    // Clipped overflow blocks PNG export
    var threwClipped = false
    do {
        _ = try metaView.exportPNGData(scope: .entireCanvas)
    } catch {
        threwClipped = error.localizedDescription.contains("clipped")
    }
    try require(threwClipped, "PNG export did not refuse clipped code block")

    // Source-only edit on omitted-lang with Fit checked commits source + fitted box in ONE transaction,
    // without materializing "language": "auto" and while keeping custom metadata!
    metaView.beginCodeEditing(nodeID: "omitted-lang")
    guard let edit2 = metaView.activeCodeEditor else {
        throw CheckFailure(description: "Failed to open code editor on existing node")
    }
    // First test invalid control character refuses flush for Save
    edit2.sourceTextView.string = "bad\u{0007}bell"
    var threwInvalidFlush = false
    do {
        try metaView.flushPendingEditsForSave()
    } catch {
        threwInvalidFlush = true
    }
    try require(threwInvalidFlush && metaView.hasActiveCodeEditor, "Invalid code draft did not block Save flush or closed editor")

    // Fix source, check Fit, and flush via Save!
    let updatedSource = "defmodule FitDemo do\n  def a, do: 1\n  def b, do: 2\n  def c, do: 3\n  def d, do: 4\nend"
    edit2.sourceTextView.string = updatedSource
    edit2.isFitChecked = true
    try metaView.flushPendingEditsForSave()
    try require(!metaView.hasActiveCodeEditor, "Valid code draft did not flush on Save")

    let fittedNode = (metaSession.root["nodes"] as? [[String: Any]])?.first(where: { $0["id"] as? String == "omitted-lang" })
    let fittedData = fittedNode?["data"] as? [String: Any]
    try require(
        fittedNode?["custom_node"] as? String == "keep" &&
        fittedData?["custom_data"] as? Int == 99 &&
        fittedData?["language"] == nil &&
        fittedData?["content"] as? String == updatedSource &&
        (metaSession.geometry(of: "omitted-lang")?.height ?? 0) > 50,
        "Source+Fit edit materialized omitted language, lost metadata, or failed to grow box"
    )
    // Now PNG export succeeds on both light and dark themes (no clipped source!)
    let lightPNG = try metaView.exportPNGData(sizing: .longestSide(640), theme: .light, scope: .entireCanvas)
    let darkPNG = try metaView.exportPNGData(sizing: .longestSide(640), theme: .dark, scope: .entireCanvas)
    try require(lightPNG.count > 100 && darkPNG.count > 100 && lightPNG != darkPNG, "Highlighted code PNG export failed for light/dark themes")

    // Undo reverts BOTH source and fitted height in one step
    metaView.undoMove(nil)
    try require(
        metaSession.codeContent(of: "omitted-lang") == "line 1\nline 2\nline 3\nline 4\nline 5\nline 6\nline 7\nline 8" &&
        metaSession.geometry(of: "omitted-lang")?.height == 50,
        "Undo did not revert source+Fit atomically"
    )

    // Locked code node refuses edit, allows Copy Code
    metaView.selectNode("future-lang")
    _ = try metaSession.setLocked("future-lang", to: true)
    try require(!metaSession.canEditCode("future-lang") && metaView.canCopyCodeSelection, "Locked code node edit/copy eligibility wrong")
    try require(metaView.copySelectedCode() && testPasteboard.string(forType: .string) == "fn main() {}", "Copy Code failed on locked code node")

    // 6. Temporary v2 JSON round-trip with exact literal bytes
    let encoded = try metaSession.encodedData()
    let reopened = try CanvasDocument(data: encoded)
    let reopenedSession = CanvasSession(document: reopened)
    try require(
        reopenedSession.version == 2 &&
        reopenedSession.codeLanguage(of: "omitted-lang") == nil &&
        reopenedSession.codeLanguage(of: "future-lang") == "future-language",
        "v2 code snippet round-trip altered language preservation"
    )

    print("PASS code snippets (v0.2): HighlighterSwift 12-language highlighting, conservative Auto detection, literal BOM/CRLF/Tab editing, v1 refusal banner, Fit to content, clipped PNG export refusal, Copy Code, atomic history and v2 round-trip")
}
