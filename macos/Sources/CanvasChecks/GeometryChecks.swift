import AppKit
import CanvasCore
import CanvasUI

@MainActor
func checkGeometry(repository: URL) throws {
    func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
    let quarterTurn = CanvasGeometry(x: 100, y: 200, width: 160, height: 80, rotation: 90)
    let enlarged = quarterTurn.resized(handle: .bottomRight, localDelta: CanvasPosition(x: 40, y: 20))
    try require(close(enlarged.x, 70) && close(enlarged.y, 210) &&
                close(enlarged.width, 200) && close(enlarged.height, 100),
                "Rotated resize did not keep the opposite anchor fixed")
    let fixed = enlarged.point(for: .topLeft)
    try require(close(fixed.x, 220) && close(fixed.y, 160), "Rotated resize moved its fixed corner")
    let opposite: [CanvasGeometryHandle: CanvasGeometryHandle] = [
        .topLeft: .bottomRight, .top: .bottom, .topRight: .bottomLeft, .right: .left,
        .bottomRight: .topLeft, .bottom: .top, .bottomLeft: .topRight, .left: .right
    ]
    for rotation in [-45.0, 0, 30, 90, 725] {
        let original = CanvasGeometry(x: -40, y: 80, width: 160, height: 96, rotation: rotation)
        for (handle, anchor) in opposite {
            let resized = original.resized(handle: handle, localDelta: CanvasPosition(x: 24, y: -12))
            let before = original.point(for: anchor), after = resized.point(for: anchor)
            try require(close(before.x, after.x) && close(before.y, after.y),
                        "Resize moved opposite anchor for \(handle) at \(rotation) degrees")
        }
    }
    let small = CanvasGeometry(x: 0, y: 0, width: 0.25, height: 0.5)
    try require(small.resized(handle: .bottomRight, localDelta: CanvasPosition(x: 0, y: 0)) == small,
                "No-op resize changed an authored sub-unit box")
    let clamped = quarterTurn.resized(handle: .right, localDelta: CanvasPosition(x: -1000, y: 0))
    try require(clamped.width == 1 && close(clamped.point(for: .left).x, quarterTurn.point(for: .left).x) &&
                close(clamped.point(for: .left).y, quarterTurn.point(for: .left).y),
                "Crossing a resize anchor flipped or moved it")

    for (fixture, id) in [("v1/compatibility.json", "ellipse"), ("v2/code-compatibility.json", "code-explicit")] {
        let bytes = try Data(contentsOf: repository.appendingPathComponent("shared/fixtures/\(fixture)"))
        let document = try CanvasDocument(data: bytes)
        let model = CanvasSession(document: document)
        let before = model.geometry(of: id)!
        let after = before.resized(handle: .topLeft, localDelta: CanvasPosition(x: -20, y: -30)).rotated(by: 15)
        _ = try model.setGeometry(id, to: after)
        _ = try CanvasDocument(data: encoded(model.root))
        _ = try model.setGeometry(id, to: before)
        try require(NSDictionary(dictionary: model.root).isEqual(to: document.root),
                    "Geometry restoration lost \(fixture) metadata, code source or attachment content")
        try require(model.document.originalData == bytes, "Geometry editing changed original bytes")
    }

    let nodes: [[String: Any]] = [
        ["id": "source", "type": "shape", "x": 100, "y": 100, "width": 160, "height": 96,
         "data": ["kind": "rect", "fill": "none", "stroke": "ink", "radius": 0,
                  "custom": ["retained": true]]],
        ["id": "target", "type": "shape", "x": 500, "y": 100, "width": 160, "height": 96,
         "data": ["kind": "rect", "fill": "none", "stroke": "ink", "radius": 0]],
        ["id": "locked", "type": "shape", "x": 800, "y": 100, "width": 160, "height": 96,
         "locked": true, "data": ["kind": "rect"]],
        ["id": "code", "type": "code", "x": 100, "y": 400, "width": 200, "height": 100,
         "data": ["content": "\u{feff}literal <code>\r\n", "language": "future-language", "custom": 42]],
        ["id": "line", "type": "shape-line", "x": 500, "y": 400, "width": 160, "height": 40,
         "data": ["from": [0, 0], "to": [160, 40]]]
    ]
    let root: [String: Any] = [
        "version": 2, "nodes": nodes, "paper": ["background": "none"],
        "edges": [["id": "edge", "source": "source", "target": "target",
                   "source_handle": "right", "target_handle": "left", "path": "bezier", "marker": "arrow"]]
    ]
    let bytes = try encoded(root)
    let model = CanvasSession(document: try CanvasDocument(data: bytes))
    for geometry in [
        CanvasGeometry(x: .nan, y: 0, width: 160, height: 96),
        CanvasGeometry(x: 0, y: 0, width: 0, height: 96),
        CanvasGeometry(x: 0, y: 0, width: 1_000_001, height: 96),
        CanvasGeometry(x: 0, y: 0, width: 160, height: 96, rotation: .infinity)
    ] {
        do {
            _ = try model.setGeometry("source", to: geometry)
            throw CheckFailure(description: "Invalid geometry was accepted")
        } catch is CanvasDocumentError {}
        try require(NSDictionary(dictionary: model.root).isEqual(to: root),
                    "Refused geometry changed committed content")
    }
    let view = CanvasView(session: model)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
    scroll.documentView = view
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scroll
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    func mouse(_ type: NSEvent.EventType, _ world: CanvasPosition) {
        let point = view.viewPoint(forWorldPoint: CGPoint(x: world.x, y: world.y))
        let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
    }
    func key(_ code: UInt16, _ characters: String = "", shift: Bool = false) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                    isARepeat: false, keyCode: code)!
        view.keyDown(with: event)
    }
    func select(_ x: Double, _ y: Double) {
        mouse(.leftMouseDown, CanvasPosition(x: x, y: y))
        mouse(.leftMouseUp, CanvasPosition(x: x, y: y))
    }
    func sample(_ world: CGPoint) -> NSColor {
        let point = view.viewPoint(forWorldPoint: world)
        let rect = CGRect(x: point.x - 1, y: point.y - 1, width: 3, height: 3)
        let bitmap = view.bitmapImageRepForCachingDisplay(in: rect)!
        view.cacheDisplay(in: rect, to: bitmap)
        return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
    }
    func difference(_ a: NSColor, _ b: NSColor) -> CGFloat {
        abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent)
    }
    let background = sample(CGPoint(x: 380, y: 300))
    select(180, 148)
    let initial = model.geometry(of: "source")!
    mouse(.leftMouseDown, initial.point(for: .bottomRight))
    mouse(.leftMouseDragged, CanvasPosition(x: 300, y: 236))
    try require(NSDictionary(dictionary: model.root).isEqual(to: root), "Pointer preview leaked into committed JSON")
    try require(difference(sample(CGPoint(x: 380, y: 148)), background) < 0.05 &&
                difference(sample(CGPoint(x: 400, y: 158)), background) > 0.2,
                "Connections did not follow the resize preview")
    mouse(.leftMouseUp, CanvasPosition(x: 300, y: 236))
    let committedResize = model.geometry(of: "source")!
    try require(close(committedResize.x, 100) && close(committedResize.y, 100) &&
                close(committedResize.width, 200) && close(committedResize.height, 136) &&
                committedResize.rotation == nil, "Pointer resize did not commit the authored box")
    let resizedRoot = model.root
    view.undoMove(nil)
    try require(NSDictionary(dictionary: model.root).isEqual(to: root), "Resize Undo lost metadata or omitted rotation")
    view.redoMove(nil)
    try require(NSDictionary(dictionary: model.root).isEqual(to: resizedRoot), "Resize Redo did not restore geometry")
    view.undoMove(nil)
    mouse(.leftMouseDown, initial.point(for: .right))
    mouse(.leftMouseDragged, CanvasPosition(x: 400, y: 148))
    key(53)
    mouse(.leftMouseUp, CanvasPosition(x: 400, y: 148))
    try require(NSDictionary(dictionary: model.root).isEqual(to: root) && view.undoManager?.canRedo == true,
                "Pointer Escape changed content/history")
    try require(difference(sample(CGPoint(x: 380, y: 148)), background) > 0.2,
                "Cancellation did not restore the original connection route")

    mouse(.leftMouseDown, initial.point(for: .rotation))
    mouse(.leftMouseDragged, CanvasPosition(x: 256, y: 148))
    try require(model.geometry(of: "source") == initial, "Rotation preview committed too early")
    try require(difference(sample(CGPoint(x: 260, y: 170)), background) < 0.05,
                "Rotation preview left the original shape outline visible")
    mouse(.leftMouseUp, CanvasPosition(x: 256, y: 148))
    try require(close(model.geometry(of: "source")!.rotation ?? 0, 90), "Pointer rotation did not commit 90 degrees")
    let rotated = model.geometry(of: "source")!
    let fixedAnchor = rotated.point(for: .topLeft)
    let resizeStart = rotated.point(for: .bottomRight)
    let resizeEnd = CanvasPosition(x: resizeStart.x - 20, y: resizeStart.y + 40)
    mouse(.leftMouseDown, resizeStart)
    mouse(.leftMouseDragged, resizeEnd)
    try require(model.geometry(of: "source") == rotated, "Rotated resize preview committed too early")
    mouse(.leftMouseUp, resizeEnd)
    let rotatedResize = model.geometry(of: "source")!
    let retainedAnchor = rotatedResize.point(for: .topLeft)
    try require(close(rotatedResize.width, 200) && close(rotatedResize.height, 116) &&
                close(fixedAnchor.x, retainedAnchor.x) && close(fixedAnchor.y, retainedAnchor.y),
                "Pointer resize used screen axes instead of rotated local axes")
    view.undoMove(nil)
    try require(model.geometry(of: "source") == rotated, "Resize Undo lost the preceding rotation")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: model.root).isEqual(to: root), "Rotation Undo materialized an omitted default")
    mouse(.leftMouseDown, initial.point(for: .rotation))
    for point in [CanvasPosition(x: 256, y: 148), CanvasPosition(x: 180, y: 224),
                  CanvasPosition(x: 104, y: 148), CanvasPosition(x: 180, y: 72)] {
        mouse(.leftMouseDragged, point)
    }
    mouse(.leftMouseUp, CanvasPosition(x: 180, y: 72))
    try require(close(model.geometry(of: "source")!.rotation ?? 0, 360), "Rotation jumped at the atan2 branch cut")
    view.undoMove(nil)

    key(5, "g")
    key(124)
    key(125, shift: true)
    try require(NSDictionary(dictionary: model.root).isEqual(to: root) && view.hasGeometryPreview,
                "Keyboard geometry preview leaked into JSON")
    key(15, "r")
    try require((model.root["nodes"] as! [Any]).count == nodes.count, "A drawing shortcut escaped geometry mode")
    key(48)
    key(48, shift: true)
    key(36)
    try require(model.geometry(of: "source") == CanvasGeometry(x: 100, y: 100, width: 161, height: 106),
                "Keyboard handle cycle lost its accumulated resize")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: model.root).isEqual(to: root), "Keyboard resize did not undo once")
    key(5, "g")
    key(36)
    try require(view.undoManager?.canRedo == true && NSDictionary(dictionary: model.root).isEqual(to: root),
                "No-op geometry commit changed content/redo")
    key(5, "g")
    key(124)
    view.undoMove(nil)
    try require(!view.hasGeometryPreview && view.undoManager?.canRedo == true &&
                NSDictionary(dictionary: model.root).isEqual(to: root), "Undo failed to cancel pending geometry first")
    key(5, "g")
    for _ in 0..<4 { key(48) } // Bottom-right → bottom → bottom-left → left → rotation.
    key(124)
    key(123, shift: true)
    key(36)
    try require(model.geometry(of: "source")?.rotation == -14, "Keyboard rotation increments were wrong")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: model.root).isEqual(to: root), "Keyboard rotation Undo lost original graph")

    select(880, 148)
    key(5, "g")
    try require(!view.hasGeometryPreview && !view.canEditGeometry, "Locked object entered geometry mode")
    do {
        _ = try model.setGeometry("locked", to: initial)
        throw CheckFailure(description: "Locked object accepted geometry")
    } catch is CanvasDocumentError {}
    select(580, 420)
    do {
        _ = try model.setGeometry("line", to: initial)
        throw CheckFailure(description: "Standalone endpoints were box-resized")
    } catch is CanvasDocumentError {}
    try require(view.canEditGeometry && !view.hasGeometryPreview,
                "Selected unlocked line did not expose endpoint editing")
    // No-op G -> Return and net-zero G -> Right -> Left -> Return on line must preserve non-padded authored box and redo history.
    key(5, "g")
    try require(view.hasGeometryPreview, "G on standalone line did not enter endpoint mode")
    key(36)
    try require(!view.hasGeometryPreview && view.undoManager?.canRedo == true &&
                NSDictionary(dictionary: model.root).isEqual(to: root),
                "No-op line endpoint commit rewrote authored box or cleared redo")
    key(5, "g")
    key(124) // Right (+1)
    key(123) // Left (-1, returning endpoint to baseline)
    key(36)
    try require(!view.hasGeometryPreview && view.undoManager?.canRedo == true &&
                NSDictionary(dictionary: model.root).isEqual(to: root),
                "Net-zero G -> Right -> Left -> Return canonicalized the non-padded line box or cleared redo")
    // Keyboard endpoint editing: nudge start (-10, 0), Tab to end, nudge end (0, +1), Tab back/forth, Return.
    key(5, "g")
    key(123, shift: true) // Start: (500, 400) -> (490, 400)
    key(48) // Tab to End
    key(125) // End: (660, 440) -> (660, 441)
    key(48, shift: true) // Shift-Tab to Start
    key(48) // Tab to End
    try require(NSDictionary(dictionary: model.root).isEqual(to: root) && view.hasGeometryPreview,
                "Keyboard line endpoint preview leaked into committed JSON")
    key(15, "r")
    key(37, "l")
    key(0, "a")
    try require((model.root["nodes"] as! [Any]).count == nodes.count,
                "Creation shortcuts escaped active line endpoint preview")
    key(36)
    let expectedKeyboardLine = CanvasLineGeometry(
        start: CanvasPosition(x: 490, y: 400),
        end: CanvasPosition(x: 660, y: 441)
    )
    try require(model.lineGeometry(of: "line") == expectedKeyboardLine &&
                expectedKeyboardLine.x == 478 && expectedKeyboardLine.y == 388 &&
                expectedKeyboardLine.width == 194 && expectedKeyboardLine.height == 65 &&
                expectedKeyboardLine.from == CanvasPosition(x: 12, y: 12) &&
                expectedKeyboardLine.to == CanvasPosition(x: 182, y: 53),
                "Keyboard endpoint commit did not compute canonical 12-unit padded box and relative endpoints")
    let editedLineRoot = model.root
    view.undoMove(nil)
    try require(NSDictionary(dictionary: model.root).isEqual(to: root),
                "Undo line endpoint edit did not restore exact original box and endpoints")
    view.redoMove(nil)
    try require(NSDictionary(dictionary: model.root).isEqual(to: editedLineRoot),
                "Redo line endpoint edit did not restore committed endpoints")
    view.undoMove(nil)

    // Pointer endpoint drag: reverse end < start into a horizontal segment (460, 400) <- (500, 400), plus Escape cancel.
    mouse(.leftMouseDown, CanvasPosition(x: 660, y: 440))
    mouse(.leftMouseDragged, CanvasPosition(x: 460, y: 400))
    try require(NSDictionary(dictionary: model.root).isEqual(to: root),
                "Pointer line endpoint preview committed before mouseUp")
    try require(difference(sample(CGPoint(x: 480, y: 400)), background) > 0.2 &&
                difference(sample(CGPoint(x: 620, y: 430)), background) < 0.05,
                "Pointer line endpoint preview did not redraw the segment at its new position")
    mouse(.leftMouseUp, CanvasPosition(x: 460, y: 400))
    let reversedLine = model.lineGeometry(of: "line")!
    try require(reversedLine.point(for: .start) == CanvasPosition(x: 500, y: 400) &&
                reversedLine.point(for: .end) == CanvasPosition(x: 460, y: 400) &&
                reversedLine.width == 64 && reversedLine.height == 24 &&
                reversedLine.from == CanvasPosition(x: 52, y: 12) &&
                reversedLine.to == CanvasPosition(x: 12, y: 12),
                "Reversed horizontal pointer endpoint drag did not preserve positive box and direction")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: model.root).isEqual(to: root),
                "Undo pointer endpoint drag did not restore original line")
    mouse(.leftMouseDown, CanvasPosition(x: 500, y: 400))
    mouse(.leftMouseDragged, CanvasPosition(x: 500, y: 320))
    key(53) // Escape cancels pointer endpoint drag
    mouse(.leftMouseUp, CanvasPosition(x: 500, y: 320))
    try require(NSDictionary(dictionary: model.root).isEqual(to: root) && view.undoManager?.canRedo == true,
                "Pointer Escape on line endpoint changed content or cleared redo")

    // Standalone Line (L) and Arrow (A) insertion, free-standing connection refusal, and AppDelegate Insert menu smoke.
    view.undoManager?.removeAllActions()
    key(37, "l") // Insert Line at viewport center
    let insertedLineRaw = (model.root["nodes"] as! [[String: Any]]).last!
    let insertedLineID = insertedLineRaw["id"] as! String
    let insertedLineData = insertedLineRaw["data"] as! [String: Any]
    try require(insertedLineRaw["type"] as? String == "shape-line" &&
                insertedLineData["arrow"] as? String == "none" &&
                insertedLineData["font"] == nil &&
                view.selectedNodeID == insertedLineID,
                "L shortcut did not insert and select an arrowless standalone line")
    let lineGeo = model.lineGeometry(of: insertedLineID)!
    let lineMid = view.viewPoint(forWorldPoint: CGPoint(
        x: (lineGeo.point(for: .start).x + lineGeo.point(for: .end).x) / 2,
        y: (lineGeo.point(for: .start).y + lineGeo.point(for: .end).y) / 2
    ))
    try require(abs(lineMid.x - view.visibleRect.midX) < 0.01 &&
                abs(lineMid.y - view.visibleRect.midY) < 0.01 &&
                lineGeo.width == 184 && lineGeo.height == 24,
                "Inserted line was not centered in the viewport with 160-unit span and 12-unit padding")
    do {
        _ = try model.insertConnection(source: insertedLineID, target: "source")
        throw CheckFailure(description: "Connected a bound edge from a standalone line")
    } catch is CanvasDocumentError {}
    do {
        _ = try model.insertConnection(source: "source", target: insertedLineID)
        throw CheckFailure(description: "Connected a bound edge to a standalone line")
    } catch is CanvasDocumentError {}
    view.undoMove(nil)
    try require(NSDictionary(dictionary: model.root).isEqual(to: root), "Undo Line insertion did not restore graph")
    view.redoMove(nil)
    try require((model.root["nodes"] as! [[String: Any]]).last?["id"] as? String == insertedLineID,
                "Redo Line insertion lost identity")
    view.undoMove(nil)

    key(0, "a") // Insert Arrow at viewport center
    let insertedArrowRaw = (model.root["nodes"] as! [[String: Any]]).last!
    let insertedArrowID = insertedArrowRaw["id"] as! String
    try require(insertedArrowRaw["type"] as? String == "shape-line" &&
                (insertedArrowRaw["data"] as? [String: Any])?["arrow"] as? String == "end",
                "A shortcut did not insert a standalone arrow")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: model.root).isEqual(to: root) && insertedArrowID != insertedLineID,
                "Undo Arrow insertion did not restore graph")

    // Exercise Insert -> Line and Insert -> Arrow via CanvasAppDelegate menus and Edit -> Edit Geometry on the arrow.
    let appDelegate = CanvasAppDelegate()
    appDelegate.installMenu()
    let appSession = CanvasSession(document: try CanvasDocument(data: bytes))
    let appCanvas = appDelegate.showSession(appSession, name: "LineMenuSmoke")
    defer { appDelegate.closeAllWindows() }
    guard let insertMenu = NSApp.mainMenu?.item(withTitle: "Insert")?.submenu,
          let editMenu = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu,
          let lineMenuItem = insertMenu.item(withTitle: "Line"),
          let arrowMenuItem = insertMenu.item(withTitle: "Arrow"),
          let editGeoItem = editMenu.item(withTitle: "Edit Geometry") else {
        throw CheckFailure(description: "Missing Line, Arrow, or Edit Geometry menu item")
    }
    try require(appDelegate.validateMenuItem(lineMenuItem) && appDelegate.validateMenuItem(arrowMenuItem),
                "Insert Line/Arrow menu items were disabled on active canvas")
    _ = appDelegate.perform(arrowMenuItem.action!, with: arrowMenuItem)
    let menuArrowID = appCanvas.selectedNodeID!
    try require(appSession.lineGeometry(of: menuArrowID) != nil &&
                appDelegate.validateMenuItem(editGeoItem),
                "Insert -> Arrow did not select an endpoint-editable arrow")
    _ = appDelegate.perform(editGeoItem.action!, with: editGeoItem)
    try require(appCanvas.hasGeometryPreview && !appDelegate.validateMenuItem(lineMenuItem) &&
                !appDelegate.validateMenuItem(arrowMenuItem) && !appDelegate.validateMenuItem(editGeoItem),
                "Edit -> Edit Geometry on arrow did not enter endpoint preview and disable Insert/Edit Geometry")
    appDelegate.undoMove(nil) // Cancels endpoint preview first
    try require(!appCanvas.hasGeometryPreview && appSession.lineGeometry(of: menuArrowID) != nil,
                "Undo during line endpoint preview deleted the arrow instead of cancelling the preview")
    appDelegate.undoMove(nil) // Undoes arrow insertion
    try require(NSDictionary(dictionary: appSession.root).isEqual(to: root),
                "Second Undo did not remove the menu-inserted arrow")
    select(200, 450)
    key(5, "g")
    key(124, shift: true)
    key(36)
    let codeData = ((model.root["nodes"] as! [[String: Any]])[3]["data"] as! NSDictionary)
    try require(model.geometry(of: "code")?.width == 210 && codeData.isEqual(to: nodes[3]["data"] as! [String: Any]),
                "Code resize changed literal source/language/metadata")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: model.root).isEqual(to: root) && model.document.originalData == bytes,
                "Geometry operations did not retain original graph/source bytes")
    print("PASS geometry: rotated anchors, preview isolation, pointer/keyboard commit/cancel, connector redraw, history and protected content")
    window.orderOut(nil)
}
