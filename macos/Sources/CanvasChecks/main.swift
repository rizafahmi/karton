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
        guard let sheet = window.attachedSheet,
              let editor = sheet.firstResponder as? NSTextView else {
            throw CheckFailure(description: "Native text sheet did not focus its editor")
        }
        return editor
    }
    view.keyDown(with: key(36))
    try require(window.attachedSheet == nil, "Locked shape opened a text editor")
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
    try require(window.attachedSheet == nil, "Commit left sheet open")
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
    try require(window.attachedSheet != nil && session.text(of: "moving") == caption,
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
    try require(window.attachedSheet != nil &&
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
    try checkStyles(repository: repository)
    try checkLiteralJSON()
    try checkCompatibilityRoundTrips(repository: repository)
    try checkTheme(repository: repository)
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
    print("PASS Neo-Acid light mode palette, highlighter/ink text contrast and bitmap rendering")
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.count == 2 && args[0] == "--export-roundtrip" {
        try exportCrossEditorRoundTrip(in: URL(fileURLWithPath: args[1]))
    } else if args.count == 2 && args[0] == "--verify-roundtrip" {
        try verifyCrossEditorRoundTrip(in: URL(fileURLWithPath: args[1]))
    } else {
        try runChecks()
        print("All native document checks passed.")
    }
} catch {
    fputs("Native document check failed: \(error)\n", stderr)
    exit(1)
}
