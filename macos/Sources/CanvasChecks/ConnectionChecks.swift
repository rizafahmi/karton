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

    // Orthogonal step, rounded smooth, and self-loop exterior routing + label avoidance checks.
    let routeRoot: [String: Any] = [
        "version": 2,
        "paper": ["background": "none"],
        "nodes": [
            ["id": "left", "type": "shape", "x": 100, "y": 100, "width": 120, "height": 80, "data": ["kind": "rect"]],
            ["id": "right-same-row", "type": "shape", "x": 360, "y": 100, "width": 120, "height": 80, "data": ["kind": "rect"]],
            ["id": "right-below", "type": "shape", "x": 360, "y": 240, "width": 120, "height": 80, "data": ["kind": "rect"]],
            ["id": "rot", "type": "shape", "x": 100, "y": 420, "width": 200, "height": 80, "data": ["kind": "rect", "rotation": 90]]
        ],
        "edges": [
            // Orthogonal right -> top step: a=(220,140), leadA=(240,140), corner=(420,140), leadB=(420,220), b=(420,240)
            [
                "id": "e-step-ortho", "source": "left", "source_handle": "right",
                "target": "right-below", "target_handle": "top", "path": "step", "marker": "arrow", "label": "Step"
            ],
            [
                "id": "e-smooth-ortho", "source": "left", "source_handle": "right",
                "target": "right-below", "target_handle": "top", "path": "smooth", "marker": "arrow", "label": "Smooth"
            ],
            // Different-row right -> right step: a=(220,140), leadA=(240,140), b=(480,280), leadB=(500,280), midY=210
            [
                "id": "e-step-same", "source": "left", "source_handle": "right",
                "target": "right-below", "target_handle": "right", "path": "step", "marker": "arrow"
            ],
            // Same-row right -> right step: source=(100,100,120,80), target=(360,100,120,80) -> detours at y=80 to (500,140) and enters (480,140) leftward!
            [
                "id": "e-step-same-row", "source": "left", "source_handle": "right",
                "target": "right-same-row", "target_handle": "right", "path": "step", "marker": "arrow"
            ],
            // Self-loop on 90-degree rotated shape with wide label
            [
                "id": "e-rot-loop", "source": "rot", "source_handle": "top",
                "target": "rot", "target_handle": "right", "path": "bezier", "marker": "arrow",
                "label": "Wide Self-Loop Label Outside Rotated Box"
            ]
        ]
    ]
    let routeSession = CanvasSession(document: try CanvasDocument(data: encoded(routeRoot)))
    let routeView = CanvasView(session: routeSession)
    guard let stepOrthoSamples = routeView.edgeSamples(of: "e-step-ortho"),
          let smoothOrthoSamples = routeView.edgeSamples(of: "e-smooth-ortho"),
          let stepSameSamples = routeView.edgeSamples(of: "e-step-same"),
          let stepSameRowSamples = routeView.edgeSamples(of: "e-step-same-row"),
          let loopSamples = routeView.edgeSamples(of: "e-rot-loop") else {
        throw CheckFailure(description: "Missing edge samples for route geometry checks")
    }
    // 1. e-step-ortho must have exact orthogonal segments (220,140) -> (420,140) -> (420,240) and downward target tangent (0, 1).
    try require(
        stepOrthoSamples == [CGPoint(x: 220, y: 140), CGPoint(x: 420, y: 140), CGPoint(x: 420, y: 240)],
        "Orthogonal right->top step polyline did not collapse to L-bend [(220,140), (420,140), (420,240)]: got \(stepOrthoSamples)"
    )
    for (p0, p1) in zip(stepOrthoSamples, stepOrthoSamples.dropFirst()) {
        try require(abs(p1.x - p0.x) < 0.01 || abs(p1.y - p0.y) < 0.01,
                    "Step segment \(p0) -> \(p1) was not axis-aligned")
    }
    try require(
        routeView.edgeTargetTangent(of: "e-step-ortho") == CGPoint(x: 0, y: 1) &&
        routeView.edgeTargetTangent(of: "e-smooth-ortho") == CGPoint(x: 0, y: 1),
        "Step/smooth right->top connection did not enter target top handle vertically downward (0, 1)"
    )
    // Total length of L-bend is 200 (horizontal) + 100 (vertical) = 300; half-arc-length midpoint is 150 along first segment -> (370, 140).
    try require(
        routeView.edgeLabelPoint(of: "e-step-ortho") == CGPoint(x: 370, y: 140) &&
        routeView.edgeLabelPoint(of: "e-smooth-ortho") == CGPoint(x: 370, y: 140),
        "Step/smooth labelPoint was not placed at half-arc-length midpoint (370, 140)"
    )
    // 2. e-smooth-ortho rounds the (420, 140) corner with radius 8 (starts rounding at (412, 140) and exits at (420, 148), never hitting sharp (420, 140)).
    try require(
        smoothOrthoSamples.count > stepOrthoSamples.count &&
        smoothOrthoSamples.contains(CGPoint(x: 412, y: 140)) &&
        smoothOrthoSamples.contains(CGPoint(x: 420, y: 148)) &&
        !smoothOrthoSamples.contains(CGPoint(x: 420, y: 140)),
        "Smooth route did not round the orthogonal corner at (420, 140) with radius 8"
    )
    // 3. e-step-same (right -> right) steps out 20 units from target right handle to x=500 and enters target horizontally leftward (-1, 0).
    try require(
        stepSameSamples.contains(CGPoint(x: 500, y: 280)) &&
        routeView.edgeTargetTangent(of: "e-step-same") == CGPoint(x: -1, y: 0),
        "Same-side right->right step route did not lead out to x=500 and enter target leftward (-1, 0)"
    )
    // 3b. e-step-same-row (same-row right -> right on (100,100,120,80) and (360,100,120,80))
    //     detours above both shapes at y=80, reaches leadB=(500,140), and enters target (480,140) leftward (-1, 0).
    try require(
        stepSameRowSamples == [
            CGPoint(x: 220, y: 140),
            CGPoint(x: 240, y: 140),
            CGPoint(x: 240, y: 80),
            CGPoint(x: 500, y: 80),
            CGPoint(x: 500, y: 140),
            CGPoint(x: 480, y: 140)
        ] &&
        routeView.edgeTargetTangent(of: "e-step-same-row") == CGPoint(x: -1, y: 0),
        "Same-row right->right step route did not detour around target at y=80 and enter leftward (-1, 0): got \(stepSameRowSamples)"
    )
    // 4. e-rot-loop on 90-degree rotated 200x80 rect (centered at (200, 460), rotated bounds x:160..240, y:360..560)
    //    stays outside visualBox (x:100..300, y:360..560), rounds corners with radius 16, and pushes its wide label outside visualBox!
    let rotVisualBox = CGRect(x: 100, y: 360, width: 200, height: 200)
    guard let loopLabelPt = routeView.edgeLabelPoint(of: "e-rot-loop") else {
        throw CheckFailure(description: "Missing label point for rotated self-loop")
    }
    try require(
        loopSamples.count > 6 && !rotVisualBox.contains(loopLabelPt),
        "Rotated self-loop did not round corners or failed to place wide label outside visual box (\(loopLabelPt) vs \(rotVisualBox))"
    )

    // 5. Direct pointer drag-and-drop connection creation (from side ports and Option-drag) and endpoint reconnection.
    let routeScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 640, height: 640))
    routeScroll.documentView = routeView
    window.contentView = routeScroll
    window.makeFirstResponder(routeView)
    func sendMouse(_ type: NSEvent.EventType, world: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        let viewPt = routeView.viewPoint(forWorldPoint: world)
        let winPt = routeView.convert(viewPt, to: nil)
        let ev = NSEvent.mouseEvent(
            with: type, location: winPt, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        )!
        switch type {
        case .leftMouseDown: routeView.mouseDown(with: ev)
        case .leftMouseDragged: routeView.mouseDragged(with: ev)
        case .leftMouseUp: routeView.mouseUp(with: ev)
        default: break
        }
    }
    let beforeDragConnectRoot = routeSession.root
    guard let leftRightPort = routeView.connectionPortWorldPoint(of: "left", side: .right),
          let targetLeftPort = routeView.connectionPortWorldPoint(of: "right-same-row", side: .left) else {
        throw CheckFailure(description: "Missing connection port world points")
    }
    // 5a. Drag from "left".right port to "right-same-row".left port; verify preview isolation, commit, and Undo/Redo.
    sendMouse(.leftMouseDown, world: leftRightPort)
    sendMouse(.leftMouseDragged, world: CGPoint(x: 290, y: 140))
    try require(
        routeView.hasActiveConnectionDrag && routeView.hasPendingDraftOrPreview &&
        NSDictionary(dictionary: routeSession.root).isEqual(to: beforeDragConnectRoot),
        "Pointer connection drag did not stay isolated outside session JSON before mouseUp"
    )
    sendMouse(.leftMouseDragged, world: targetLeftPort)
    sendMouse(.leftMouseUp, world: targetLeftPort)
    try require(!routeView.hasActiveConnectionDrag, "mouseUp did not finish pointer connection drag")
    guard let dragCreatedEdgeID = routeView.selectedConnectionID,
          let dragCreatedState = routeSession.connectionState(of: dragCreatedEdgeID) else {
        throw CheckFailure(description: "Pointer port-to-port drag did not create and select a connection")
    }
    try require(
        dragCreatedState.source == "left" && dragCreatedState.sourceSide == .right &&
        dragCreatedState.target == "right-same-row" && dragCreatedState.targetSide == .left,
        "Port-to-port drag did not bind explicit source_handle=right and target_handle=left: got \(dragCreatedState)"
    )
    let afterPortDragRoot = routeSession.root
    routeView.undoMove(nil)
    try require(NSDictionary(dictionary: routeSession.root).isEqual(to: beforeDragConnectRoot),
                "Undo pointer connection drag did not restore baseline")
    routeView.redoMove(nil)
    try require(NSDictionary(dictionary: routeSession.root).isEqual(to: afterPortDragRoot) &&
                routeView.selectedConnectionID == dragCreatedEdgeID,
                "Redo pointer connection drag did not restore identical connection ID")

    // 5b. Drag the selected connection's target endpoint handle from (360, 140) to "right-below".bottom (420, 320):
    //     first cancel with Escape (preserving redo/state), then commit on mouseUp!
    guard let rightBelowBottomPort = routeView.connectionPortWorldPoint(of: "right-below", side: .bottom) else {
        throw CheckFailure(description: "Missing bottom port on right-below")
    }
    sendMouse(.leftMouseDown, world: targetLeftPort)
    sendMouse(.leftMouseDragged, world: rightBelowBottomPort)
    try require(routeView.hasActiveConnectionDrag &&
                NSDictionary(dictionary: routeSession.root).isEqual(to: afterPortDragRoot),
                "Reconnection drag mutated session before mouseUp")
    routeView.keyDown(with: key(53)) // Escape cancels reconnection drag
    sendMouse(.leftMouseUp, world: rightBelowBottomPort)
    try require(!routeView.hasActiveConnectionDrag &&
                NSDictionary(dictionary: routeSession.root).isEqual(to: afterPortDragRoot),
                "Escape during reconnection drag did not cancel cleanly")

    // Now drag target endpoint handle and release on rightBelowBottomPort to commit reconnection!
    // Drag over rightBelowBottomPort, then release mouseUp in blank space (50, 50) without another mouseDragged:
    // must cancel without mutating root, revision, or redo history!
    let revBeforeBlankReconnectRelease = routeSession.revision
    sendMouse(.leftMouseDown, world: targetLeftPort)
    sendMouse(.leftMouseDragged, world: rightBelowBottomPort)
    sendMouse(.leftMouseUp, world: CGPoint(x: 50, y: 50))
    try require(
        !routeView.hasActiveConnectionDrag &&
        routeSession.revision == revBeforeBlankReconnectRelease &&
        NSDictionary(dictionary: routeSession.root).isEqual(to: afterPortDragRoot),
        "Releasing reconnection drag in blank space after hovering a valid port committed a stale target"
    )
    sendMouse(.leftMouseDown, world: targetLeftPort)
    sendMouse(.leftMouseDragged, world: rightBelowBottomPort)
    sendMouse(.leftMouseUp, world: rightBelowBottomPort)
    guard let reconnectedByDrag = routeSession.connectionState(of: dragCreatedEdgeID) else {
        throw CheckFailure(description: "Missing connection after pointer reconnection")
    }
    try require(
        reconnectedByDrag.source == "left" && reconnectedByDrag.sourceSide == .right &&
        reconnectedByDrag.target == "right-below" && reconnectedByDrag.targetSide == .bottom,
        "Pointer endpoint drag did not reconnect target to right-below.bottom: got \(reconnectedByDrag)"
    )
    routeView.undoMove(nil)
    try require(NSDictionary(dictionary: routeSession.root).isEqual(to: afterPortDragRoot),
                "Undo pointer reconnection did not restore previous target")
    routeView.undoMove(nil)

    // 5c. Option-drag from inside "left" body (160, 140) onto "right-below" body (420, 280) creates automatic-side connection!
    sendMouse(.leftMouseDown, world: CGPoint(x: 160, y: 140), modifiers: [.option])
    sendMouse(.leftMouseDragged, world: CGPoint(x: 420, y: 280), modifiers: [.option])
    sendMouse(.leftMouseUp, world: CGPoint(x: 420, y: 280), modifiers: [.option])
    guard let optEdgeID = routeView.selectedConnectionID,
          let optState = routeSession.connectionState(of: optEdgeID) else {
        throw CheckFailure(description: "Option-drag between shapes did not create a connection")
    }
    try require(
        optState.source == "left" && optState.sourceSide == nil &&
        optState.target == "right-below" && optState.targetSide == nil,
        "Option-drag onto shape body materialized explicit handles instead of automatic nil sides: got \(optState)"
    )
    // Clicking (mouseDown + mouseUp without drag movement) on both automatic endpoints of optEdgeID
    // must NOT materialize explicit source_handle/target_handle, advance revision, or clear redo!
    // Create a redo entry first by moving and undoing, then reselect optEdgeID.
    routeView.selectNode("left")
    routeView.keyDown(with: key(124))
    routeView.undoMove(nil)
    try require(routeView.undoManager?.canRedo == true, "Expected redo available before automatic-endpoint click check")
    sendMouse(.leftMouseDown, world: CGPoint(x: 290, y: 210))
    sendMouse(.leftMouseUp, world: CGPoint(x: 290, y: 210))
    try require(routeView.selectedConnectionID == optEdgeID, "Clicking midpoint did not reselect automatic connection")
    let afterOptCreateRoot = routeSession.root
    let revBeforeEndpointClick = routeSession.revision
    guard let optSamples = routeView.edgeSamples(of: optEdgeID),
          let optStartPt = optSamples.first,
          let optEndPt = optSamples.last else {
        throw CheckFailure(description: "Missing samples for automatic connection optEdgeID")
    }
    for endpointPt in [optStartPt, optEndPt] {
        sendMouse(.leftMouseDown, world: endpointPt)
        sendMouse(.leftMouseUp, world: endpointPt)
        try require(
            !routeView.hasActiveConnectionDrag &&
            routeView.selectedConnectionID == optEdgeID &&
            routeSession.revision == revBeforeEndpointClick &&
            routeView.undoManager?.canRedo == true &&
            NSDictionary(dictionary: routeSession.root).isEqual(to: afterOptCreateRoot),
            "Clicking automatic connection endpoint at \(endpointPt) without dragging materialized a side, advanced revision, or cleared redo"
        )
    }
    routeView.undoMove(nil)
    try require(NSDictionary(dictionary: routeSession.root).isEqual(to: beforeDragConnectRoot),
                "Undo Option-drag connection did not restore baseline")
    // Drag from "left".right over targetLeftPort, then release mouseUp in blank space (50, 50):
    // must cancel without creating a connection, advancing revision, or clearing redo!
    let revBeforeBlankCreateRelease = routeSession.revision
    try require(routeView.undoManager?.canRedo == true, "Expected redo available before blank-space create release")
    sendMouse(.leftMouseDown, world: leftRightPort)
    sendMouse(.leftMouseDragged, world: targetLeftPort)
    sendMouse(.leftMouseUp, world: CGPoint(x: 50, y: 50))
    try require(
        !routeView.hasActiveConnectionDrag &&
        routeSession.revision == revBeforeBlankCreateRelease &&
        routeView.undoManager?.canRedo == true &&
        NSDictionary(dictionary: routeSession.root).isEqual(to: beforeDragConnectRoot),
        "Releasing new connection drag in blank space after hovering a valid port committed a stale target or cleared redo"
    )

    print("PASS native connections: endpoint/self-loop refusal, labels, reconnection, pointer drag-and-drop connect/reconnect, sheets, step/smooth/self-loop routing, rendered movement, history and v1/source retention")
    window.orderOut(nil)
}
