import AppKit
import CanvasCore
import CanvasUI

@MainActor
func checkConnections(repository: URL) throws {
    let document = try CanvasDocument.blank()
    let session = CanvasSession(document: document)
    let source = try session.insertShape(.rectangle, at: CanvasPosition(x: 100, y: 100))
    let target = try session.insertShape(.rectangle, at: CanvasPosition(x: 500, y: 100))
    let disconnected = session.root
    for (from, fromSide, to, toSide) in [
        (source.id, nil, "missing", nil),
        ("missing", nil, target.id, nil),
        (source.id, nil, source.id, nil),
        (source.id, CanvasConnectionSide.top, source.id, .top),
        (source.id, .right, source.id, nil)
    ] as [(String, CanvasConnectionSide?, String, CanvasConnectionSide?)] {
        do {
            _ = try session.insertConnection(source: from, sourceSide: fromSide, target: to, targetSide: toSide)
            throw CheckFailure(description: "Accepted an invalid connection")
        } catch is CanvasDocumentError {}
        try require(NSDictionary(dictionary: session.root).isEqual(to: disconnected),
                    "Refused connection changed committed content")
    }
    let insertion = try session.insertConnection(source: source.id, target: target.id)
    let connected = session.root
    do {
        try session.removeInsertion(source)
        throw CheckFailure(description: "Removed an endpoint while its connection existed")
    } catch is CanvasDocumentError {}
    try require(NSDictionary(dictionary: session.root).isEqual(to: connected),
                "Refused endpoint removal changed the graph")
    try session.removeInsertion(insertion)
    try session.restoreInsertion(insertion)
    try require(NSDictionary(dictionary: session.root).isEqual(to: connected),
                "Connection restoration lost identity or retained graph metadata")
    try session.removeInsertion(insertion)

    let v1Document = try CanvasDocument(data: Data(contentsOf:
        repository.appendingPathComponent("shared/fixtures/v1/compatibility.json")))
    let v1 = CanvasSession(document: v1Document)
    let v1Nodes = v1.root["nodes"] as! [[String: Any]]
    let v1Connection = try v1.insertConnection(source: v1Nodes[0]["id"] as! String,
                                             target: v1Nodes[1]["id"] as! String)
    _ = try CanvasDocument(data: encoded(v1.root))
    try require(v1.root["version"] as? Int == 1, "Connection creation upgraded v1")
    try v1.removeInsertion(v1Connection)
    try require(NSDictionary(dictionary: v1.root).isEqual(to: v1Document.root),
                "Connection undo changed existing v1 metadata/edges")

    // Exercise the real native sheet, controls, focus, and rendered connection.
    var root = session.root
    root["paper"] = ["background": "none"]
    let sourceBytes = try encoded(root)
    let uiSession = CanvasSession(document: try CanvasDocument(data: sourceBytes))
    let view = CanvasView(session: uiSession)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    scroll.documentView = view
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scroll
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)
    func key(_ code: UInt16, characters: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.attachedSheet?.windowNumber ?? window.windowNumber,
                        context: nil, characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: code)!
    }
    func control<T: NSView>(_ id: String, as type: T.Type) throws -> T {
        guard let control = window.attachedSheet?.contentView?.subviews.first(where: {
            $0.identifier?.rawValue == id
        }) as? T else { throw CheckFailure(description: "Missing native control: \(id)") }
        return control
    }
    func clickSource() {
        let point = view.viewPoint(forWorldPoint: CGPoint(x: 180, y: 148))
        let location = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 1, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { view.mouseDown(with: event) }
            else { view.mouseUp(with: event) }
        }
    }
    func snapshot() -> NSBitmapImageRep {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
    func color(_ bitmap: NSBitmapImageRep, at world: CGPoint) -> NSColor {
        let point = view.viewPoint(forWorldPoint: world)
        let x = Int(point.x * CGFloat(bitmap.pixelsWide) / view.bounds.width)
        let y = Int(point.y * CGFloat(bitmap.pixelsHigh) / view.bounds.height)
        return bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    }
    func difference(_ first: NSColor, _ second: NSColor) -> CGFloat {
        abs(first.redComponent - second.redComponent) + abs(first.greenComponent - second.greenComponent) +
        abs(first.blueComponent - second.blueComponent)
    }
    clickSource()
    let originalRoot = uiSession.root
    let midpoint = CGPoint(x: 380, y: 148)
    let background = color(snapshot(), at: midpoint)
    view.keyDown(with: key(8, characters: "c"))
    let sourcePopup = try control("connection-source", as: NSPopUpButton.self)
    let targetPopup = try control("connection-target", as: NSPopUpButton.self)
    try require(sourcePopup.indexOfSelectedItem == 0 && targetPopup.indexOfSelectedItem == 1,
                "Connection sheet did not use selected source and a distinct target")
    try require(window.attachedSheet?.firstResponder === targetPopup, "Connection target did not receive keyboard focus")
    try require(NSDictionary(dictionary: uiSession.root).isEqual(to: originalRoot), "Opening connection sheet changed content")
    try control("connection-create", as: NSButton.self).performClick(nil)
    try require(window.attachedSheet == nil, "Connection commit did not dismiss sheet")
    let normalConnection = uiSession.root
    let edge = (normalConnection["edges"] as! [[String: Any]]).last!
    let edgeID = edge["id"] as! String
    try require(edge["source"] as? String == source.id && edge["target"] as? String == target.id,
                "Sheet connected the wrong endpoints")
    try require(edge["source_handle"] == nil && edge["target_handle"] == nil,
                "Automatic sides were materialized as named sides")
    try require(difference(color(snapshot(), at: midpoint), background) > 0.2,
                "Committed connection was not drawn between its endpoints")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: uiSession.root).isEqual(to: originalRoot), "Connection did not undo as one transaction")
    try require(difference(color(snapshot(), at: midpoint), background) < 0.05,
                "Undo left the removed connection visible")
    view.beginConnection()
    let cancel = try control("connection-cancel", as: NSButton.self)
    cancel.performClick(nil)
    try require(NSDictionary(dictionary: uiSession.root).isEqual(to: originalRoot) && view.undoManager?.canRedo == true,
                "Cancellation changed content or cleared redo")
    view.redoMove(nil)
    try require(NSDictionary(dictionary: uiSession.root).isEqual(to: normalConnection), "Redo changed connection identity/metadata")

    // Move only the target through actual pointer events; the bound arrow must follow.
    let oldTarget = view.viewPoint(forWorldPoint: CGPoint(x: 580, y: 148))
    let newTarget = CGPoint(x: oldTarget.x, y: oldTarget.y + 200)
    for (type, point) in [(NSEvent.EventType.leftMouseDown, oldTarget), (.leftMouseDragged, newTarget), (.leftMouseUp, newTarget)] {
        let event = NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                      context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
    }
    let moved = snapshot()
    try require(difference(color(moved, at: midpoint), background) < 0.05,
                "Moving an endpoint left a stale connection route")
    try require(difference(color(moved, at: CGPoint(x: 380, y: 248)), background) > 0.2,
                "Connection did not redraw at its moved endpoints")
    try require(NSDictionary(dictionary: (uiSession.root["edges"] as! [[String: Any]])[0]).isEqual(to: edge),
                "Endpoint movement rewrote connection metadata")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: uiSession.root).isEqual(to: normalConnection), "Undo endpoint move changed the connection")

    // A self-loop is refused while Automatic/same-side, without losing its draft choices.
    clickSource()
    view.beginConnection()
    try control("connection-target", as: NSPopUpButton.self).selectItem(at: 0)
    try control("connection-create", as: NSButton.self).performClick(nil)
    let connectionError = try control("connection-error", as: NSTextField.self)
    try require(window.attachedSheet != nil && !connectionError.isHidden,
                "Invalid self-loop was not retained with an error")
    try require(NSDictionary(dictionary: uiSession.root).isEqual(to: normalConnection), "Invalid self-loop changed the graph")
    try control("connection-source-side", as: NSPopUpButton.self).selectItem(at: 1)
    try control("connection-target-side", as: NSPopUpButton.self).selectItem(at: 1)
    try control("connection-create", as: NSButton.self).performClick(nil)
    try require(window.attachedSheet != nil, "Same-side self-loop was committed")
    try control("connection-source-side", as: NSPopUpButton.self).selectItem(at: 2)
    try control("connection-create", as: NSButton.self).performClick(nil)
    let selfConnected = uiSession.root
    let loop = (selfConnected["edges"] as! [[String: Any]]).last!
    try require(loop["source"] as? String == source.id && loop["target"] as? String == source.id &&
                loop["source_handle"] as? String == "right" && loop["target_handle"] as? String == "top",
                "Self-loop did not retain distinct chosen sides")
    _ = try CanvasDocument(data: encoded(selfConnected))
    view.undoMove(nil)
    try require(NSDictionary(dictionary: uiSession.root).isEqual(to: normalConnection), "Self-loop Undo removed the wrong edge")
    view.redoMove(nil)
    try require(NSDictionary(dictionary: uiSession.root).isEqual(to: selfConnected), "Self-loop Redo lost edge ordering/identity")
    try require((uiSession.root["edges"] as! [[String: Any]])[0]["id"] as? String == edgeID,
                "Adding a self-loop changed the existing connection")
    try require(uiSession.document.originalData == sourceBytes, "Connections changed the original source bytes")
    view.undoMove(nil)
    let outsidePoint = CGPoint(x: 380, y: -50)
    let previousZero = view.viewPoint(forWorldPoint: .zero)
    let previousWorldCenter = CGPoint(x: view.visibleRect.midX - previousZero.x,
                                     y: view.visibleRect.midY - previousZero.y)
    view.beginConnection()
    try control("connection-source-side", as: NSPopUpButton.self).selectItem(at: 1)
    try control("connection-target-side", as: NSPopUpButton.self).selectItem(at: 1)
    try control("connection-create", as: NSButton.self).performClick(nil)
    let currentZero = view.viewPoint(forWorldPoint: .zero)
    let currentWorldCenter = CGPoint(x: view.visibleRect.midX - currentZero.x,
                                    y: view.visibleRect.midY - currentZero.y)
    try require(abs(previousWorldCenter.x - currentWorldCenter.x) < 0.01 &&
                abs(previousWorldCenter.y - currentWorldCenter.y) < 0.01,
                "Growing for an exterior route shifted the visible canvas")
    try require(view.bounds.contains(view.viewPoint(forWorldPoint: outsidePoint)),
                "New exterior route is outside the scrollable canvas")
    try require(difference(color(snapshot(), at: outsidePoint), background) > 0.2,
                "Exterior route was clipped instead of drawn")

    // Exercise connection label editing (Return / double-click) and endpoint/side reconnection (C) on existing connection.
    // Select the connection (index 0 in edges) via Tab traversal (node 0 -> node 1 -> edge 0 -> edge 1).
    window.makeFirstResponder(view)
    view.keyDown(with: key(53)) // Clear selection
    view.keyDown(with: key(48)) // source
    view.keyDown(with: key(48)) // target
    view.keyDown(with: key(48)) // edge 0 (normalConnection edgeID)
    try require(view.selectedConnectionID == edgeID, "Tab did not select the first connection")
    let beforeConnEdit = uiSession.root
    // Press Return on the selected connection to open Edit Connection with Label focused.
    view.keyDown(with: key(36))
    try require(window.attachedSheet?.title == "Edit Connection", "Return on selected connection did not open Edit Connection sheet")
    let labelControl = try control("connection-label", as: NSTextField.self)
    try require(labelControl.stringValue == "", "Unlabeled connection did not start with empty label field")
    // No-op commit preserves omitted label and redo history.
    try control("connection-create", as: NSButton.self).performClick(nil)
    try require(window.attachedSheet == nil && NSDictionary(dictionary: uiSession.root).isEqual(to: beforeConnEdit),
                "No-op connection edit materialized omitted label or mutated root")

    // Reopen with Return, verify >2000-char label is accepted per edge contract, then commit a Unicode label + Undo/Redo.
    let longLabel = String(repeating: "x", count: 2001)
    view.keyDown(with: key(36))
    try control("connection-label", as: NSTextField.self).stringValue = longLabel
    try control("connection-create", as: NSButton.self).performClick(nil)
    try require(window.attachedSheet == nil && uiSession.connectionState(of: edgeID)?.label == longLabel,
                "Long connection label was not accepted per edge contract")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: uiSession.root).isEqual(to: beforeConnEdit),
                "Undo long connection label did not restore omitted label")
    view.keyDown(with: key(36))
    let editLabelField = try control("connection-label", as: NSTextField.self)
    editLabelField.stringValue = "接続ラベル"
    try control("connection-create", as: NSButton.self).performClick(nil)
    try require(window.attachedSheet == nil, "Valid connection label commit did not close sheet")
    try require(uiSession.connectionState(of: edgeID)?.label == "接続ラベル",
                "Connection label edit did not persist")
    let labeledRoot = uiSession.root
    view.undoMove(nil)
    try require(NSDictionary(dictionary: uiSession.root).isEqual(to: beforeConnEdit),
                "Undo connection label edit did not restore omitted label")
    view.redoMove(nil)
    try require(NSDictionary(dictionary: uiSession.root).isEqual(to: labeledRoot),
                "Redo connection label edit did not restore label")
    // Reconnect endpoints and sides via C on the selected connection (reverse direction: target.bottom -> source.bottom).
    view.keyDown(with: key(8, characters: "c"))
    try require(window.attachedSheet?.title == "Edit Connection", "C on selected connection did not open Edit Connection sheet")
    try control("connection-source", as: NSPopUpButton.self).selectItem(at: 1) // target
    try control("connection-source-side", as: NSPopUpButton.self).selectItem(at: 3) // Bottom
    try control("connection-target", as: NSPopUpButton.self).selectItem(at: 0) // source
    try control("connection-target-side", as: NSPopUpButton.self).selectItem(at: 3) // Bottom
    try control("connection-label", as: NSTextField.self).stringValue = "" // Clear label
    try control("connection-create", as: NSButton.self).performClick(nil)
    let reconnectedState = uiSession.connectionState(of: edgeID)!
    try require(reconnectedState.source == target.id && reconnectedState.sourceSide == .bottom &&
                reconnectedState.target == source.id && reconnectedState.targetSide == .bottom &&
                reconnectedState.label == nil &&
                ((uiSession.root["edges"] as! [[String: Any]])[0]["label"] == nil),
                "Reconnecting and clearing label did not update endpoints/sides or remove cleared label")
    let reconnectedRoot = uiSession.root
    view.undoMove(nil)
    try require(NSDictionary(dictionary: uiSession.root).isEqual(to: labeledRoot),
                "Undo connection reconnect did not restore previous endpoints, sides, and label")
    view.redoMove(nil)
    try require(NSDictionary(dictionary: uiSession.root).isEqual(to: reconnectedRoot),
                "Redo connection reconnect did not restore updated endpoints and sides")
    view.undoMove(nil)
    view.undoMove(nil)
    try require(NSDictionary(dictionary: uiSession.root).isEqual(to: beforeConnEdit),
                "Two undos did not return connection to pre-edit state")

    // Back-to-back commands must not merge into AppKit's implicit event group.
    let retainedFirstSession = uiSession.root
    let historySession = CanvasSession(document: document)
    let historyCanvas = CanvasView(session: historySession)
    scroll.documentView = historyCanvas
    window.makeFirstResponder(historyCanvas)
    historyCanvas.insertShape(.rectangle)
    let oneShape = historySession.root
    historyCanvas.insertShape(.ellipse)
    let twoShapes = historySession.root
    historyCanvas.undoMove(nil)
    try require(NSDictionary(dictionary: historySession.root).isEqual(to: oneShape),
                "Consecutive insertion commands merged into one Undo")
    historyCanvas.redoMove(nil)
    try require(NSDictionary(dictionary: historySession.root).isEqual(to: twoShapes),
                "Separate insertion Redo lost identity/stacking")
    historyCanvas.undoMove(nil)
    historyCanvas.beginConnection()
    try control("connection-create", as: NSButton.self).performClick(nil)
    let singleLoopRoot = historySession.root
    let onlyNodeID = (oneShape["nodes"] as! [[String: Any]])[0]["id"] as! String
    let singleLoop = (singleLoopRoot["edges"] as! [[String: Any]]).last!
    try require(singleLoop["source"] as? String == onlyNodeID &&
                singleLoop["target"] as? String == onlyNodeID &&
                singleLoop["source_handle"] as? String != singleLoop["target_handle"] as? String,
                "Single-object sheet did not provide a valid self-loop")
    historyCanvas.undoMove(nil)
    try require(NSDictionary(dictionary: historySession.root).isEqual(to: oneShape),
                "Connection Undo removed its source insertion too")
    historyCanvas.redoMove(nil)
    try require(NSDictionary(dictionary: historySession.root).isEqual(to: singleLoopRoot),
                "Single-object self-loop Redo lost identity")
    try require(NSDictionary(dictionary: uiSession.root).isEqual(to: retainedFirstSession),
                "One canvas history changed another session")
    print("PASS native connections: endpoint/self-loop refusal, labels, reconnection, sheets, rendered movement, history and v1/source retention")
    window.orderOut(nil)
}
