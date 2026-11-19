import AppKit
import CanvasCore
import CanvasUI
import Foundation

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if !(try condition()) { throw CheckFailure(description: message) }
}

func encoded(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
}

func shape(_ id: String) -> [String: Any] {
    ["id": id, "type": "shape", "x": 0, "y": 0, "width": 100, "height": 50,
     "data": ["kind": "rect", "text": "hello"]]
}

func code(_ id: String, _ source: String) -> [String: Any] {
    ["id": id, "type": "code", "x": 0, "y": 0, "width": 100, "height": 50,
     "data": ["content": source]]
}

func canvas(_ nodes: [[String: Any]], edges: [[String: Any]] = [], version: Int = 2) -> [String: Any] {
    ["version": version, "nodes": nodes, "edges": edges]
}

func rejects(_ object: Any, mentioning expected: String) throws {
    let bytes = try encoded(object)
    do {
        _ = try CanvasDocument(data: bytes)
        throw CheckFailure(description: "Accepted invalid canvas: \(expected)")
    } catch let error as CanvasDocumentError {
        try require(error.localizedDescription.localizedCaseInsensitiveContains(expected), "Unexpected refusal for \(expected): \(error)")
    }
}

@MainActor
func runChecks() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    CanvasTypography.customFontDirectoryURL = repository.appendingPathComponent("macos/Resources/Fonts", isDirectory: true)
    for path in ["v1/document.json", "v1/compatibility.json", "v2/document.json", "v2/code-compatibility.json"] {
        let bytes = try Data(contentsOf: repository.appendingPathComponent("shared/fixtures/\(path)"))
        let document = try CanvasDocument(data: bytes)
        try require(document.originalData == bytes, "Original bytes changed: \(path)")
        try require(document.root["nodes"] is [Any], "Missing fixture nodes: \(path)")
        print("PASS fixture \(path): original bytes retained")
    }

    let malformed = Data("{".utf8)
    do {
        _ = try CanvasDocument(data: malformed)
        throw CheckFailure(description: "Accepted malformed JSON")
    } catch is CanvasDocumentError {}
    try rejects([1, 2], mentioning: "object")
    try rejects(["version": 3, "nodes": [], "edges": []], mentioning: "version")
    try rejects(["version": true, "nodes": [], "edges": []], mentioning: "version")
    try rejects(["nodes": [], "edges": []], mentioning: "version")
    var unknown = shape("n"); unknown["type"] = "future"
    try rejects(canvas([unknown]), mentioning: "type")
    try rejects(canvas([code("c", "")], version: 1), mentioning: "version 2")
    var invalid = shape("n"); invalid["width"] = 0
    try rejects(canvas([invalid]), mentioning: "dimensions")
    invalid = shape("n"); invalid["x"] = true
    try rejects(canvas([invalid]), mentioning: "coordinates")
    invalid = shape("n"); invalid["data"] = ["kind": "star"]
    try rejects(canvas([invalid]), mentioning: "kind")
    try rejects(canvas([shape("n"), shape("n")]), mentioning: "duplicate node")
    try rejects(canvas([shape("n")], edges: [["id": "e", "source": "n", "target": "missing"]]), mentioning: "missing node")
    let edge: [String: Any] = ["id": "e", "source": "n", "target": "m"]
    try rejects(canvas([shape("n"), shape("m")], edges: [edge, edge]), mentioning: "duplicate connector")
    var badHandle = edge; badHandle["source_handle"] = "future"
    try rejects(canvas([shape("n"), shape("m")], edges: [badHandle]), mentioning: "handle")
    try rejects(canvas([shape("n")], edges: [["id": "loop", "source": "n", "target": "n"]]), mentioning: "self-loop")
    print("PASS malformed, unsupported and inconsistent documents refused")

    let maximum = String(repeating: "x", count: 262_144)
    _ = try CanvasDocument(data: encoded(canvas((0..<4).map { code("c\($0)", maximum) })))
    try rejects(canvas([code("c", maximum + "x")]), mentioning: "262144")
    try rejects(canvas((0..<4).map { code("c\($0)", maximum) } + [code("extra", "x")]), mentioning: "1048576")
    try rejects(canvas([code("c", "bad\u{0}source")]), mentioning: "control")
    var badLanguage = code("c", ""); badLanguage["data"] = ["content": "", "language": ""]
    try rejects(canvas([badLanguage]), mentioning: "language")
    func attached(_ id: String, _ text: String) -> [String: Any] {
        var node = shape(id)
        node["data"] = ["kind": "rect", "attachment": ["filename": "a.txt", "media_type": "text/plain", "encoding": "utf-8", "content": text]]
        return node
    }
    _ = try CanvasDocument(data: encoded(canvas((0..<4).map { attached("a\($0)", maximum) })))
    try rejects(canvas([attached("a", maximum + "x")]), mentioning: "262144")
    try rejects(canvas((0..<4).map { attached("a\($0)", maximum) } + [attached("extra", "x")]), mentioning: "1048576")
    try rejects(canvas([attached("a", "\u{7f}")]), mentioning: "control")
    print("PASS code and attachment byte limits and control restrictions")

    var interactionRoot = canvas([shape("moving"), shape("locked")])
    var interactionNodes = interactionRoot["nodes"] as! [[String: Any]]
    interactionNodes[0]["x"] = 100
    interactionNodes[0]["y"] = 100
    interactionNodes[0]["data"] = ["kind": "rect", "custom": ["retained": true]]
    interactionNodes[1]["x"] = 300
    interactionNodes[1]["y"] = 100
    interactionNodes[1]["locked"] = true
    interactionRoot["nodes"] = interactionNodes
    let interactionBytes = try encoded(interactionRoot)
    let session = CanvasSession(document: try CanvasDocument(data: interactionBytes))
    let view = CanvasView(session: session)
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: view.frame.size),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentView = view
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    let start = view.viewPoint(forWorldPoint: CGPoint(x: 150, y: 125))
    let finish = CGPoint(x: start.x + 40, y: start.y + 30)
    func mouse(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: clicks,
            pressure: 1
        )!
    }
    view.mouseDown(with: mouse(.leftMouseDown, start))
    view.mouseDragged(with: mouse(.leftMouseDragged, finish))
    view.mouseUp(with: mouse(.leftMouseUp, finish))
    try require(session.position(of: "moving") == CanvasPosition(x: 140, y: 130), "Pointer drag did not update session geometry")
    let canUndo = view.undoManager?.canUndo == true
    try require(canUndo, "Pointer drag did not create one undoable move")
    view.undoMove(nil)
    try require(session.position(of: "moving") == CanvasPosition(x: 100, y: 100), "Undo did not restore geometry")
    view.redoMove(nil)
    try require(session.position(of: "moving") == CanvasPosition(x: 140, y: 130), "Redo did not restore moved geometry")
    let shiftRight = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.shift],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: false,
        keyCode: 124
    )!
    view.keyDown(with: shiftRight)
    try require(session.position(of: "moving") == CanvasPosition(x: 150, y: 130), "Shift-arrow did not move by 10 world units")
    view.undoMove(nil)
    try require(session.position(of: "moving") == CanvasPosition(x: 140, y: 130), "Undo did not restore keyboard move")

    let lockedStart = view.viewPoint(forWorldPoint: CGPoint(x: 350, y: 125))
    let lockedFinish = CGPoint(x: lockedStart.x + 40, y: lockedStart.y + 30)
    view.mouseDown(with: mouse(.leftMouseDown, lockedStart))
    view.mouseDragged(with: mouse(.leftMouseDragged, lockedFinish))
    view.mouseUp(with: mouse(.leftMouseUp, lockedFinish))
    try require(session.position(of: "locked") == CanvasPosition(x: 300, y: 100), "Locked node moved")
    try require(session.document.originalData == interactionBytes, "Session movement changed original document bytes")
    print("PASS AppKit pointer move, undo/redo, locked refusal and original-byte boundary")

    func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], characters: String = "") -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, characters: characters,
                        charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }
    func activeEditor() throws -> NSTextView {
        guard window.attachedSheet == nil,
              view.hasActiveInlineTextEditor,
              let editor = view.inlineTextEditorView,
              window.firstResponder === editor else {
            throw CheckFailure(description: "Canvas did not focus its inline text editor without a popup sheet")
        }
        return editor
    }
    view.keyDown(with: key(36))
    try require(!view.hasActiveInlineTextEditor && window.attachedSheet == nil, "Locked shape opened a text editor")
    let movedCenter = view.viewPoint(forWorldPoint: CGPoint(x: 190, y: 155))
    view.mouseDown(with: mouse(.leftMouseDown, movedCenter))
    view.mouseUp(with: mouse(.leftMouseUp, movedCenter))
    view.undoManager?.removeAllActions()
    let beforeTextRoot = session.root
    view.mouseDown(with: mouse(.leftMouseDown, movedCenter, clicks: 2))
    var editor = try activeEditor()
    let caption = "Hello 👨‍👩‍👧‍👦\nCafe\u{301} <literal>"
    editor.string = caption
    try require(session.text(of: "moving") == nil, "Draft leaked into committed content")
    editor.keyDown(with: key(36, modifiers: [.command]))
    try require(session.text(of: "moving") == caption, "Command-Return did not commit literal multiline text")
    try require(!view.hasActiveInlineTextEditor && window.attachedSheet == nil, "Commit left inline text editor open")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: session.root).isEqual(to: beforeTextRoot), "Text Undo did not restore complete original metadata and absent text")
    view.redoMove(nil)
    try require(session.text(of: "moving") == caption, "Text Redo did not restore caption")
    view.keyDown(with: key(36))
    editor = try activeEditor()
    editor.string = "Discard me"
    editor.keyDown(with: key(53))
    try require(session.text(of: "moving") == caption, "Escape committed the draft")
    view.keyDown(with: key(36))
    editor = try activeEditor()
    editor.string = String(repeating: "a", count: 2001)
    editor.keyDown(with: key(36, modifiers: [.command]))
    try require(view.hasActiveInlineTextEditor && session.text(of: "moving") == caption,
                "Over-limit draft was committed or dismissed")
    try require(editor.string.count == 2001, "Invalid draft was truncated")
    editor.string = String(repeating: "e\u{301}", count: 2000)
    editor.keyDown(with: key(36, modifiers: [.command]))
    try require(session.text(of: "moving")?.count == 2000, "Valid grapheme boundary was refused")
    try require(session.document.originalData == interactionBytes, "Text editing changed source bytes")
    view.undoMove(nil)
    try require(session.text(of: "moving") == caption, "Boundary edit did not undo as one transaction")
    view.keyDown(with: key(36))
    editor = try activeEditor()
    editor.keyDown(with: key(36, modifiers: [.command]))
    try require(view.undoManager?.canRedo == true, "Unchanged text finish cleared redo")
    view.redoMove(nil)
    try require(session.text(of: "moving")?.count == 2000, "No-op finish changed text history")
    print("PASS native text draft isolation, commit, cancel, history, Unicode limit and source-byte boundary")

    let blank = try CanvasDocument.blank()
    try require((blank.root["version"] as? Int) == 2 &&
                (blank.root["nodes"] as? [Any])?.isEmpty == true &&
                (blank.root["edges"] as? [Any])?.isEmpty == true, "New canvas is not blank v2")
    let blankSession = CanvasSession(document: blank)
    let blankInsertion = try blankSession.insertShape(.rectangle, at: CanvasPosition(x: -80, y: -48))
    _ = try CanvasDocument(data: encoded(blankSession.root))
    try blankSession.removeInsertion(blankInsertion)
    try require(NSDictionary(dictionary: blankSession.root).isEqual(to: blank.root),
                "Undo insertion did not restore blank canvas")
    do {
        _ = try blankSession.insertShape(.rectangle, at: CanvasPosition(x: .nan, y: 0))
        throw CheckFailure(description: "Inserted nonfinite geometry")
    } catch is CanvasDocumentError {}
    try require(NSDictionary(dictionary: blankSession.root).isEqual(to: blank.root),
                "Rejected insertion changed the canvas")

    let v1Document = try CanvasDocument(data: Data(contentsOf:
        repository.appendingPathComponent("shared/fixtures/v1/compatibility.json")))
    let v1Session = CanvasSession(document: v1Document)
    let v1Insertion = try v1Session.insertShape(.triangle, at: CanvasPosition(x: -160, y: 80))
    try require(v1Session.root["version"] as? Int == 1, "Insertion silently upgraded v1")
    _ = try CanvasDocument(data: encoded(v1Session.root))
    try v1Session.removeInsertion(v1Insertion)
    try require(NSDictionary(dictionary: v1Session.root).isEqual(to: v1Document.root),
                "Insertion Undo lost v1 metadata")

    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 280))
    view.removeFromSuperview()
    scroll.documentView = view
    window.contentView = scroll
    window.setContentSize(scroll.frame.size)
    scroll.contentView.scroll(to: CGPoint(x: 100, y: 90))
    scroll.reflectScrolledClipView(scroll.contentView)
    window.makeFirstResponder(view)
    view.undoManager?.removeAllActions()
    let beforeInsert = session.root
    for kind in [CanvasShapeKind.rectangle, .ellipse, .diamond, .triangle] {
        view.insertShape(kind)
        let raw = (session.root["nodes"] as! [[String: Any]]).last!
        let id = raw["id"] as! String
        let data = raw["data"] as! [String: Any]
        try require(data["kind"] as? String == kind.rawValue, "Insert command created the wrong shape")
        let center = view.viewPoint(forWorldPoint: CGPoint(
            x: (raw["x"] as! Double) + 80, y: (raw["y"] as! Double) + 48))
        try require(abs(center.x - view.visibleRect.midX) < 0.01 &&
                    abs(center.y - view.visibleRect.midY) < 0.01, "Insertion missed viewport center")
        _ = try CanvasDocument(data: encoded(session.root))
        let insertedRoot = session.root
        view.undoMove(nil)
        try require(NSDictionary(dictionary: session.root).isEqual(to: beforeInsert),
                    "Undo insertion damaged pre-existing content")
        view.redoMove(nil)
        try require(NSDictionary(dictionary: session.root).isEqual(to: insertedRoot) &&
                    session.position(of: id) != nil, "Redo changed inserted identity or stacking")
        view.undoMove(nil)
    }
    let hadRedo = view.undoManager?.canRedo
    view.insertShape(.text)
    editor = try activeEditor()
    editor.string = "Cancelled new text"
    editor.keyDown(with: key(53))
    try require(NSDictionary(dictionary: session.root).isEqual(to: beforeInsert) &&
                view.undoManager?.canRedo == hadRedo, "Cancelling new text changed content/history")
    view.insertShape(.text)
    editor = try activeEditor()
    editor.keyDown(with: key(36, modifiers: [.command]))
    try require(NSDictionary(dictionary: session.root).isEqual(to: beforeInsert) &&
                view.undoManager?.canRedo == hadRedo, "Empty new text created a node/history")
    view.insertShape(.text)
    editor = try activeEditor()
    editor.keyDown(with: key(15, characters: "r"))
    try require(editor.string == "r" &&
                NSDictionary(dictionary: session.root).isEqual(to: beforeInsert),
                "Canvas creation shortcut intercepted native text input")
    editor.undoManager?.undo()
    try require(editor.string.isEmpty &&
                NSDictionary(dictionary: session.root).isEqual(to: beforeInsert) &&
                view.undoManager?.canRedo == hadRedo,
                "Native text Undo affected canvas content/history")
    editor.string = String(repeating: "a", count: 2001)
    editor.keyDown(with: key(36, modifiers: [.command]))
    try require(view.hasActiveInlineTextEditor &&
                NSDictionary(dictionary: session.root).isEqual(to: beforeInsert),
                "Invalid new text escaped its draft")
    editor.string = "A new thought\n👩🏽‍💻"
    editor.keyDown(with: key(36, modifiers: [.command]))
    let newTextRoot = session.root
    let newText = (newTextRoot["nodes"] as! [[String: Any]]).last!
    let newTextID = newText["id"] as! String
    try require(session.text(of: newTextID) == "A new thought\n👩🏽‍💻", "New text was not committed literally")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: session.root).isEqual(to: beforeInsert),
                "New text did not undo in one transaction")
    view.redoMove(nil)
    try require(NSDictionary(dictionary: session.root).isEqual(to: newTextRoot),
                "New text redo lost identity or content")
    view.undoMove(nil)
    // Clicking outside on the canvas while typing inline text commits the text (only Escape cancels).
    view.insertShape(.text)
    editor = try activeEditor()
    editor.string = "Committed by outside click"
    let outsidePt = view.viewPoint(forWorldPoint: CGPoint(x: -300, y: -300))
    view.mouseDown(with: mouse(.leftMouseDown, outsidePt))
    view.mouseUp(with: mouse(.leftMouseUp, outsidePt))
    let clickedTextNode = (session.root["nodes"] as! [[String: Any]]).last!
    let clickedTextID = clickedTextNode["id"] as! String
    try require(!view.hasActiveInlineTextEditor &&
                session.text(of: clickedTextID) == "Committed by outside click",
                "Clicking outside inline text editor cancelled instead of committing")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: session.root).isEqual(to: beforeInsert),
                "Undo after outside-click text commit did not restore baseline")
    view.keyDown(with: key(15, characters: "r"))
    let keyboardShape = (session.root["nodes"] as! [[String: Any]]).last!
    let keyboardID = keyboardShape["id"] as! String
    try require((keyboardShape["data"] as? [String: Any])?["kind"] as? String == "rect",
                "Canvas R shortcut did not insert a rectangle")
    let insertedPosition = session.position(of: keyboardID)!
    view.keyDown(with: key(124))
    try require(session.position(of: keyboardID) == CanvasPosition(x: insertedPosition.x + 1, y: insertedPosition.y),
                "New shape was not selected for keyboard movement")
    view.undoMove(nil)
    try require(session.position(of: keyboardID) == insertedPosition, "Undo movement removed the insertion")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: session.root).isEqual(to: beforeInsert), "Mixed history lost original content")
    view.redoMove(nil)
    view.redoMove(nil)
    try require(session.position(of: keyboardID) == CanvasPosition(x: insertedPosition.x + 1, y: insertedPosition.y),
                "Mixed insertion/movement redo lost geometry or identity")
    try require(session.document.originalData == interactionBytes, "Creation changed original source bytes")
    print("PASS blank canvas, all shape insertions, viewport placement, text drafts and mixed history")
    try checkConnections(repository: repository)
    try checkGeometry(repository: repository)
    try checkLifecycle(repository: repository)
    try checkAdjacentThoughtsAndViewport(repository: repository)
    try checkStyles(repository: repository)
    try checkAlignment(repository: repository)
    try checkLiteralJSON()
    try checkCompatibilityRoundTrips(repository: repository)
    try checkTheme(repository: repository)
    try checkPNGExport(repository: repository)
    try checkPersistenceAndRecovery(repository: repository)
    try checkReleaseSlices(repository: repository)
}

@MainActor
func checkTheme(repository: URL) throws {
    func relativeLuminance(_ color: NSColor) throws -> CGFloat {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            throw CheckFailure(description: "Color could not convert to sRGB")
        }
        func channel(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.redComponent)
            + 0.7152 * channel(rgb.greenComponent)
            + 0.0722 * channel(rgb.blueComponent)
    }

    func contrastRatio(_ a: NSColor, _ b: NSColor) throws -> CGFloat {
        let la = try relativeLuminance(a)
        let lb = try relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    for fill in ["accent", "blue", "green", "violet", "yellow", "red", "gray", "surface", "none"] {
        let bg = fill == "none" ? CanvasTheme.canvasBackground : CanvasTheme.palette(fill)
        let ink = CanvasTheme.textColor(onFill: fill)
        try require(ink == CanvasTheme.highlighterInk, "Fill \(fill) did not pin Ebony highlighter ink")
        let ratio = try contrastRatio(bg, ink)
        try require(ratio >= 4.5, "Fill \(fill) contrast \(ratio) fell below WCAG AA 4.5:1")
    }

    for darkFill in ["ink", "future-fill"] {
        let swatch = CanvasTheme.palette(darkFill)
        let text = CanvasTheme.textColor(onFill: darkFill)
        try require(text == CanvasTheme.elevatedSurface, "Dark fill \(darkFill) did not use white text")
        let ratio = try contrastRatio(swatch, text)
        try require(ratio >= 12.0, "Dark fill \(darkFill) contrast \(ratio) was too low")
    }

    let inkContrast = try contrastRatio(CanvasTheme.canvasBackground, CanvasTheme.palette("ink"))
    try require(inkContrast >= 12.0, "Default ink stroke contrast \(inkContrast) on Plaster background was too low")

    let themeDoc = try CanvasDocument(
        data: encoded([
            "version": 2,
            "paper": ["background": "none"],
            "nodes": [shape("s1")],
            "edges": [] as [[String: Any]],
        ])
    )
    let v2Session = CanvasSession(document: themeDoc)
    let beforeRoot = v2Session.root
    let view = CanvasView(session: v2Session)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    window.contentView = view
    window.makeFirstResponder(view)
    view.insertShape(.rectangle)
    view.beginGeometryEditing()
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 200,
            pixelsHigh: 200,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ),
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
    else {
        throw CheckFailure(description: "Could not allocate sRGB bitmap context for CanvasView")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    view.draw(NSRect(x: 0, y: 0, width: 200, height: 200))
    NSGraphicsContext.restoreGraphicsState()
    let cornerColor = rep.colorAt(x: 3, y: 3)?.usingColorSpace(.sRGB)
    let expectedBg = CanvasTheme.canvasBackground.usingColorSpace(.sRGB)!
    try require(
        cornerColor != nil
            && abs(cornerColor!.redComponent - expectedBg.redComponent) < 0.03
            && abs(cornerColor!.greenComponent - expectedBg.greenComponent) < 0.03
            && abs(cornerColor!.blueComponent - expectedBg.blueComponent) < 0.03,
        "Rendered canvas background (\(String(describing: cornerColor))) did not match Raw Gallery Plaster (#f7f7f5)"
    )
    view.undoMove(nil) // cancels geometry preview
    view.undoMove(nil) // undoes inserted rectangle
    try require(
        NSDictionary(dictionary: v2Session.root).isEqual(to: beforeRoot)
            && v2Session.document.originalData == themeDoc.originalData,
        "Theme rendering or undo mutated session state or original bytes"
    )
    let previousAppearance = NSApp.appearance
    defer { NSApp.appearance = previousAppearance }
    NSApp.appearance = NSAppearance(named: .aqua)
    let welcomeWindow = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 520, height: 264),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    let welcomeView = WelcomeContentView(frame: NSRect(x: 0, y: 0, width: 520, height: 264))
    let newBtn = NSButton(title: "New Canvas", target: nil, action: nil)
    newBtn.frame = NSRect(x: 32, y: 214, width: 140, height: 32)
    newBtn.keyEquivalent = "\r"
    let openBtn = NSButton(title: "Open Canvas…", target: nil, action: nil)
    openBtn.frame = NSRect(x: 184, y: 214, width: 140, height: 32)
    welcomeView.addSubview(newBtn)
    welcomeView.addSubview(openBtn)
    welcomeWindow.contentView = welcomeView
    welcomeView.layoutSubtreeIfNeeded()
    let footerRect = NSRect(x: 0, y: 196, width: 520, height: 68)
    try require(
        footerRect.contains(newBtn.frame)
            && footerRect.contains(openBtn.frame)
            && !newBtn.frame.intersects(openBtn.frame),
        "Welcome window action buttons did not fit cleanly inside the footer bar"
    )
    guard let welcomeRep = welcomeView.bitmapImageRepForCachingDisplay(in: welcomeView.bounds) else {
        throw CheckFailure(description: "Could not allocate WelcomeContentView bitmap")
    }
    welcomeView.cacheDisplay(in: welcomeView.bounds, to: welcomeRep)
    let welcomeBg = welcomeRep.colorAt(x: 5, y: 5)?.usingColorSpace(.sRGB)
    try require(
        welcomeBg != nil
            && abs(welcomeBg!.redComponent - expectedBg.redComponent) < 0.03
            && abs(welcomeBg!.greenComponent - expectedBg.greenComponent) < 0.03
            && abs(welcomeBg!.blueComponent - expectedBg.blueComponent) < 0.03,
        "WelcomeContentView background did not match Raw Gallery Plaster (#f7f7f5)"
    )

    guard let iconData = CanvasTheme.appIconPNGData(pixelSize: 256),
          let iconRep = NSBitmapImageRep(data: iconData),
          iconRep.pixelsWide == 256 && iconRep.pixelsHigh == 256 else {
        throw CheckFailure(description: "CanvasTheme.appIconPNGData(pixelSize: 256) failed")
    }
    let iconAcidSample = iconRep.colorAt(x: 28, y: 28)
    let expectedAcid = CanvasTheme.acid.usingColorSpace(.sRGB)!
    let iconInkSample = iconRep.colorAt(x: 57, y: 57)
    let expectedInk = CanvasTheme.highlighterInk.usingColorSpace(.sRGB)!
    try require(
        iconAcidSample != nil
            && abs(iconAcidSample!.redComponent - expectedAcid.redComponent) < 0.03
            && abs(iconAcidSample!.greenComponent - expectedAcid.greenComponent) < 0.03
            && abs(iconAcidSample!.blueComponent - expectedAcid.blueComponent) < 0.03
            && iconInkSample != nil
            && abs(iconInkSample!.redComponent - expectedInk.redComponent) < 0.03
            && abs(iconInkSample!.greenComponent - expectedInk.greenComponent) < 0.03
            && abs(iconInkSample!.blueComponent - expectedInk.blueComponent) < 0.03,
        "App icon PNG pixels did not match Neo-Acid Lime (#c5f82a) background and Ebony Ink (#0a0b0d) glyph"
    )
    let icnsURL = repository.appendingPathComponent("macos/Resources/AppIcon.icns")
    guard let icnsImage = NSImage(contentsOf: icnsURL),
          let icns256Rep = icnsImage.representations.first(where: { $0.pixelsWide == 256 && $0.pixelsHigh == 256 }) as? NSBitmapImageRep else {
        throw CheckFailure(description: "Could not load 256x256 NSBitmapImageRep from macos/Resources/AppIcon.icns")
    }
    let icnsAcid = icns256Rep.colorAt(x: 28, y: 28)
    let icnsInk = icns256Rep.colorAt(x: 57, y: 57)
    try require(
        icnsImage.representations.count == 10
            && icnsImage.representations.contains(where: { $0.pixelsWide == 1024 && $0.pixelsHigh == 1024 })
            && icnsAcid != nil
            && abs(icnsAcid!.redComponent - expectedAcid.redComponent) < 0.03
            && abs(icnsAcid!.greenComponent - expectedAcid.greenComponent) < 0.03
            && abs(icnsAcid!.blueComponent - expectedAcid.blueComponent) < 0.03
            && icnsInk != nil
            && abs(icnsInk!.redComponent - expectedInk.redComponent) < 0.03
            && abs(icnsInk!.greenComponent - expectedInk.greenComponent) < 0.03
            && abs(icnsInk!.blueComponent - expectedInk.blueComponent) < 0.03,
        "macos/Resources/AppIcon.icns representations or Neo-Acid Lime/Ebony Ink pixel colors did not match"
    )
    print("PASS Neo-Acid light mode palette, highlighter/ink text contrast and bitmap rendering")
}

@MainActor
func checkReleaseSlices(repository: URL) throws {
    let fm = FileManager.default
    let tempRoot = fm.temporaryDirectory.appendingPathComponent("CanvasReleaseSlices-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempRoot) }

    let recoveryDir = tempRoot.appendingPathComponent("Recovery", isDirectory: true)
    let recoveryStore = CanvasRecoveryStore(directoryURL: recoveryDir)
    let recentKey = "local.elixircanvas.native.testRecent.\(UUID().uuidString)"
    let recentStore = CanvasRecentDocumentsStore(defaultsKey: recentKey, maxCount: 5)
    defer { recentStore.clear() }

    let delegate = CanvasAppDelegate(recoveryStore: recoveryStore, recentDocumentsStore: recentStore)
    delegate.installMenu()

    // Verify menus: Canvas (About Canvas), File (Open Recent), View (Hide Tool Dock), Window, Help
    guard let mainMenu = NSApplication.shared.mainMenu else {
        throw CheckFailure(description: "Missing mainMenu after installMenu")
    }
    let topTitles = mainMenu.items.map(\.title)
    try require(
        topTitles == ["Canvas", "File", "Edit", "Insert", "View", "Window", "Help"],
        "Unexpected top-level menus: \(topTitles)"
    )
    try require(NSApplication.shared.windowsMenu?.title == "Window", "NSApp.windowsMenu not wired")
    try require(NSApplication.shared.helpMenu?.title == "Help", "NSApp.helpMenu not wired")
    let appSubmenuTitles = mainMenu.item(withTitle: "Canvas")?.submenu?.items.map(\.title) ?? []
    try require(appSubmenuTitles.contains("About Canvas"), "Missing About Canvas menu item")
    let fileSubmenu = mainMenu.item(withTitle: "File")?.submenu
    try require(fileSubmenu?.item(withTitle: "Open Recent")?.submenu != nil, "Missing File -> Open Recent submenu")

    // Slice 1: Single Bottom-Center Neo-Acid Floating Icon Dock (no duplicate top NSToolbar) and armed click-or-drag creation
    delegate.newDocument(nil)
    defer { delegate.closeAllWindows() }
    guard let doc = delegate.activeNativeDocument(),
          let canvas = delegate.activeCanvas(),
          let window = canvas.window else {
        throw CheckFailure(description: "Failed to create native document window for Slice 1 check")
    }
    try require(window.toolbar == nil, "Document window should not attach a duplicate top NSToolbar")
    try require(canvas.isToolDockVisible && !canvas.toolDock.isHidden, "Floating icon tool dock should be visible on document window")
    try require(
        canvas.toolDock.iconGlyph(forButtonID: "dock-tool-select") == CanvasDockIconGlyph.select &&
        canvas.toolDock.iconGlyph(forButtonID: "dock-tool-rect") == CanvasDockIconGlyph.rectangle &&
        canvas.toolDock.iconGlyph(forButtonID: "dock-tool-arrow") == CanvasDockIconGlyph.arrow &&
        canvas.toolDock.iconGlyph(forButtonID: "dock-action-style") == CanvasDockIconGlyph.style &&
        canvas.toolDock.iconGlyph(forButtonID: "dock-action-export") == CanvasDockIconGlyph.exportPNG &&
        canvas.toolDock.iconGlyph(forButtonID: "dock-action-help") == CanvasDockIconGlyph.help,
        "Floating tool dock buttons are missing geometric vector icon glyphs"
    )
    delegate.toggleToolDock(nil)
    try require(!canvas.isToolDockVisible && canvas.toolDock.isHidden, "toggleToolDock did not hide tool dock")
    delegate.toggleToolDock(nil)
    try require(canvas.isToolDockVisible && !canvas.toolDock.isHidden, "toggleToolDock did not restore tool dock")

    func mouse(_ type: NSEvent.EventType, world: CGPoint) -> NSEvent {
        let viewPt = canvas.viewPoint(forWorldPoint: world)
        return NSEvent.mouseEvent(
            with: type,
            location: canvas.convert(viewPt, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
    }
    func key(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        )!
    }

    // 1a. Armed click placement for Rectangle via tool dock
    canvas.activateToolFromDock(.shape(.rectangle))
    try require(canvas.activeCreationTool == CanvasCreationTool.shape(.rectangle), "Dock did not arm rectangle tool")
    canvas.mouseDown(with: mouse(.leftMouseDown, world: CGPoint(x: 240, y: 180)))
    canvas.mouseUp(with: mouse(.leftMouseUp, world: CGPoint(x: 240, y: 180)))
    try require(canvas.activeCreationTool == CanvasCreationTool.select, "Click placement did not return to Select tool")
    guard let rectID = canvas.selectedNodeID,
          let rectGeo = doc.session.geometry(of: rectID) else {
        throw CheckFailure(description: "Click placement did not insert and select rectangle")
    }
    try require(
        rectGeo.x == 160 && rectGeo.y == 132 && rectGeo.width == 160 && rectGeo.height == 96,
        "Click-placed rectangle had unexpected geometry: \(rectGeo)"
    )

    // 1b. Armed drag placement for Diamond with live preview isolation before mouseUp
    canvas.activateToolFromDock(.shape(.diamond))
    let countBeforeDrag = (doc.session.root["nodes"] as? [Any])?.count ?? 0
    canvas.mouseDown(with: mouse(.leftMouseDown, world: CGPoint(x: 420, y: 120)))
    canvas.mouseDragged(with: mouse(.leftMouseDragged, world: CGPoint(x: 640, y: 260)))
    try require(
        canvas.hasActiveCreationDrag && ((doc.session.root["nodes"] as? [Any])?.count ?? 0) == countBeforeDrag,
        "Creation drag mutated session before mouseUp"
    )
    canvas.mouseUp(with: mouse(.leftMouseUp, world: CGPoint(x: 640, y: 260)))
    guard let diamondID = canvas.selectedNodeID,
          let diamondGeo = doc.session.geometry(of: diamondID) else {
        throw CheckFailure(description: "Drag placement did not commit diamond")
    }
    try require(
        !canvas.hasActiveCreationDrag &&
        canvas.activeCreationTool == CanvasCreationTool.select &&
        diamondGeo.x == 420 && diamondGeo.y == 120 && diamondGeo.width == 220 && diamondGeo.height == 140,
        "Dragged diamond had unexpected geometry: \(diamondGeo)"
    )

    // 1c. Armed drag placement for Arrow line
    canvas.activateToolFromDock(.line(.arrow))
    canvas.mouseDown(with: mouse(.leftMouseDown, world: CGPoint(x: 320, y: 180)))
    canvas.mouseDragged(with: mouse(.leftMouseDragged, world: CGPoint(x: 420, y: 190)))
    canvas.mouseUp(with: mouse(.leftMouseUp, world: CGPoint(x: 420, y: 190)))
    guard let arrowID = canvas.selectedNodeID,
          let arrowGeo = doc.session.lineGeometry(of: arrowID) else {
        throw CheckFailure(description: "Drag placement did not commit standalone arrow")
    }
    try require(
        arrowGeo.point(for: .start) == CanvasPosition(x: 320, y: 180) &&
        arrowGeo.point(for: .end) == CanvasPosition(x: 420, y: 190),
        "Dragged arrow endpoints did not match: \(arrowGeo)"
    )

    // 1d. Escape mid-drag cancels armed creation without mutating session or history
    canvas.activateToolFromDock(.shape(.ellipse))
    let preCancelNodes = (doc.session.root["nodes"] as? [Any])?.count ?? 0
    canvas.mouseDown(with: mouse(.leftMouseDown, world: CGPoint(x: 100, y: 400)))
    canvas.mouseDragged(with: mouse(.leftMouseDragged, world: CGPoint(x: 260, y: 520)))
    canvas.keyDown(with: key(53, characters: "\u{1b}"))
    try require(
        !canvas.hasActiveCreationDrag &&
        canvas.activeCreationTool == CanvasCreationTool.select &&
        ((doc.session.root["nodes"] as? [Any])?.count ?? 0) == preCancelNodes,
        "Escape did not cancel active creation drag cleanly"
    )

    // 1e. Shortcuts help sheet (? / ⌘/)
    canvas.keyDown(with: key(44, characters: "?"))
    try require(canvas.isShortcutsSheetOpen && canvas.activeShortcutsPanel != nil, "? did not open shortcuts reference sheet")
    if let closeBtn = canvas.activeShortcutsPanel?.contentView?.subviews.first(where: { $0.identifier?.rawValue == "shortcuts-close" }) as? NSButton {
        closeBtn.performClick(nil)
    }
    try require(!canvas.isShortcutsSheetOpen, "Shortcuts sheet did not close")

    // Slice 3: NSAccessibility exposure for nodes, connections, and selection
    let conn = try doc.session.insertConnection(source: rectID, target: diamondID, label: "flow")
    canvas.reloadFromSession(clearingUndoHistory: false)
    canvas.selectNode(rectID)
    try require(
        canvas.isAccessibilityElement() &&
        canvas.accessibilityRole() == .group &&
        canvas.accessibilityRoleDescription() == "spatial canvas",
        "CanvasView root accessibility metadata missing"
    )
    let a11yElements = canvas.accessibilityCanvasElements()
    try require(a11yElements.count == 4, "Expected 3 nodes + 1 connection in accessibilityCanvasElements, got \(a11yElements.count)")
    guard let rectA11y = a11yElements.first(where: { $0.elementID == rectID }),
          let connA11y = a11yElements.first(where: { $0.elementID == conn.id }) else {
        throw CheckFailure(description: "Missing node or connection in accessibilityCanvasElements")
    }
    try require(
        rectA11y.accessibilityIdentifier() == "canvas-node-\(rectID)" &&
        rectA11y.isAccessibilitySelected() &&
        rectA11y.accessibilityFrame().width > 0 &&
        connA11y.accessibilityIdentifier() == "canvas-connection-\(conn.id)" &&
        connA11y.accessibilityLabel()?.contains("flow") == true &&
        !connA11y.isAccessibilitySelected(),
        "Accessibility element attributes or selection state mismatch"
    )
    _ = connA11y.accessibilityPerformPress()
    try require(
        canvas.selectedConnectionID == conn.id &&
        (canvas.accessibilitySelectedChildren()?.count == 1),
        "accessibilityPerformPress did not select connection"
    )

    // Slice 2: Actionable in-window Conflict, Read-Only, and Save-Error status banner
    try require(canvas.statusBanner.isHidden, "Status banner should be hidden before saving/conflicts")
    let savedURL = tempRoot.appendingPathComponent("slice-banner.json")
    _ = try doc.saveDocumentAs(to: savedURL)
    recentStore.record(savedURL)
    delegate.rebuildOpenRecentMenu()
    try require(
        recentStore.recentURLs.first?.standardizedFileURL == savedURL.standardizedFileURL &&
        (fileSubmenu?.item(withTitle: "Open Recent")?.submenu?.items.first?.title == "slice-banner.json"),
        "Saved document was not recorded in Open Recent"
    )

    // External modification triggers immediate in-window conflict banner without waiting for ⌘S
    var externalRoot = doc.session.root
    externalRoot["nodes"] = []
    externalRoot["edges"] = []
    try CanvasDocument.encode(externalRoot).write(to: savedURL, options: .atomic)
    let detected = doc.checkExternalSourceStatus()
    try require(
        detected && !canvas.statusBanner.isHidden &&
        canvas.statusBanner.activeKind == CanvasStatusBannerView.BannerKind.conflict(doc.conflictReason!),
        "External change did not immediately display in-window conflict banner"
    )
    doc.dismissStatusBanner()
    try require(
        canvas.statusBanner.isHidden && doc.conflictReason != nil && doc.isStatusBannerDismissed,
        "Keep Editing on banner should hide banner while keeping conflict autosave pause active"
    )

    // 2b. While conflict banner is dismissed, a background recovery write failure MUST surface immediately
    let draftsSubdir = recoveryDir.appendingPathComponent("Drafts", isDirectory: true)
    try fm.createDirectory(at: draftsSubdir, withIntermediateDirectories: true)
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: recoveryDir.path)
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: draftsSubdir.path)
    _ = try? doc.writeRecoverySnapshotNow()
    try require(
        doc.lastRecoveryError != nil &&
        !canvas.statusBanner.isHidden &&
        canvas.statusBanner.activeKind == CanvasStatusBannerView.BannerKind.recoveryError(doc.lastRecoveryError!),
        "Recovery failure after dismissing conflict banner did not display recoveryError banner"
    )
    // Dismissing recoveryError banner preserves lastRecoveryError, and a subsequent recovery failure re-displays the banner
    doc.dismissStatusBanner()
    try require(
        canvas.statusBanner.isHidden && doc.lastRecoveryError != nil,
        "Dismissing recovery banner must preserve lastRecoveryError state"
    )
    _ = try? doc.writeRecoverySnapshotNow()
    try require(
        !canvas.statusBanner.isHidden &&
        canvas.statusBanner.activeKind == CanvasStatusBannerView.BannerKind.recoveryError(doc.lastRecoveryError!),
        "Subsequent recovery failure after dismissal did not re-show recoveryError banner"
    )
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: draftsSubdir.path)
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recoveryDir.path)
    try doc.writeRecoverySnapshotNow()
    try require(
        doc.lastRecoveryError == nil && canvas.statusBanner.isHidden,
        "Successful recovery write did not clear lastRecoveryError and hide recoveryError banner"
    )

    // 2c. Resolve conflict via Save As to a writable subdirectory, then trigger Save Error -> Dismiss -> new Save Error
    let saveSubdir = tempRoot.appendingPathComponent("SaveSubdir", isDirectory: true)
    try fm.createDirectory(at: saveSubdir, withIntermediateDirectories: true)
    let resolvedURL = saveSubdir.appendingPathComponent("resolved.json")
    _ = try doc.saveDocumentAs(to: resolvedURL)
    try require(doc.conflictReason == nil && canvas.statusBanner.isHidden, "Save As did not clear conflict state")

    _ = try doc.session.insertShape(.ellipse, at: CanvasPosition(x: 60, y: 60))
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: saveSubdir.path)
    doc.triggerScheduledAutosaveNow()
    try require(
        doc.lastSaveError != nil &&
        !canvas.statusBanner.isHidden &&
        canvas.statusBanner.activeKind == CanvasStatusBannerView.BannerKind.saveError(doc.lastSaveError!, canRetry: true),
        "Background autosave failure did not display saveError banner"
    )
    // Dismissing saveError banner MUST preserve lastSaveError and .saveFailed persistenceState
    doc.dismissStatusBanner()
    try require(
        canvas.statusBanner.isHidden &&
        doc.lastSaveError != nil &&
        doc.persistenceState == CanvasPersistenceState.saveFailed(message: doc.lastSaveError!, hasPendingDraft: false),
        "Dismissing saveError banner wiped lastSaveError or falsely cleared .saveFailed state"
    )
    // A subsequent failed save attempt MUST re-display the saveError banner even with the same error
    _ = try? doc.saveDocumentExplicitly()
    try require(
        !canvas.statusBanner.isHidden &&
        canvas.statusBanner.activeKind == CanvasStatusBannerView.BannerKind.saveError(doc.lastSaveError!, canRetry: true),
        "Subsequent save failure after banner dismissal did not re-display saveError banner"
    )
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: saveSubdir.path)
    _ = try doc.saveDocumentExplicitly()
    try require(
        doc.lastSaveError == nil && canvas.statusBanner.isHidden,
        "Successful save did not clear saveError banner"
    )

    // 2d. Delayed recovery write keeps connected fileURL invariant (single-writer reopen deduplication)
    // and guards saveDocumentAs while recovery is in flight:
    _ = try doc.session.insertShape(.triangle, at: CanvasPosition(x: 120, y: 120))
    var delayedRecoveryCompletion: (() -> Void)?
    doc.synchronousWaitTimeout = 0.02
    doc.saveCompletionDelayHook = { complete in
        delayedRecoveryCompletion = complete
    }
    do {
        try doc.writeRecoverySnapshotNow(requireAcknowledgement: true)
        throw CheckFailure(description: "writeRecoverySnapshotNow succeeded before delayed completion fired")
    } catch {}
    try require(
        delayedRecoveryCompletion != nil &&
        doc.isRecoveryWriteInFlight &&
        doc.fileURL?.standardizedFileURL == resolvedURL.standardizedFileURL,
        "Delayed recovery write cleared or mutated connected fileURL"
    )
    // Reopening resolvedURL while recovery completion is still pending MUST deduplicate to the existing document:
    let reopenedDuringRecovery = delegate.openDocument(resolvedURL)
    try require(
        reopenedDuringRecovery === doc && delegate.openNativeDocuments.count == 1,
        "openDocument failed single-writer deduplication during delayed recovery write"
    )
    // saveDocumentAs while recovery is still in flight beyond timeout MUST refuse cleanly:
    let postDelaySaveAsURL = saveSubdir.appendingPathComponent("post-delay-save-as.json")
    doc.saveCompletionDelayHook = nil
    do {
        _ = try doc.saveDocumentAs(to: postDelaySaveAsURL)
        throw CheckFailure(description: "saveDocumentAs succeeded while recovery write was still in flight")
    } catch is CanvasPersistenceError {}
    try require(
        doc.fileURL?.standardizedFileURL == resolvedURL.standardizedFileURL,
        "Refused saveDocumentAs during in-flight recovery changed fileURL"
    )
    // Complete the delayed recovery write, then perform Save As, and verify a second invocation of the old
    // completion closure cannot revert fileURL or autosavedContentsFileURL:
    doc.synchronousWaitTimeout = 5.0
    delayedRecoveryCompletion?()
    try require(!doc.isRecoveryWriteInFlight, "Delayed recovery completion did not clear isRecoveryWriteInFlight")
    _ = try doc.saveDocumentAs(to: postDelaySaveAsURL)
    delayedRecoveryCompletion?()
    try require(
        doc.fileURL?.standardizedFileURL == postDelaySaveAsURL.standardizedFileURL &&
        doc.displayNameTitle == "post-delay-save-as.json" &&
        doc.persistenceState == CanvasPersistenceState.saved(hasPendingDraft: false) &&
        doc.autosavedContentsFileURL == nil,
        "Late recovery callback reverted Save As destination URL or dirtied saved state"
    )

    // Read-only file opens with Read-Only status banner visible
    let readOnlyURL = tempRoot.appendingPathComponent("readonly-banner.json")
    try CanvasDocument.encode(try CanvasDocument.blank().root).write(to: readOnlyURL)
    try fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnlyURL.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: readOnlyURL.path) }
    guard let roDoc = delegate.openDocument(readOnlyURL) else {
        throw CheckFailure(description: "Failed to open read-only document for banner check")
    }
    try require(
        !roDoc.canvasView.statusBanner.isHidden &&
        roDoc.canvasView.statusBanner.activeKind == CanvasStatusBannerView.BannerKind.readOnly(roDoc.readOnlyReason ?? ""),
        "Read-only document did not display in-window read-only status banner"
    )

    // Welcome window shows recent document quick-open button
    delegate.closeAllWindows()
    delegate.showWelcome()
    defer { delegate.closeAllWindows() }
    let plistPath = repository.appendingPathComponent("macos/Info.plist")
    let plistDict = NSDictionary(contentsOf: plistPath) as? [String: Any]
    try require(
        plistDict?["CFBundleShortVersionString"] as? String == "1.0",
        "Info.plist CFBundleShortVersionString is not 1.0"
    )
    print("PASS v1.0 release slices: NSToolbar, floating tool dock, click/drag tool creation, Open Recent, shortcuts sheet (?), in-window conflict/read-only banner, NSAccessibility elements, and v1.0 bundle metadata")
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    let repoFonts = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/Fonts", isDirectory: true)
    if args.count == 2 && args[0] == "--export-roundtrip" {
        CanvasTypography.customFontDirectoryURL = repoFonts
        try exportCrossEditorRoundTrip(in: URL(fileURLWithPath: args[1]))
    } else if args.count == 2 && args[0] == "--verify-roundtrip" {
        CanvasTypography.customFontDirectoryURL = repoFonts
        try verifyCrossEditorRoundTrip(in: URL(fileURLWithPath: args[1]))
    } else if args.count == 3 && args[0] == "--export-png" {
        CanvasTypography.customFontDirectoryURL = repoFonts
        let doc = try CanvasDocument(data: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let session = CanvasSession(document: doc)
        try MainActor.assumeIsolated {
            let view = CanvasView(session: session)
            try view.exportPNG(to: URL(fileURLWithPath: args[2]))
        }
    } else if args.count == 3 && args[0] == "--child-crash-writer" {
        CanvasTypography.customFontDirectoryURL = repoFonts
        try MainActor.assumeIsolated {
            try runChildCrashWriter(recoveryDirPath: args[1], readyFlagPath: args[2])
        }
    } else if args.count == 3 && args[0] == "--child-crash-restorer" {
        CanvasTypography.customFontDirectoryURL = repoFonts
        try MainActor.assumeIsolated {
            try runChildCrashRestorer(recoveryDirPath: args[1], outputPath: args[2])
        }
    } else if args.count == 2 && args[0] == "--verify-standalone-workflow" {
        // Do NOT set customFontDirectoryURL: must resolve fonts strictly from inside the .app bundle!
        try MainActor.assumeIsolated {
            try runStandaloneWorkflowVerification(in: URL(fileURLWithPath: args[1], isDirectory: true))
        }
    } else if args.count == 2 && args[0] == "--generate-icns" {
        let fm = FileManager.default
        let iconsetURL = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset", isDirectory: true)
        try fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: iconsetURL) }
        for (name, px) in [
            ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
        ] {
            guard let png = CanvasTheme.appIconPNGData(pixelSize: px) else {
                throw CheckFailure(description: "Failed to render \(name)")
            }
            try png.write(to: iconsetURL.appendingPathComponent(name))
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        proc.arguments = ["-c", "icns", "-o", args[1], iconsetURL.path]
        try proc.run()
        proc.waitUntilExit()
        try require(proc.terminationStatus == 0, "iconutil failed with status \(proc.terminationStatus)")
    } else {
        try runChecks()
        print("All native document checks passed.")
    }
} catch {
    fputs("Native document check failed: \(error)\n", stderr)
    exit(1)
}
