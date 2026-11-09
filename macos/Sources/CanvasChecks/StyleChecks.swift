import AppKit
import CanvasCore
import CanvasUI
import Foundation

@MainActor
func checkStyles(repository: URL) throws {
    let nodes: [[String: Any]] = [
        [
            "id": "rect", "type": "shape", "x": 80, "y": 80, "width": 160, "height": 100,
            "future-node": "rect-meta",
            "data": ["kind": "rect", "text": "Box", "future-data": [1, 2]]
        ],
        [
            "id": "ellipse", "type": "shape", "x": 300, "y": 80, "width": 140, "height": 90,
            "data": ["kind": "ellipse", "fill": "yellow", "stroke": "ink"]
        ],
        [
            "id": "text", "type": "shape", "x": 500, "y": 80, "width": 160, "height": 48,
            "data": ["kind": "text", "text": "Note"]
        ],
        [
            "id": "line", "type": "shape-line", "x": 80, "y": 240, "width": 184, "height": 24,
            "data": ["from": [12, 12], "to": [172, 12], "future-line": "kept"]
        ],
        [
            "id": "code", "type": "code", "x": 300, "y": 240, "width": 220, "height": 110,
            "data": ["content": "IO.inspect(:ok)\n", "language": "elixir", "future-code": true]
        ],
        [
            "id": "locked", "type": "shape", "x": 560, "y": 240, "width": 140, "height": 90,
            "locked": true,
            "data": ["kind": "diamond", "fill": "red", "stroke": "ink"]
        ]
    ]
    let edges: [[String: Any]] = [
        [
            "id": "plain-edge", "source": "rect", "source_handle": "right",
            "target": "ellipse", "target_handle": "left", "path": "straight", "marker": "arrow",
            "animated": true, "future-edge": "plain-kept"
        ],
        [
            "id": "styled-edge", "source": "ellipse", "source_handle": "bottom",
            "target": "code", "target_handle": "top", "path": "bezier", "marker": "dot",
            "animated": false,
            "data": [
                "connector_style": ["stroke": "violet", "width": 4, "dash": true, "future-style": "kept"],
                "future-data": 99
            ]
        ],
        [
            "id": "collision-edge", "source": "rect", "source_handle": "bottom",
            "target": "code", "target_handle": "left", "path": "step", "marker": "arrow",
            "data": ["connector_style": "legacy-collision", "future": "collision-kept"]
        ]
    ]
    let rootObject: [String: Any] = [
        "version": 2,
        "appearance": ["font": "heading"],
        "paper": ["background": "none"],
        "nodes": nodes,
        "edges": edges
    ]
    let sourceBytes = try encoded(rootObject)
    let appDelegate = CanvasAppDelegate()
    appDelegate.installMenu()
    let session = CanvasSession(document: try CanvasDocument(data: sourceBytes))
    let view = appDelegate.showSession(session, name: "StyleSmoke")
    defer { appDelegate.closeAllWindows() }

    guard let window = view.window,
          let editMenu = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu,
          let styleMenuItem = editMenu.item(withTitle: "Style…") else {
        throw CheckFailure(description: "Missing window or Edit -> Style… menu item")
    }

    func dispatchKey(_ code: UInt16, _ chars: String = "", modifiers: NSEvent.ModifierFlags = []) {
        let targetWindow = window.attachedSheet ?? window
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: targetWindow.windowNumber,
            context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: code
        )!
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return
        }
        NSApp.sendEvent(event)
    }

    func sample(_ world: CGPoint) -> NSColor {
        let point = view.viewPoint(forWorldPoint: world)
        let rect = CGRect(x: point.x - 1, y: point.y - 1, width: 3, height: 3)
        let rep = view.bitmapImageRepForCachingDisplay(in: rect)!
        view.cacheDisplay(in: rect, to: rep)
        return rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)!.usingColorSpace(.sRGB)!
    }

    func colorDiff(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let sa = a.usingColorSpace(.sRGB)!
        let sb = b.usingColorSpace(.sRGB)!
        return abs(sa.redComponent - sb.redComponent)
            + abs(sa.greenComponent - sb.greenComponent)
            + abs(sa.blueComponent - sb.blueComponent)
    }

    let inspector = view.styleInspector
    func label(_ id: String) throws -> NSTextField {
        guard let field = inspector.subviews.first(where: { $0.identifier?.rawValue == id }) as? NSTextField else {
            throw CheckFailure(description: "Missing inspector label: \(id)")
        }
        return field
    }
    func popup(_ property: CanvasStyleProperty) -> NSPopUpButton? {
        inspector.subviews.first(where: { $0.identifier?.rawValue == "style-\(property.rawValue)" }) as? NSPopUpButton
    }
    func visibleProperties() -> [CanvasStyleProperty] {
        CanvasStyleProperty.allCases.filter { popup($0) != nil }
    }
    func choose(_ property: CanvasStyleProperty, title: String) throws {
        guard let control = popup(property) else {
            throw CheckFailure(description: "Missing popup for \(property.rawValue)")
        }
        let index = control.indexOfItem(withTitle: title)
        try require(index >= 0, "Missing option '\(title)' in \(property.rawValue)")
        control.selectItem(at: index)
        _ = control.target?.perform(control.action!, with: control)
    }

    let baselineRoot = session.root

    // 1. Open Style inspector via Edit -> Style… with empty selection; verify observation never mutates root.
    try require(!view.isStyleInspectorOpen && inspector.isHidden, "Style inspector started open")
    try require(appDelegate.validateMenuItem(styleMenuItem), "Edit -> Style… was disabled")
    _ = appDelegate.perform(styleMenuItem.action!, with: styleMenuItem)
    try require(view.isStyleInspectorOpen && !inspector.isHidden, "Edit -> Style… did not open inspector")
    try require(try label("style-title").stringValue == "Style" &&
                !(try label("style-message").isHidden) &&
                visibleProperties().isEmpty,
                "Empty-selection Style inspector did not show guidance without controls")

    // Close with Escape and reopen with S shortcut after selecting "rect".
    dispatchKey(53, "\u{1b}")
    try require(!view.isStyleInspectorOpen && inspector.isHidden && window.firstResponder === view,
                "Escape did not close Style inspector and return focus to canvas")

    // 2. Traverse across all node/edge types while Style is open: verify capability sets, effective defaults,
    //    canvas focus retention on selection changes, and zero document mutation.
    dispatchKey(48, "\t") // Select "rect"
    dispatchKey(1, "s") // Press S to open and focus Style inspector
    try require(view.isStyleInspectorOpen && view.selectedNodeID == "rect",
                "S shortcut did not open Style inspector for 'rect'")
    try require(window.firstResponder === popup(.fill),
                "S shortcut did not focus first enabled control in Style inspector")
    try require(try label("style-title").stringValue == "Rectangle" &&
                visibleProperties() == [.fill, .stroke, .width, .dash, .radius, .font, .size, .align],
                "Rectangle did not expose exact 8 style properties")
    // Verify inherited document font ("heading" -> "Title") and shape defaults are read without mutating root!
    try require(popup(.fill)?.titleOfSelectedItem == "Blue" &&
                popup(.stroke)?.titleOfSelectedItem == "Blue" &&
                popup(.width)?.titleOfSelectedItem == "Medium" &&
                popup(.dash)?.titleOfSelectedItem == "Solid" &&
                popup(.radius)?.titleOfSelectedItem == "Rounded" &&
                popup(.font)?.titleOfSelectedItem == "Title" &&
                popup(.size)?.titleOfSelectedItem == "Medium" &&
                popup(.align)?.titleOfSelectedItem == "Center",
                "Rectangle effective defaults or inherited document font were wrong")
    try require(NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "Inspecting rectangle materialized defaults into session JSON")

    // Return focus to canvas and Tab through remaining objects: selection changes must NOT steal focus!
    window.makeFirstResponder(view)
    dispatchKey(48, "\t") // "ellipse"
    try require(view.selectedNodeID == "ellipse" && window.firstResponder === view,
                "Canvas selection change stole focus from CanvasView")
    try require(try label("style-title").stringValue == "Ellipse" &&
                visibleProperties() == [.fill, .stroke, .width, .dash, .font, .size, .align],
                "Ellipse exposed radius or wrong properties")

    dispatchKey(48, "\t") // "text"
    try require(try label("style-title").stringValue == "Text" &&
                visibleProperties() == [.fill, .font, .size, .align] &&
                popup(.fill)?.titleOfSelectedItem == "None" &&
                popup(.align)?.titleOfSelectedItem == "Left",
                "Text node did not expose exact [fill, font, size, align] properties and defaults")

    dispatchKey(48, "\t") // "line"
    try require(try label("style-title").stringValue == "Line" &&
                visibleProperties() == [.stroke, .width, .dash, .arrow] &&
                popup(.stroke)?.titleOfSelectedItem == "Ink" &&
                popup(.arrow)?.titleOfSelectedItem == "End",
                "Standalone line did not expose exact [stroke, width, dash, arrow] properties")

    dispatchKey(48, "\t") // "code"
    try require(try label("style-title").stringValue == "Code block" &&
                visibleProperties() == [.fill, .stroke, .width, .dash, .radius, .size] &&
                popup(.fill)?.titleOfSelectedItem == "None" &&
                popup(.stroke)?.titleOfSelectedItem == "Ink" &&
                popup(.radius)?.titleOfSelectedItem == "Sharp",
                "Code block did not expose exact [fill, stroke, width, dash, radius, size] properties")

    dispatchKey(48, "\t") // "locked"
    try require(try label("style-title").stringValue == "Diamond" &&
                !(try label("style-message").isHidden) &&
                popup(.fill)?.isEnabled == false,
                "Locked shape did not disable inspector controls with explanation")
    do {
        try view.applyStyle(.fill, to: .string("green"))
        throw CheckFailure(description: "Locked node accepted style mutation")
    } catch is CanvasDocumentError {}

    dispatchKey(48, "\t") // "plain-edge" (animated: true, omitted connector_style, path: straight, marker: arrow)
    try require(view.selectedConnectionID == "plain-edge" &&
                (try label("style-title").stringValue == "Connection") &&
                visibleProperties() == [.stroke, .width, .dash, .path, .marker] &&
                popup(.stroke)?.titleOfSelectedItem == "Default" &&
                popup(.width)?.titleOfSelectedItem == "Medium" &&
                popup(.dash)?.titleOfSelectedItem == "Dashed" &&
                popup(.path)?.titleOfSelectedItem == "Straight" &&
                popup(.marker)?.titleOfSelectedItem == "Arrow",
                "Animated connection with omitted connector_style did not read Default stroke, inherited Dashed, Path and Marker")
    try require(NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "Traversing all nodes and connections with Style open mutated session JSON")

    // 3. Same-selection control identity & focus retention + bitmap fill proof + omitted-default no-op + Undo/Redo.
    dispatchKey(48, "\t") // "styled-edge"
    dispatchKey(48, "\t") // "collision-edge"
    dispatchKey(48, "\t") // wraps to "rect"
    try require(view.selectedNodeID == "rect", "Expected traversal to wrap back to 'rect'")

    // Create a redo entry to verify no-op style selections do not clear redo.
    dispatchKey(124) // Move right 1px
    dispatchKey(6, "z", modifiers: [.command]) // Undo move
    try require(view.undoManager?.canRedo == true, "Expected redo available before no-op style check")

    // Selecting already-effective "Medium" width (2) or "Title" font ("heading") on "rect" must be a no-op!
    try choose(.width, title: "Medium")
    try choose(.font, title: "Title")
    try require(NSDictionary(dictionary: session.root).isEqual(to: baselineRoot) &&
                view.undoManager?.canRedo == true,
                "Selecting already-effective default width or inherited font materialized defaults or cleared redo")

    // Now focus "style-fill" popup and change "rect" fill from default Blue to Yellow; check control identity & bitmap!
    let fillControlBefore = popup(.fill)!
    window.makeFirstResponder(fillControlBefore)
    let rectSamplePoint = CGPoint(x: 100, y: 100) // Inside "rect", clear of "Box" caption
    let yellowReference = sample(CGPoint(x: 320, y: 100)) // Inside "ellipse" (authored yellow)
    let beforeRectColor = sample(rectSamplePoint)
    try require(colorDiff(beforeRectColor, yellowReference) > 0.3,
                "Rectangle was already yellow before style edit")
    try choose(.fill, title: "Yellow")
    let fillControlAfter = popup(.fill)!
    try require(fillControlBefore === fillControlAfter && window.firstResponder === fillControlAfter,
                "Same-selection style edit replaced native control instance or lost focus")
    try require(colorDiff(sample(rectSamplePoint), yellowReference) < 0.05,
                "Changing rectangle fill to Yellow did not update rendered canvas bitmap")
    let rectNodes = session.root["nodes"] as! [[String: Any]]
    let rectData = rectNodes[0]["data"] as! [String: Any]
    try require(rectData["fill"] as? String == "yellow" &&
                rectData["width"] == nil && rectData["font"] == nil &&
                rectNodes[0]["future-node"] as? String == "rect-meta" &&
                (rectData["future-data"] as? [Int]) == [1, 2],
                "Style edit materialized unrelated defaults or lost unknown metadata")

    // Undo / Redo from inside the Style inspector
    dispatchKey(6, "z", modifiers: [.command])
    try require(NSDictionary(dictionary: session.root).isEqual(to: baselineRoot) &&
                popup(.fill)?.titleOfSelectedItem == "Blue" &&
                colorDiff(sample(rectSamplePoint), beforeRectColor) < 0.05,
                "Undo style edit did not restore omitted fill and original bitmap")
    dispatchKey(6, "Z", modifiers: [.command, .shift])
    try require(((session.root["nodes"] as! [[String: Any]])[0]["data"] as! [String: Any])["fill"] as? String == "yellow",
                "Redo style edit did not reapply Yellow fill")
    dispatchKey(6, "z", modifiers: [.command])
    try require(NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "Second Undo did not return to baseline")

    // 4. Connection styles: legacy omission vs explicit Ink, animated dash override, and collision refusal.
    window.makeFirstResponder(view)
    for _ in 0..<6 { dispatchKey(48, "\t") } // "plain-edge"
    try require(view.selectedConnectionID == "plain-edge", "Expected 'plain-edge' selected")
    // Explicitly choosing "Ink" on a legacy-omitted stroke writes connector_style.stroke = "ink"
    try choose(.stroke, title: "Ink")
    let plainEdgeAfterInk = (session.root["edges"] as! [[String: Any]])[0]
    let plainStyleAfterInk = (plainEdgeAfterInk["data"] as? [String: Any])?["connector_style"] as? [String: Any]
    try require(plainStyleAfterInk?["stroke"] as? String == "ink" &&
                plainEdgeAfterInk["future-edge"] as? String == "plain-kept",
                "Explicit Ink on omitted connector_style did not persist or lost edge metadata")
    // Choosing "Solid" on an animated connection writes dash = false while retaining animated = true
    try choose(.dash, title: "Solid")
    let plainEdgeAfterSolid = (session.root["edges"] as! [[String: Any]])[0]
    let plainStyleAfterSolid = (plainEdgeAfterSolid["data"] as? [String: Any])?["connector_style"] as? [String: Any]
    try require(plainStyleAfterSolid?["dash"] as? Bool == false &&
                plainEdgeAfterSolid["animated"] as? Bool == true,
                "Setting Solid on animated edge did not preserve animated: true")
    // Exercise top-level connection Path ("Step") and Target marker ("Dot") controls and Undo/Redo restoration.
    try choose(.path, title: "Step")
    try choose(.marker, title: "Dot")
    let plainEdgeAfterPathMarker = (session.root["edges"] as! [[String: Any]])[0]
    try require(plainEdgeAfterPathMarker["path"] as? String == "step" &&
                plainEdgeAfterPathMarker["marker"] as? String == "dot" &&
                plainEdgeAfterPathMarker["future-edge"] as? String == "plain-kept",
                "Connection Path/Marker controls did not update top-level edge fields or lost metadata")
    dispatchKey(6, "z", modifiers: [.command]) // Undo Marker
    dispatchKey(6, "z", modifiers: [.command]) // Undo Path
    dispatchKey(6, "z", modifiers: [.command]) // Undo Solid
    dispatchKey(6, "z", modifiers: [.command]) // Undo Ink -> restores absent "data" key and original path/marker on plain-edge!
    try require((session.root["edges"] as! [[String: Any]])[0]["data"] == nil &&
                NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "Undoing connection styles did not restore original edge fields and absent data object")

    // Select "collision-edge" (where data.connector_style == "legacy-collision") and verify visible refusal.
    dispatchKey(48, "\t") // "styled-edge"
    dispatchKey(48, "\t") // "collision-edge"
    try require(view.selectedConnectionID == "collision-edge", "Expected 'collision-edge' selected")
    try choose(.stroke, title: "Red")
    let errorField = try label("style-error")
    try require(!errorField.isHidden &&
                errorField.stringValue.localizedCaseInsensitiveContains("conflicts with existing metadata") &&
                NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "Non-object connector_style collision was not visibly refused without mutation")

    // 5. Staged Escape precedence: G geometry preview cancels before Style closes, Style closes before selection clears.
    dispatchKey(48, "\t") // Wrap to "rect"
    try require(view.selectedNodeID == "rect" && errorField.isHidden,
                "Selection change did not clear previous connector collision error")
    dispatchKey(5, "g") // Enter G geometry mode while Style is open
    try require(view.hasGeometryPreview && view.isStyleInspectorOpen &&
                popup(.fill)?.isEnabled == false &&
                !(try label("style-message").isHidden),
                "Entering G mode did not disable Style inspector controls")
    dispatchKey(53, "\u{1b}") // 1st Escape: cancels G mode, keeps Style open and "rect" selected!
    try require(!view.hasGeometryPreview && view.isStyleInspectorOpen && view.selectedNodeID == "rect" &&
                popup(.fill)?.isEnabled == true,
                "First Escape did not cancel G preview while keeping Style inspector open")
    dispatchKey(53, "\u{1b}") // 2nd Escape: closes Style inspector, keeps "rect" selected!
    try require(!view.isStyleInspectorOpen && inspector.isHidden && view.selectedNodeID == "rect" &&
                window.firstResponder === view,
                "Second Escape did not close Style inspector while preserving selection")
    dispatchKey(53, "\u{1b}") // 3rd Escape: clears selection!
    try require(view.selectedNodeID == nil && view.selectedConnectionID == nil,
                "Third Escape did not clear canvas selection")

    try require(session.document.originalData == sourceBytes,
                "Style inspector operations mutated original document bytes")
    print("PASS Style inspector: capability intersection, omitted defaults, control identity, connector collisions, staged Escape and Undo/Redo")
}
