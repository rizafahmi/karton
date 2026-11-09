import AppKit
import CanvasCore
import CanvasUI
import Foundation

@MainActor
func checkLifecycle(repository: URL) throws {
    let initialNodes: [[String: Any]] = [
        [
            "id": "back", "type": "shape", "x": 100, "y": 100, "width": 160, "height": 100,
            "future-node": ["origin": "back-meta"],
            "data": ["kind": "rect", "fill": "yellow", "stroke": "ink", "text": "Back"]
        ],
        [
            "id": "middle", "type": "shape", "x": 140, "y": 120, "width": 160, "height": 100,
            "locked": false,
            "future-node": ["origin": "middle-meta"],
            "data": ["kind": "rect", "fill": "blue", "stroke": "ink", "text": "Middle", "custom": 42]
        ],
        [
            "id": "front", "type": "shape", "x": 420, "y": 100, "width": 160, "height": 100,
            "data": ["kind": "ellipse", "fill": "green", "stroke": "ink", "text": "Front"]
        ],
        [
            "id": "locked", "type": "shape", "x": 420, "y": 280, "width": 160, "height": 100,
            "locked": true,
            "data": ["kind": "diamond", "fill": "red", "stroke": "ink", "text": "Locked"]
        ]
    ]
    let initialEdges: [[String: Any]] = [
        [
            "id": "e-back-front", "source": "back", "source_handle": "right",
            "target": "front", "target_handle": "left", "path": "straight", "marker": "arrow",
            "label": "link", "future-edge": "keep-1",
            "data": ["connector_style": ["stroke": "ink", "width": 2, "dash": false], "meta": 1]
        ],
        [
            "id": "e-middle-front", "source": "middle", "source_handle": "right",
            "target": "front", "target_handle": "bottom", "path": "bezier", "marker": "dot",
            "future-edge": "keep-2", "data": ["meta": 2]
        ],
        [
            "id": "e-front-loop", "source": "front", "source_handle": "top",
            "target": "front", "target_handle": "right", "path": "bezier", "marker": "arrow",
            "data": ["meta": 3]
        ],
        [
            "id": "e-locked", "source": "front", "source_handle": "bottom",
            "target": "locked", "target_handle": "top", "path": "straight", "marker": "arrow",
            "data": ["meta": 4]
        ]
    ]
    let rootObject: [String: Any] = [
        "version": 2,
        "paper": ["background": "none"],
        "nodes": initialNodes,
        "edges": initialEdges
    ]
    let sourceBytes = try encoded(rootObject)
    let document = try CanvasDocument(data: sourceBytes)
    let session = CanvasSession(document: document)
    let view = CanvasView(session: session)
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 760, height: 520))
    scroll.documentView = view
    let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = scroll
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(view)

    func key(_ code: UInt16, _ characters: String = "", modifiers: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code
        )!
        view.keyDown(with: event)
    }

    func click(_ world: CGPoint) {
        let point = view.viewPoint(forWorldPoint: world)
        let location = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            )!
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
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

    func nodeIDs() -> [String] {
        (session.root["nodes"] as! [[String: Any]]).map { $0["id"] as! String }
    }

    func edgeIDs() -> [String] {
        (session.root["edges"] as! [[String: Any]]).map { $0["id"] as! String }
    }

    let baselineRoot = session.root

    // 1. Tab / Shift-Tab traversal across nodes and connections + Escape deselection.
    let expectedOrder: [(node: String?, edge: String?)] = [
        ("back", nil), ("middle", nil), ("front", nil), ("locked", nil),
        (nil, "e-back-front"), (nil, "e-middle-front"), (nil, "e-front-loop"), (nil, "e-locked")
    ]
    for expected in expectedOrder {
        key(48) // Tab
        try require(view.selectedNodeID == expected.node && view.selectedConnectionID == expected.edge,
                    "Tab traversal did not visit \(expected)")
    }
    key(48) // Wraps back to first node
    try require(view.selectedNodeID == "back" && view.selectedConnectionID == nil,
                "Tab traversal did not wrap around to first node")
    key(48, modifiers: [.shift]) // Shift-Tab wraps to last edge
    try require(view.selectedNodeID == nil && view.selectedConnectionID == "e-locked",
                "Shift-Tab did not wrap to last connection")
    key(53) // Escape clears selection
    try require(view.selectedNodeID == nil && view.selectedConnectionID == nil &&
                NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "Escape did not clear selection cleanly")

    // 2. Pointer hit-testing on connection stroke & label, Cobalt highlight, and Connection Delete/Undo/Redo.
    let edgeSamplePoint = CGPoint(x: 305, y: 150) // On straight line from (260,150) to (420,150), outside label pill
    let unselectedEdgeColor = sample(edgeSamplePoint)
    click(CGPoint(x: 340, y: 150)) // Click label pill at midpoint
    try require(view.selectedConnectionID == "e-back-front" && view.selectedNodeID == nil,
                "Clicking connection label did not select connection")
    let selectedEdgeColor = sample(edgeSamplePoint)
    try require(colorDiff(selectedEdgeColor, unselectedEdgeColor) > 0.2 &&
                selectedEdgeColor.blueComponent > selectedEdgeColor.redComponent + 0.3,
                "Selected connection did not render in selection Cobalt")

    // Delete selected connection via Delete key (51)
    key(51)
    try require(view.selectedConnectionID == nil &&
                edgeIDs() == ["e-middle-front", "e-front-loop", "e-locked"],
                "Delete key did not remove selected connection")
    let bgAtEdge = sample(edgeSamplePoint)
    let bgReference = sample(CGPoint(x: 305, y: 80))
    try require(colorDiff(bgAtEdge, bgReference) < 0.05,
                "Deleted connection remained visible on canvas")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: session.root).isEqual(to: baselineRoot) &&
                view.selectedConnectionID == "e-back-front",
                "Undo connection delete did not restore connection at original index with metadata")
    view.redoMove(nil)
    try require(edgeIDs() == ["e-middle-front", "e-front-loop", "e-locked"] &&
                view.selectedConnectionID == nil,
                "Redo connection delete did not remove connection again")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "Second undo of connection delete did not restore baseline")

    // Deleting a connection attached to a locked node succeeds without mutating the locked node.
    click(CGPoint(x: 500, y: 240)) // Midpoint of e-locked from (500,200) to (500,280)
    try require(view.selectedConnectionID == "e-locked",
                "Clicking connection to locked node did not select it")
    key(117) // Forward Delete
    try require(!session.hasConnection("e-locked") && session.isLocked("locked"),
                "Forward Delete did not remove connection to locked node")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "Undo of locked-endpoint connection deletion altered graph")

    // 3. Stacking (Bring to Front / Send to Back) + overlap bitmap verification + no-op preservation.
    let overlapPoint = CGPoint(x: 155, y: 135) // Inside both "back" (yellow) and "middle" (blue), clear of captions
    let yellowFill = sample(CGPoint(x: 115, y: 115)) // Inside "back" only
    let blueFill = sample(CGPoint(x: 280, y: 200)) // Inside "middle" only
    try require(colorDiff(yellowFill, blueFill) > 0.3, "Back and middle fills were not distinct")
    try require(colorDiff(sample(overlapPoint), blueFill) < 0.05,
                "Higher stacking node 'middle' did not occlude 'back' initially")
    // Select "back" (at index 0) — Send to Back is a no-op and must not clear redo!
    click(CGPoint(x: 115, y: 115)) // Only inside "back"
    try require(view.selectedNodeID == "back" && !view.canSendToBack && view.canBringToFront,
                "Stacking capability flags wrong for backmost node")
    key(124) // Move right 1px
    view.undoMove(nil)
    try require(view.undoManager?.canRedo == true, "Expected redo available before no-op stacking")
    key(33, "[", modifiers: [.command, .shift]) // Send to Back on already-back node
    try require(nodeIDs() == ["back", "middle", "front", "locked"] &&
                view.undoManager?.canRedo == true,
                "No-op Send to Back mutated order or cleared redo")

    // Now Bring to Front on "back" (⌘⇧])
    key(30, "]", modifiers: [.command, .shift])
    try require(nodeIDs() == ["middle", "front", "locked", "back"] &&
                !view.canBringToFront && view.canSendToBack,
                "Bring to Front did not move 'back' to the end of nodes")
    try require(colorDiff(sample(overlapPoint), yellowFill) < 0.15,
                "Bring to Front did not render 'back' above 'middle' in overlap region")
    let frontOrderRoot = session.root
    _ = try CanvasDocument(data: session.encodedData())
    view.undoMove(nil)
    try require(NSDictionary(dictionary: session.root).isEqual(to: baselineRoot) &&
                colorDiff(sample(overlapPoint), blueFill) < 0.15,
                "Undo Bring to Front did not restore original node order and rendering")
    view.redoMove(nil)
    try require(NSDictionary(dictionary: session.root).isEqual(to: frontOrderRoot) &&
                colorDiff(sample(overlapPoint), yellowFill) < 0.15,
                "Redo Bring to Front did not restore reordered stacking")

    // Send to Back on "back" (⌘⇧[) returns it to index 0
    key(33, "[", modifiers: [.command, .shift])
    try require(NSDictionary(dictionary: session.root).isEqual(to: baselineRoot) &&
                colorDiff(sample(overlapPoint), blueFill) < 0.15,
                "Send to Back did not move node to index 0")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: session.root).isEqual(to: frontOrderRoot),
                "Undo Send to Back did not restore front position")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "Second undo did not restore baseline")

    // 4. Lock / Unlock (⌘L) + protection of locked objects + restoration of nil vs false vs true.
    click(CGPoint(x: 500, y: 330)) // Click "locked" diamond
    try require(view.selectedNodeID == "locked" && view.isSelectedNodeLocked &&
                !view.canDeleteSelection && !view.canDuplicateSelection &&
                !view.canBringToFront && !view.canSendToBack && !view.canEditGeometry,
                "Locked node did not disable mutating capabilities")
    try require(view.undoManager?.canRedo == true, "Expected redo before locked refusals")
    key(51) // Delete
    key(2, "d", modifiers: [.command]) // Duplicate
    key(30, "]", modifiers: [.command, .shift]) // Bring to Front
    key(33, "[", modifiers: [.command, .shift]) // Send to Back
    try require(NSDictionary(dictionary: session.root).isEqual(to: baselineRoot) &&
                view.undoManager?.canRedo == true,
                "Locked node accepted a prohibited command or cleared redo")

    // Unlock "locked" via ⌘L
    key(37, "l", modifiers: [.command])
    try require(!session.isLocked("locked") && session.lockedValue(of: "locked") == nil &&
                view.canEditGeometry && view.canDeleteSelection && view.canDuplicateSelection,
                "⌘L did not unlock the selected locked node")
    view.undoMove(nil)
    try require(session.isLocked("locked") && session.lockedValue(of: "locked") == true &&
                NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "Undo Unlock did not restore locked: true")
    view.redoMove(nil)
    try require(!session.isLocked("locked") && session.lockedValue(of: "locked") == nil,
                "Redo Unlock did not clear locked")
    view.undoMove(nil)

    // Lock and undo on "middle" (which had explicit "locked": false) and "back" (which omitted "locked")
    click(CGPoint(x: 220, y: 180)) // "middle"
    try require(view.selectedNodeID == "middle" && session.lockedValue(of: "middle") == false,
                "Expected middle node with explicit locked: false")
    key(37, "l", modifiers: [.command])
    try require(session.isLocked("middle") && session.lockedValue(of: "middle") == true,
                "⌘L did not lock 'middle'")
    view.undoMove(nil)
    try require(session.lockedValue(of: "middle") == false &&
                NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "Undo Lock on 'middle' did not restore explicit locked: false")

    click(CGPoint(x: 115, y: 115)) // "back"
    try require(view.selectedNodeID == "back" && session.lockedValue(of: "back") == nil,
                "Expected 'back' node with omitted locked field")
    key(37, "l", modifiers: [.command])
    try require(session.isLocked("back"), "⌘L did not lock 'back'")
    view.undoMove(nil)
    try require(session.lockedValue(of: "back") == nil &&
                NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "Undo Lock on 'back' materialized a locked field instead of omitting it")

    // 5. Node Deletion with multiple incident edges & self-loop, plus atomic Undo/Redo.
    let unrelatedEdge = try session.insertConnection(source: "back", sourceSide: .bottom, target: "middle", targetSide: .bottom)
    let beforeFrontDelete = session.root
    click(CGPoint(x: 500, y: 150)) // Select "front"
    try require(view.selectedNodeID == "front", "Expected 'front' selected before delete")
    key(51) // Delete "front"
    try require(nodeIDs() == ["back", "middle", "locked"] &&
                edgeIDs() == [unrelatedEdge.id] &&
                view.selectedNodeID == nil,
                "Deleting 'front' did not atomically remove the node and all 4 incident connections")
    _ = try CanvasDocument(data: session.encodedData())
    view.undoMove(nil)
    try require(NSDictionary(dictionary: session.root).isEqual(to: beforeFrontDelete) &&
                view.selectedNodeID == "front",
                "Undo node delete did not restore 'front' at index 2 and all 4 incident connections at their original indices")
    view.redoMove(nil)
    try require(nodeIDs() == ["back", "middle", "locked"] && edgeIDs() == [unrelatedEdge.id],
                "Redo node delete did not remove 'front' and its incident connections")
    view.undoMove(nil)
    try session.removeInsertion(unrelatedEdge)
    try require(NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "Removing temporary unrelated edge did not return to baseline")

    // 6. Duplication (⌘D): offset (+24, +24), fresh ID, preserved data, dropped top-level unknown metadata, Undo/Redo, and 1 MiB quota enforcement.
    click(CGPoint(x: 220, y: 180)) // Select "middle"
    key(2, "d", modifiers: [.command]) // ⌘D
    let afterDupNodes = session.root["nodes"] as! [[String: Any]]
    try require(afterDupNodes.count == 5, "⌘D did not append a duplicated node")
    let duplicated = afterDupNodes.last!
    let dupID = duplicated["id"] as! String
    try require(dupID != "middle" && view.selectedNodeID == dupID,
                "Duplicate did not receive a fresh selected ID")
    try require(session.position(of: dupID) == CanvasPosition(x: 164, y: 144) &&
                !session.isLocked(dupID) &&
                duplicated["future-node"] == nil &&
                NSDictionary(dictionary: duplicated["data"] as! [String: Any]).isEqual(to: initialNodes[1]["data"] as! [String: Any]),
                "Duplicate did not offset by (+24,+24), omit top-level unknown metadata, or preserve data")
    let afterDupRoot = session.root
    view.undoMove(nil)
    try require(NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "Undo Duplicate did not restore baseline")
    view.redoMove(nil)
    try require(NSDictionary(dictionary: session.root).isEqual(to: afterDupRoot) &&
                view.selectedNodeID == dupID,
                "Redo Duplicate did not restore identical ID and state")
    view.undoMove(nil)

    // Duplicate quota enforcement for 256 KiB attachments and 256 KiB code blocks (1 MiB total each).
    let maxChunk = String(repeating: "x", count: 262_144)
    let attachmentNodes: [[String: Any]] = (0..<4).map { i in
        [
            "id": "att-\(i)", "type": "shape", "x": Double(i * 40), "y": 0, "width": 120, "height": 80,
            "data": [
                "kind": "rect",
                "attachment": [
                    "filename": "f\(i).txt", "media_type": "text/plain",
                    "encoding": "utf-8", "content": maxChunk
                ]
            ]
        ]
    }
    let codeNodes: [[String: Any]] = (0..<4).map { i in
        [
            "id": "code-\(i)", "type": "code", "x": Double(i * 40), "y": 120, "width": 160, "height": 100,
            "data": ["content": maxChunk, "language": "elixir"]
        ]
    }
    let quotaDoc = try CanvasDocument(data: encoded(canvas(attachmentNodes + codeNodes)))
    let quotaSession = CanvasSession(document: quotaDoc)
    let quotaBefore = quotaSession.root
    for id in ["att-0", "code-0"] {
        do {
            _ = try quotaSession.duplicateNode(id)
            throw CheckFailure(description: "Duplicate exceeded 1 MiB quota for \(id)")
        } catch let error as CanvasDocumentError {
            try require(error.localizedDescription.contains("1048576"),
                        "Unexpected quota error for \(id): \(error)")
        }
        try require(NSDictionary(dictionary: quotaSession.root).isEqual(to: quotaBefore),
                    "Refused quota duplicate mutated session for \(id)")
    }
    // Deleting one attachment and one code node frees budget to duplicate once each.
    let deletedAtt = try quotaSession.deleteNode("att-3")
    let dupAtt = try quotaSession.duplicateNode("att-0")
    try require(quotaSession.position(of: dupAtt.id) == CanvasPosition(x: 24, y: 24),
                "Attachment duplicate after freeing quota failed")
    do {
        try quotaSession.restoreNodeDeletion(deletedAtt)
        throw CheckFailure(description: "Restoring deleted attachment exceeded 1 MiB quota")
    } catch is CanvasDocumentError {}
    try quotaSession.removeInsertion(dupAtt)
    try quotaSession.restoreNodeDeletion(deletedAtt)

    let deletedCode = try quotaSession.deleteNode("code-3")
    let dupCode = try quotaSession.duplicateNode("code-0")
    try require(quotaSession.position(of: dupCode.id) == CanvasPosition(x: 24, y: 144),
                "Code duplicate after freeing quota failed")
    try quotaSession.removeInsertion(dupCode)
    try quotaSession.restoreNodeDeletion(deletedCode)
    try require(NSDictionary(dictionary: quotaSession.root).isEqual(to: quotaBefore),
                "Quota delete/duplicate/restore cycle did not return to exact initial state")

    try require(session.document.originalData == sourceBytes,
                "Lifecycle operations mutated original document bytes")
    window.orderOut(nil)

    // 7. Real AppDelegate menu validation, NSApp key-equivalent/sendEvent routing,
    //    Delete inside an active ShapeTextEditor sheet, and disabled mutations during G previews.
    let appDelegate = CanvasAppDelegate()
    appDelegate.installMenu()
    let appSession = CanvasSession(document: try CanvasDocument(data: sourceBytes))
    let appCanvas = appDelegate.showSession(appSession, name: "MenuSmoke")
    defer { appDelegate.closeAllWindows() }
    guard let appWindow = appCanvas.window,
          let editMenu = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu,
          let insertMenu = NSApp.mainMenu?.item(withTitle: "Insert")?.submenu else {
        throw CheckFailure(description: "CanvasAppDelegate did not install Edit/Insert menus or window")
    }

    func editItem(_ title: String) throws -> NSMenuItem {
        guard let item = editMenu.items.first(where: { $0.title == title }) else {
            throw CheckFailure(description: "Missing Edit menu item: \(title)")
        }
        return item
    }

    func dispatchAppKey(_ code: UInt16, _ chars: String, modifiers: NSEvent.ModifierFlags = []) {
        let targetWindow = appWindow.attachedSheet ?? appWindow
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

    // Initially nothing is selected: mutating Edit items validate as false.
    editMenu.update()
    for title in ["Duplicate", "Delete", "Bring to Front", "Send to Back", "Lock", "Edit Geometry"] {
        try require(!appDelegate.validateMenuItem(try editItem(title)),
                    "Menu item '\(title)' was enabled with empty selection")
    }

    // Traverse to "back" via NSApp-dispatched Tab, then exercise menu items and key equivalents.
    dispatchAppKey(48, "\t")
    try require(appCanvas.selectedNodeID == "back", "NSApp-dispatched Tab did not select 'back'")
    try require(appDelegate.validateMenuItem(try editItem("Duplicate")) &&
                appDelegate.validateMenuItem(try editItem("Delete")) &&
                appDelegate.validateMenuItem(try editItem("Bring to Front")) &&
                !appDelegate.validateMenuItem(try editItem("Send to Back")) &&
                appDelegate.validateMenuItem(try editItem("Lock")) &&
                (try editItem("Lock")).title == "Lock",
                "Edit menu validation did not reflect selected backmost unlocked node")

    // Lock via Edit -> Lock menu item, verify title switches to "Unlock" and mutations disable.
    let lockMenuItem = try editItem("Lock")
    _ = appDelegate.perform(lockMenuItem.action!, with: lockMenuItem)
    try require(appSession.isLocked("back"), "Edit -> Lock menu action did not lock 'back'")
    try require(appDelegate.validateMenuItem(lockMenuItem) && lockMenuItem.title == "Unlock" &&
                !appDelegate.validateMenuItem(try editItem("Duplicate")) &&
                !appDelegate.validateMenuItem(try editItem("Delete")) &&
                !appDelegate.validateMenuItem(try editItem("Bring to Front")),
                "Menu validation did not update to 'Unlock' and disable mutations on locked node")
    // Unlock via ⌘L key equivalent through NSApp.mainMenu.performKeyEquivalent
    dispatchAppKey(37, "l", modifiers: [.command])
    try require(!appSession.isLocked("back") && appDelegate.validateMenuItem(lockMenuItem) &&
                lockMenuItem.title == "Lock",
                "⌘L key equivalent did not unlock 'back' and restore 'Lock' menu title")
    // Undo Lock/Unlock via ⌘Z twice so history is clean
    dispatchAppKey(6, "z", modifiers: [.command])
    dispatchAppKey(6, "z", modifiers: [.command])
    try require(NSDictionary(dictionary: appSession.root).isEqual(to: baselineRoot),
                "Menu Lock/Unlock undo did not restore baseline")

    // Enter G geometry preview via Edit -> Edit Geometry and verify mutations are disabled in menu & ignored via keys.
    let geomMenuItem = try editItem("Edit Geometry")
    try require(appDelegate.validateMenuItem(geomMenuItem), "Edit Geometry was disabled for unlocked shape")
    _ = appDelegate.perform(geomMenuItem.action!, with: geomMenuItem)
    try require(appCanvas.hasGeometryPreview, "Edit -> Edit Geometry did not start geometry preview")
    dispatchAppKey(124, "") // Right arrow nudges preview width +1
    for title in ["Duplicate", "Delete", "Bring to Front", "Send to Back", "Lock", "Edit Geometry"] {
        let item = try editItem(title)
        try require(!appDelegate.validateMenuItem(item),
                    "Menu item '\(title)' stayed enabled during active G geometry preview")
    }
    for item in insertMenu.items where item.action != nil {
        try require(!appDelegate.validateMenuItem(item),
                    "Insert menu item '\(item.title)' stayed enabled during active G geometry preview")
    }
    // Dispatching Delete, ⌘D, ⌘L, ⇧⌘], ⇧⌘[ during G preview must not mutate graph or drop the preview.
    dispatchAppKey(51, "\u{7f}")
    dispatchAppKey(2, "d", modifiers: [.command])
    dispatchAppKey(37, "l", modifiers: [.command])
    dispatchAppKey(30, "]", modifiers: [.command, .shift])
    dispatchAppKey(33, "[", modifiers: [.command, .shift])
    try require(appCanvas.hasGeometryPreview &&
                NSDictionary(dictionary: appSession.root).isEqual(to: baselineRoot),
                "Mutating shortcuts leaked through active G geometry preview")
    // ⌘Z cancels the pending geometry preview first without undoing committed history.
    dispatchAppKey(6, "z", modifiers: [.command])
    try require(!appCanvas.hasGeometryPreview &&
                NSDictionary(dictionary: appSession.root).isEqual(to: baselineRoot),
                "⌘Z did not cancel active G geometry preview cleanly")

    // Open inline on-canvas text editor via Return, then press Delete/Backspace and ⌘D/⌘L inside the inline editor.
    dispatchAppKey(36, "\r")
    guard appWindow.attachedSheet == nil,
          appCanvas.hasActiveInlineTextEditor,
          let inlineEditor = appCanvas.inlineTextEditorView,
          appWindow.firstResponder === inlineEditor else {
        throw CheckFailure(description: "Return did not open and focus inline on-canvas text editor")
    }
    for title in ["Duplicate", "Delete", "Bring to Front", "Send to Back", "Lock", "Edit Geometry"] {
        let item = try editItem(title)
        try require(!appDelegate.validateMenuItem(item),
                    "Menu item '\(title)' stayed enabled while inline text editor was active")
    }
    inlineEditor.string = "Back!"
    inlineEditor.setSelectedRange(NSRange(location: 5, length: 0))
    // Dispatch Backspace through NSApp (which checks mainMenu.performKeyEquivalent first, then inline editor responder)
    dispatchAppKey(51, "\u{7f}")
    try require(inlineEditor.string == "Back" &&
                appSession.position(of: "back") != nil &&
                appCanvas.hasActiveInlineTextEditor,
                "Backspace inside inline text editor deleted the canvas node or failed to delete text character")
    // Also verify CanvasAppDelegate.deleteSelection routes to NSTextView.deleteBackward when invoked while editor is firstResponder
    inlineEditor.string = "Back?"
    inlineEditor.setSelectedRange(NSRange(location: 5, length: 0))
    appDelegate.deleteSelection(nil)
    try require(inlineEditor.string == "Back" && appSession.position(of: "back") != nil,
                "CanvasAppDelegate.deleteSelection did not route to active inline NSTextView")
    // Cancel inline editor via Escape
    dispatchAppKey(53, "\u{1b}")
    try require(!appCanvas.hasActiveInlineTextEditor &&
                appWindow.attachedSheet == nil &&
                NSDictionary(dictionary: appSession.root).isEqual(to: baselineRoot),
                "Escape did not dismiss inline text editor cleanly")

    // Finally exercise Duplicate, Bring to Front, Send to Back, and Delete through menu actions / key equivalents.
    dispatchAppKey(2, "d", modifiers: [.command]) // ⌘D duplicates "back"
    try require((appSession.root["nodes"] as! [Any]).count == 5,
                "⌘D key equivalent did not duplicate 'back' through mainMenu")
    dispatchAppKey(51, "\u{7f}") // Backspace deletes the selected duplicate via NSApp.sendEvent -> CanvasView.keyDown
    try require(NSDictionary(dictionary: appSession.root).isEqual(to: baselineRoot),
                "Backspace did not delete the selected duplicate through NSApp.sendEvent")
    // Undo deletion via ⌘Z (restoring and selecting the duplicate), then exercise Edit -> Delete menu action directly.
    dispatchAppKey(6, "z", modifiers: [.command])
    let deleteMenuItem = try editItem("Delete")
    try require(appDelegate.validateMenuItem(deleteMenuItem), "Edit -> Delete was disabled for selected duplicate")
    _ = appDelegate.perform(deleteMenuItem.action!, with: deleteMenuItem)
    try require(NSDictionary(dictionary: appSession.root).isEqual(to: baselineRoot),
                "Edit -> Delete menu action did not delete the selected duplicate")

    // 8. Attachment preview sheet (locked & unlocked cards, literal BOM/CRLF/tabs, Copy Source, Escape/Return close)
    //    and rotated shape text-box live/committed growth keeping top anchor fixed.
    let v1Bytes = try Data(contentsOf: repository.appendingPathComponent("shared/fixtures/v1/compatibility.json"))
    let v1Session = CanvasSession(document: try CanvasDocument(data: v1Bytes))
    let v1Baseline = v1Session.root
    let v1Canvas = appDelegate.showSession(v1Session, name: "AttachmentAndGrowthSmoke")
    guard let v1Window = v1Canvas.window else {
        throw CheckFailure(description: "Missing window for v1 attachment/growth smoke")
    }
    func v1SheetControl<T: NSView>(_ id: String, as type: T.Type) throws -> T {
        guard let rootView = v1Window.attachedSheet?.contentView else {
            throw CheckFailure(description: "No attached sheet on v1Window for \(id)")
        }
        func find(in view: NSView) -> T? {
            if view.identifier?.rawValue == id, let matched = view as? T { return matched }
            for sub in view.subviews {
                if let found = find(in: sub) { return found }
            }
            return nil
        }
        guard let control = find(in: rootView) else {
            throw CheckFailure(description: "Missing sheet control '\(id)'")
        }
        return control
    }

    // Tab once selects "rect" (locked, with attachment "資料.md" containing BOM/CRLF/tabs).
    dispatchAppKey(48, "\t")
    try require(v1Canvas.selectedNodeID == "rect" && v1Canvas.isSelectedNodeLocked &&
                v1Canvas.canPreviewAttachment && !v1Canvas.canEditTextSelection,
                "Locked attachment shape 'rect' did not enable attachment preview while disabling text editing")
    try require(appDelegate.validateMenuItem(try editItem("Preview Attachment…")) &&
                !appDelegate.validateMenuItem(try editItem("Edit Text…")),
                "Menu validation wrong for locked attachment node")
    // Return on locked attachment node opens read-only AttachmentPreviewSheet!
    dispatchAppKey(36, "\r")
    let previewTitle = try v1SheetControl("attachment-preview-title", as: NSTextField.self)
    let previewMeta = try v1SheetControl("attachment-preview-meta", as: NSTextField.self)
    let previewText = try v1SheetControl("attachment-preview-content", as: NSTextView.self)
    let expectedAttachmentContent = "\u{feff}雪\r\nCafé\t🌿\r\n"
    try require(previewTitle.stringValue == "資料.md" &&
                previewMeta.stringValue.contains("text/markdown") &&
                !previewText.isEditable &&
                previewText.string.utf8.elementsEqual(expectedAttachmentContent.utf8),
                "AttachmentPreviewSheet did not show read-only literal UTF-8 content with BOM/CRLF/tabs")
    // Close and reopen with a private pasteboard so Copy Source check never overwrites the user's system clipboard.
    dispatchAppKey(53, "\u{1b}")
    let testPasteboard = NSPasteboard.withUniqueName()
    defer { testPasteboard.releaseGlobally() }
    v1Canvas.attachmentPasteboard = testPasteboard
    dispatchAppKey(36, "\r")
    try v1SheetControl("attachment-preview-copy", as: NSButton.self).performClick(nil)
    let copiedData = testPasteboard.data(forType: .string) ?? Data()
    try require(copiedData.elementsEqual(expectedAttachmentContent.utf8),
                "Copy Source in AttachmentPreviewSheet did not copy exact literal UTF-8 bytes")
    // Escape closes preview without dirtying or recording history.
    dispatchAppKey(53, "\u{1b}")
    try require(v1Window.attachedSheet == nil &&
                v1Canvas.undoManager?.canUndo != true &&
                NSDictionary(dictionary: v1Session.root).isEqual(to: v1Baseline),
                "Previewing and closing attachment mutated session or history")

    // Tab to "ellipse" (unlocked, with empty attachment "empty.txt" AND caption "Oval").
    dispatchAppKey(48, "\t")
    try require(v1Canvas.selectedNodeID == "ellipse" &&
                v1Canvas.canPreviewAttachment && v1Canvas.canEditTextSelection,
                "Unlocked attachment shape 'ellipse' did not enable both Preview Attachment and Edit Text")
    dispatchAppKey(36, "\r") // Return opens AttachmentPreviewSheet on attachment card
    let emptyStatus = try v1SheetControl("attachment-preview-status", as: NSTextField.self)
    try require(!emptyStatus.isHidden && emptyStatus.stringValue.contains("empty"),
                "Empty attachment preview did not display empty status")
    dispatchAppKey(36, "\r") // Return inside read-only preview dismisses it
    try require(v1Window.attachedSheet == nil, "Return inside AttachmentPreviewSheet did not close it")

    // Tab to "diamond" then "triangle" (unlocked rotated shape at 12.5 degrees).
    dispatchAppKey(48, "\t") // diamond
    dispatchAppKey(48, "\t") // triangle
    try require(v1Canvas.selectedNodeID == "triangle", "Expected 'triangle' selected")
    let triBeforeGeo = v1Session.geometry(of: "triangle")!
    let triTopAnchorBefore = triBeforeGeo.point(for: .top)
    // Open inline text editor on "triangle" via Return, enter 8 multiline rows to trigger box growth.
    dispatchAppKey(36, "\r")
    guard v1Window.attachedSheet == nil,
          v1Canvas.hasActiveInlineTextEditor,
          let triEditor = v1Canvas.inlineTextEditorView,
          v1Window.firstResponder === triEditor else {
        throw CheckFailure(description: "Return on 'triangle' did not open inline on-canvas text editor")
    }
    let longMultiline = (1...8).map { "Line \($0) of rotated growth" }.joined(separator: "\n")
    triEditor.string = longMultiline
    // Live preview must not mutate committed session geometry before commit!
    try require(v1Session.geometry(of: "triangle") == triBeforeGeo &&
                v1Session.text(of: "triangle") == "三角",
                "Inline text editor live growth preview leaked into committed session state")
    // Commit with Return (or Command-Return); verify text + rotated height growth commit as one transaction with top anchor fixed!
    triEditor.keyDown(with: NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: v1Window.windowNumber,
        context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
        isARepeat: false, keyCode: 36
    )!)
    try require(!v1Canvas.hasActiveInlineTextEditor && v1Window.attachedSheet == nil,
                "Return did not commit and close inline on-canvas text editor")
    let triAfterGeo = v1Session.geometry(of: "triangle")!
    let triTopAnchorAfter = triAfterGeo.point(for: .top)
    try require(v1Session.text(of: "triangle") == longMultiline &&
                triAfterGeo.height > triBeforeGeo.height &&
                triAfterGeo.width == triBeforeGeo.width &&
                triAfterGeo.rotation == triBeforeGeo.rotation &&
                abs(triTopAnchorAfter.x - triTopAnchorBefore.x) < 0.0001 &&
                abs(triTopAnchorAfter.y - triTopAnchorBefore.y) < 0.0001,
                "Committed multiline text on rotated triangle did not grow height while keeping top anchor fixed")
    let triGrownRoot = v1Session.root
    dispatchAppKey(6, "z", modifiers: [.command]) // Single Undo restores both text and original geometry!
    try require(NSDictionary(dictionary: v1Session.root).isEqual(to: v1Baseline),
                "Single Undo of text+growth commit did not restore exact original text and geometry")
    dispatchAppKey(6, "Z", modifiers: [.command, .shift]) // Single Redo reapplies both text and grown geometry!
    try require(NSDictionary(dictionary: v1Session.root).isEqual(to: triGrownRoot),
                "Single Redo of text+growth commit did not restore grown geometry and text")
    dispatchAppKey(6, "z", modifiers: [.command])
    try require(v1Session.document.originalData == v1Bytes,
                "Attachment preview and text growth checks mutated original v1 bytes")
    // Verify inline editor placement and font scaling at 50% zoom (0.5x) and 90° rotation.
    _ = try v1Session.setGeometry("triangle", to: CanvasGeometry(
        x: triBeforeGeo.x, y: triBeforeGeo.y, width: triBeforeGeo.width, height: triBeforeGeo.height, rotation: 90
    ))
    v1Canvas.setZoom(0.5)
    dispatchAppKey(36, "\r")
    guard let rotatedZoomedEditor = v1Canvas.inlineTextEditorView,
          let scrollContainer = rotatedZoomedEditor.enclosingScrollView else {
        throw CheckFailure(description: "Expected active inline editor at 50% zoom and 90° rotation")
    }
    let expectedCenter = v1Canvas.viewPoint(forWorldPoint: CGPoint(
        x: triBeforeGeo.x + triBeforeGeo.width / 2,
        y: triBeforeGeo.y + triBeforeGeo.height / 2
    ))
    let actualCenter = scrollContainer.convert(
        CGPoint(x: scrollContainer.bounds.midX, y: scrollContainer.bounds.midY),
        to: v1Canvas
    )
    let unitX = scrollContainer.convert(CGPoint(x: 1, y: 0), to: v1Canvas)
    let originPt = scrollContainer.convert(CGPoint.zero, to: v1Canvas)
    try require(
        rotatedZoomedEditor.frame.size == scrollContainer.contentView.bounds.size &&
        hypot(scrollContainer.contentView.bounds.origin.x, scrollContainer.contentView.bounds.origin.y) < 1.0 &&
        abs(rotatedZoomedEditor.font!.pointSize - 8.0) < 0.01 &&
        abs(scrollContainer.frameRotation - 90.0) < 0.01 &&
        hypot(actualCenter.x - expectedCenter.x, actualCenter.y - expectedCenter.y) < 0.5 &&
        abs((unitX.x - originPt.x) - 0.0) < 0.01 &&
        abs((unitX.y - originPt.y) - 1.0) < 0.01,
        "Inline editor at 50% zoom and 90° rotation failed: editorFrame=\(rotatedZoomedEditor.frame), clipBounds=\(scrollContainer.contentView.bounds), fontPt=\(rotatedZoomedEditor.font!.pointSize), rot=\(scrollContainer.frameRotation), actualCenter=\(actualCenter) vs expected=\(expectedCenter), unitX=\(unitX) vs origin=\(originPt)"
    )
    dispatchAppKey(53, "\u{1b}") // Cancel inline editor
    v1Canvas.resetZoom(nil)
    _ = try v1Session.setGeometry("triangle", to: triBeforeGeo)
    // Also verify empty-triangle inline editor after tall->short reuse has exact non-overflowing documentView frame.
    v1Canvas.insertShape(.triangle)
    dispatchAppKey(36, "\r")
    guard let emptyTriEditor = v1Canvas.inlineTextEditorView,
          let emptyTriScroll = emptyTriEditor.enclosingScrollView else {
        throw CheckFailure(description: "Expected active inline editor on newly inserted empty triangle")
    }
    try require(
        emptyTriEditor.frame.size == emptyTriScroll.contentView.bounds.size &&
        emptyTriScroll.contentView.bounds.origin == .zero &&
        !emptyTriScroll.hasVerticalScroller,
        "Empty triangle inline editor overflowed contentView after tall->short reuse (\(emptyTriEditor.frame.size) vs \(emptyTriScroll.contentView.bounds.size))"
    )
    dispatchAppKey(53, "\u{1b}")
    dispatchAppKey(6, "z", modifiers: [.command]) // Undo inserted triangle
    _ = try v1Session.setGeometry("triangle", to: triBeforeGeo)
    try require(NSDictionary(dictionary: v1Session.root).isEqual(to: v1Baseline),
                "Restoring 90° rotation test did not match v1Baseline")

    print("PASS AppDelegate menu validation, NSApp key-equivalent routing, text-sheet Delete isolation and G-preview guards")
    print("PASS attachment preview sheet (locked/unlocked, literal BOM/CRLF, Copy Source) and rotated text-box growth")
    print("PASS lifecycle: connection selection/deletion, Tab traversal, node deletion with incident edges, duplicate quotas, stacking and lock/unlock")
}

@MainActor
func checkAdjacentThoughtsAndViewport(repository: URL) throws {
    // 1. Deterministic placement math: all 4 cardinal directions, rotated source bounds, and multi-pass ray blockers.
    let uprightSource = CanvasGeometry(x: 100, y: 200, width: 200, height: 120)
    try require(
        CanvasGeometry.adjacentThoughtBox(source: uprightSource, obstacles: [], direction: .right)
            == CanvasGeometry(x: 348, y: 212, width: 160, height: 96),
        "Right adjacent thought did not place 48 units past source right edge centered vertically"
    )
    try require(
        CanvasGeometry.adjacentThoughtBox(source: uprightSource, obstacles: [], direction: .left)
            == CanvasGeometry(x: -108, y: 212, width: 160, height: 96),
        "Left adjacent thought did not place 48 units before source left edge"
    )
    try require(
        CanvasGeometry.adjacentThoughtBox(source: uprightSource, obstacles: [], direction: .down)
            == CanvasGeometry(x: 120, y: 368, width: 160, height: 96),
        "Down adjacent thought did not place 48 units below source bottom edge"
    )
    try require(
        CanvasGeometry.adjacentThoughtBox(source: uprightSource, obstacles: [], direction: .up)
            == CanvasGeometry(x: 120, y: 56, width: 160, height: 96),
        "Up adjacent thought did not place 48 units above source top edge"
    )

    // Rotated 90-degree source: 200x100 centered at (200, 150) has rotated bounds x:150..250, y:50..250.
    let rotated90 = CanvasGeometry(x: 100, y: 100, width: 200, height: 100, rotation: 90)
    try require(
        CanvasGeometry.adjacentThoughtBox(source: rotated90, obstacles: [], direction: .right)
            == CanvasGeometry(x: 298, y: 102, width: 160, height: 96),
        "Rotated source did not measure 48-unit gap from rotated axis-aligned bounds"
    )

    // Multi-pass ray blocker skipping (including a rotated blocker and an off-ray non-blocker).
    let blocker1 = CanvasGeometry(x: 340, y: 200, width: 160, height: 96)
    let blocker2 = CanvasGeometry(x: 540, y: 180, width: 120, height: 160, rotation: 90) // rotated bounds x:520..680, y:200..320
    let offRay = CanvasGeometry(x: 360, y: 600, width: 160, height: 96) // far below 48-unit cross clearance
    let skipped = CanvasGeometry.adjacentThoughtBox(
        source: uprightSource,
        obstacles: [blocker2, offRay, blocker1],
        direction: .right
    )
    try require(
        skipped == CanvasGeometry(x: 728, y: 212, width: 160, height: 96),
        "Adjacent thought did not skip both ray blockers in multiple passes (got \(skipped))"
    )

    // 2. Interactive N workflow, eligibility guards, live growth + blocker recheck, 2000-grapheme limit, chained N, Undo/Redo.
    let initialNodes: [[String: Any]] = [
        [
            "id": "origin", "type": "shape", "x": 100, "y": 100, "width": 160, "height": 96,
            "future-meta": "keep-origin",
            "data": ["kind": "ellipse", "fill": "yellow", "stroke": "red", "font": "heading", "text": "Origin"]
        ],
        [
            "id": "tall-blocker", "type": "shape", "x": 308, "y": 250, "width": 160, "height": 96,
            "data": ["kind": "rect", "fill": "blue", "stroke": "ink", "text": "Lower Blocker"]
        ],
        [
            "id": "locked-shape", "type": "shape", "x": 100, "y": 320, "width": 160, "height": 96,
            "locked": true,
            "data": ["kind": "rect", "text": "Locked"]
        ],
        [
            "id": "free-line", "type": "shape-line", "x": 800, "y": 100, "width": 144, "height": 24,
            "data": ["from": [12, 12], "to": [132, 12], "stroke": "ink", "width": 2, "arrow": "end"]
        ],
        [
            "id": "code-node", "type": "code", "x": 800, "y": 220, "width": 200, "height": 100,
            "data": ["content": "IO.puts(:ok)", "language": "elixir"]
        ]
    ]
    let initialEdges: [[String: Any]] = [
        [
            "id": "e1", "source": "origin", "source_handle": "bottom",
            "target": "locked-shape", "target_handle": "top", "path": "straight", "marker": "arrow"
        ]
    ]
    let rootObj: [String: Any] = [
        "version": 2,
        "paper": ["background": "none"],
        "nodes": initialNodes,
        "edges": initialEdges
    ]
    let sourceBytes = try encoded(rootObj)
    let doc = try CanvasDocument(data: sourceBytes)
    let session = CanvasSession(document: doc)
    let appDelegate = CanvasAppDelegate()
    appDelegate.installMenu()
    let view = appDelegate.showSession(session, name: "ThoughtChecks")
    defer { appDelegate.closeAllWindows() }
    guard let window = view.window else {
        throw CheckFailure(description: "Expected window for ThoughtChecks")
    }

    func key(_ code: UInt16, _ characters: String = "", modifiers: NSEvent.ModifierFlags = [], to targetView: NSView? = nil) {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters.lowercased(),
            isARepeat: false, keyCode: code
        )!
        (targetView ?? view).keyDown(with: event)
    }

    func keyUp(_ code: UInt16, _ characters: String = "") {
        let event = NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters.lowercased(),
            isARepeat: false, keyCode: code
        )!
        view.keyUp(with: event)
    }

    func mouse(_ type: NSEvent.EventType, world: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        let pt = view.viewPoint(forWorldPoint: world)
        let loc = view.convert(pt, to: nil)
        let event = NSEvent.mouseEvent(
            with: type, location: loc, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        )!
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        default: break
        }
    }

    let baselineRoot = session.root

    // Empty selection, locked shape, standalone line, code node, and connection must all refuse N.
    key(45, "n")
    try require(!view.hasAdjacentThoughtPreview, "Empty selection entered adjacent thought mode")
    mouse(.leftMouseDown, world: CGPoint(x: 180, y: 368))
    mouse(.leftMouseUp, world: CGPoint(x: 180, y: 368))
    try require(view.selectedNodeID == "locked-shape" && !view.canInsertAdjacentThought,
                "Locked shape reported eligible for adjacent thought")
    key(45, "n")
    try require(!view.hasAdjacentThoughtPreview, "Locked shape entered adjacent thought mode")

    mouse(.leftMouseDown, world: CGPoint(x: 860, y: 112))
    mouse(.leftMouseUp, world: CGPoint(x: 860, y: 112))
    try require(view.selectedNodeID == "free-line" && !view.canInsertAdjacentThought,
                "Standalone line reported eligible for adjacent thought")
    key(45, "n")
    try require(!view.hasAdjacentThoughtPreview, "Standalone line entered adjacent thought mode")

    mouse(.leftMouseDown, world: CGPoint(x: 900, y: 270))
    mouse(.leftMouseUp, world: CGPoint(x: 900, y: 270))
    try require(view.selectedNodeID == "code-node" && !view.canInsertAdjacentThought,
                "Code block reported eligible for adjacent thought")
    key(45, "n")
    try require(!view.hasAdjacentThoughtPreview, "Code block entered adjacent thought mode")

    mouse(.leftMouseDown, world: CGPoint(x: 180, y: 250))
    mouse(.leftMouseUp, world: CGPoint(x: 180, y: 250))
    try require(view.selectedConnectionID == "e1" && !view.canInsertAdjacentThought,
                "Selected connection reported eligible for adjacent thought")
    key(45, "n")
    try require(!view.hasAdjacentThoughtPreview, "Selected connection entered adjacent thought mode")

    // Select unlocked "origin" shape, create a redo entry to verify chooser/draft cancellation preserves redo.
    mouse(.leftMouseDown, world: CGPoint(x: 180, y: 148))
    mouse(.leftMouseUp, world: CGPoint(x: 180, y: 148))
    try require(view.selectedNodeID == "origin" && view.canInsertAdjacentThought,
                "Unlocked shape 'origin' was not eligible for adjacent thought")
    key(124) // Move right 1px
    view.undoMove(nil)
    try require(view.undoManager?.canRedo == true, "Expected redo before adjacent thought cancel checks")

    // Stage 1: N -> direction chooser -> Escape cancels without touching session or redo.
    key(45, "n")
    try require(view.isChoosingAdjacentThoughtDirection && !view.hasAdjacentThoughtDraft,
                "N did not enter direction chooser state")
    key(53) // Escape
    try require(!view.hasAdjacentThoughtPreview &&
                NSDictionary(dictionary: session.root).isEqual(to: baselineRoot) &&
                view.undoManager?.canRedo == true,
                "Cancelling direction chooser mutated session or cleared redo")

    // Stage 2: N -> Right arrow -> draft editor -> live multiline growth rechecks blocker -> Escape cancels cleanly.
    key(45, "n")
    key(124) // Right arrow
    try require(view.hasAdjacentThoughtDraft &&
                view.adjacentThoughtDraftGeometry == CanvasGeometry(x: 308, y: 100, width: 160, height: 96) &&
                window.firstResponder === view.adjacentThoughtTextView,
                "Right arrow did not place initial 160x96 draft at (308, 100) and focus inline editor")
    // Verify "tall-blocker" at (308, 250) is NOT overlapping when height is 96 (100 + 96 + 48 = 244 < 250),
    // but when multiline text grows height past 102, 100 + height + 48 > 250 so placement skips past tall-blocker (to x = 516)!
    let tallText = (1...8).map { "Thought line \($0)" }.joined(separator: "\n")
    view.adjacentThoughtTextView?.string = tallText
    // Verify CanvasView.draw(_:) only draws the preview box border/background and never paints a second
    // duplicate copy of the draft text underneath the live thoughtInputView.
    if let checkGeo = view.adjacentThoughtDraftGeometry {
        let boxRect = CGRect(
            x: view.viewPoint(forWorldPoint: CGPoint(x: checkGeo.x + 12, y: checkGeo.y + 12)).x,
            y: view.viewPoint(forWorldPoint: CGPoint(x: checkGeo.x + 12, y: checkGeo.y + 12)).y,
            width: CGFloat(checkGeo.width) - 24,
            height: CGFloat(checkGeo.height) - 24
        )
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(boxRect.width), pixelsHigh: Int(boxRect.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.translateBy(x: -boxRect.minX, y: -boxRect.minY)
        view.draw(boxRect)
        NSGraphicsContext.restoreGraphicsState()
        let bg = CanvasTheme.canvasBackground.usingColorSpace(.sRGB)!
        for sampleY in stride(from: 4, to: rep.pixelsHigh - 4, by: 6) {
            for sampleX in stride(from: 4, to: rep.pixelsWide - 4, by: 8) {
                let c = rep.colorAt(x: sampleX, y: sampleY)!.usingColorSpace(.sRGB)!
                let diff = abs(c.redComponent - bg.redComponent) + abs(c.greenComponent - bg.greenComponent) + abs(c.blueComponent - bg.blueComponent)
                try require(diff < 0.05, "CanvasView.draw(_:) painted duplicate draft text underneath thoughtInputView")
            }
        }
    }
    guard let grownGeo = view.adjacentThoughtDraftGeometry else {
        throw CheckFailure(description: "Missing grown adjacent thought geometry")
    }
    try require(grownGeo.height > 120 && grownGeo.x == 516,
                "Live text growth did not recheck blocker and skip past tall-blocker to x=516 (got \(grownGeo))")
    try require(NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "Live adjacent thought draft leaked into committed session state")
    key(53) // Escape cancels draft
    try require(!view.hasAdjacentThoughtPreview &&
                NSDictionary(dictionary: session.root).isEqual(to: baselineRoot) &&
                view.undoManager?.canRedo == true,
                "Escape from active thought draft mutated session or cleared redo")

    // Over-limit 2001-grapheme refusal keeps draft intact; 2000 combining graphemes commits; chained N works!
    key(45, "n")
    key(126) // Up arrow -> places at (100, -44)
    try require(view.adjacentThoughtDraftGeometry == CanvasGeometry(x: 100, y: -44, width: 160, height: 96),
                "Up arrow did not place thought at (100, -44)")
    view.adjacentThoughtTextView?.string = String(repeating: "x", count: 2001)
    key(36, "\r") // Return attempts commit
    try require(view.hasAdjacentThoughtDraft &&
                view.adjacentThoughtTextView?.string.count == 2001 &&
                view.adjacentThoughtError != nil &&
                NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "2001-grapheme thought draft was not refused with intact text")

    // Shorten to 2000 combining-character graphemes ("e\u{301}") -> commits in one transaction!
    let boundaryText = String(repeating: "e\u{301}", count: 2000)
    view.adjacentThoughtTextView?.string = boundaryText
    key(36, "\r")
    try require(!view.hasAdjacentThoughtPreview, "Valid 2000-grapheme thought did not finish")
    guard let firstThoughtID = view.selectedNodeID, firstThoughtID != "origin" else {
        throw CheckFailure(description: "Committed adjacent thought was not selected for chaining")
    }
    let firstThoughtRaw = (session.root["nodes"] as! [[String: Any]]).first { $0["id"] as? String == firstThoughtID }!
    let firstThoughtData = firstThoughtRaw["data"] as! [String: Any]
    try require(firstThoughtRaw["future-meta"] == nil &&
                firstThoughtData["kind"] as? String == "rect" &&
                firstThoughtData["fill"] as? String == "none" &&
                firstThoughtData["stroke"] as? String == "ink" &&
                firstThoughtData["font"] == nil &&
                firstThoughtData["text"] as? String == boundaryText &&
                (session.root["edges"] as! [[String: Any]]).count == initialEdges.count,
                "Adjacent thought cloned source metadata/styles or created an unrequested edge")

    // Immediate chained N from the newly added thought with blank/whitespace text via Shift-Return newline!
    key(45, "n")
    key(123) // Left arrow from firstThoughtID
    try require(view.hasAdjacentThoughtDraft, "Chained N did not start from newly committed thought")
    key(36, "\r", modifiers: [.shift]) // Shift-Return inserts newline without committing
    try require(view.hasAdjacentThoughtDraft && view.adjacentThoughtDraftText == "\n",
                "Shift-Return did not insert a newline in the adjacent thought draft")
    key(36, "\r") // Return commits whitespace-only thought
    guard let secondThoughtID = view.selectedNodeID,
          secondThoughtID != firstThoughtID,
          secondThoughtID != "origin" else {
        throw CheckFailure(description: "Chained whitespace thought did not commit and select")
    }
    try require(session.text(of: secondThoughtID) == "\n" &&
                session.geometry(of: secondThoughtID)?.width == 160 &&
                session.geometry(of: secondThoughtID)?.height == 96,
                "Whitespace-only adjacent thought did not commit as a 160x96 rectangle")
    _ = try CanvasDocument(data: session.encodedData())

    // Undo removes second thought and restores selection to firstThoughtID; second Undo restores baseline; Redo restores same IDs!
    view.undoMove(nil)
    try require(view.selectedNodeID == firstThoughtID && session.position(of: secondThoughtID) == nil,
                "Undo of second thought did not remove it and restore selection to its source thought")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: session.root).isEqual(to: baselineRoot) &&
                view.selectedNodeID == "origin",
                "Undo of first thought did not restore exact baseline and 'origin' selection")
    view.redoMove(nil)
    try require(view.selectedNodeID == firstThoughtID && session.text(of: firstThoughtID) == boundaryText,
                "Redo did not restore first thought with identical ID and text")
    view.redoMove(nil)
    try require(view.selectedNodeID == secondThoughtID && session.text(of: secondThoughtID) == "\n",
                "Redo did not restore second thought with identical ID")
    view.undoMove(nil)
    view.undoMove(nil)
    try require(NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "Undo after chained thoughts did not return to baseline")

    // 3. Space tap selection toggle, selection-preserving Tab traversal, Space-hold pointer pan, marquee selection, and zoom/fit.
    key(53) // Clear selection
    key(48) // Tab -> "origin"
    try require(view.selectedNodeID == "origin" && view.selectedNodeIDs == ["origin"],
                "Tab did not focus and select first node")
    // Tap Space to deselect "origin" while keeping focus on "origin"
    key(49, " ")
    keyUp(49, " ")
    try require(view.selectedNodeIDs.isEmpty && view.focusedNodeID == "origin",
                "Space tap did not deselect focused node while keeping focus")
    // Tap Space again to re-select "origin", then Tab to "tall-blocker" (selection preserved!) and tap Space to add it!
    key(49, " ")
    keyUp(49, " ")
    try require(view.selectedNodeIDs == ["origin"], "Second Space tap did not reselect 'origin'")
    key(48) // Tab -> focuses "tall-blocker" while preserving ["origin"]
    try require(view.focusedNodeID == "tall-blocker" && view.selectedNodeIDs == ["origin"],
                "Tab after Space selection did not preserve existing selection")
    key(49, " ")
    keyUp(49, " ")
    try require(view.selectedNodeIDs == ["origin", "tall-blocker"],
                "Space tap on second traversed node did not add to multi-selection")
    // While focused on "tall-blocker" in spaceSelectionMode, N grows from focused node "tall-blocker"!
    try require(view.canInsertAdjacentThought, "Focused unlocked shape in multi-selection should allow N")
    key(45, "n")
    key(53) // Cancel chooser

    // Space hold + pointer drag pans viewport without changing selection, session, or history.
    let beforePanOrigin = view.visibleWorldRect.origin
    key(49, " ") // Hold Space
    mouse(.leftMouseDown, world: CGPoint(x: 200, y: 200))
    mouse(.leftMouseDragged, world: CGPoint(x: 120, y: 150))
    mouse(.leftMouseUp, world: CGPoint(x: 120, y: 150))
    keyUp(49, " ")
    let afterPanOrigin = view.visibleWorldRect.origin
    try require(abs((afterPanOrigin.x - beforePanOrigin.x) - 80) < 1.0 &&
                abs((afterPanOrigin.y - beforePanOrigin.y) - 50) < 1.0 &&
                view.selectedNodeIDs == ["origin", "tall-blocker"] &&
                NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "Space-drag pan did not shift visibleWorldRect by (80, 50) while preserving selection and session")

    // Marquee selection on empty canvas + multi-node arrow move as one undoable transaction.
    mouse(.leftMouseDown, world: CGPoint(x: 50, y: 50))
    mouse(.leftMouseDragged, world: CGPoint(x: 480, y: 360))
    mouse(.leftMouseUp, world: CGPoint(x: 480, y: 360))
    try require(view.selectedNodeIDs == ["origin", "tall-blocker", "locked-shape"] &&
                !view.selectedNodeIDs.contains("free-line"),
                "Marquee selection did not select the enclosed nodes")
    key(124, modifiers: [.shift]) // Shift-Right moves both unlocked selected nodes by +10
    try require(session.position(of: "origin") == CanvasPosition(x: 110, y: 100) &&
                session.position(of: "tall-blocker") == CanvasPosition(x: 318, y: 250) &&
                session.position(of: "locked-shape") == CanvasPosition(x: 100, y: 320),
                "Multi-selection Shift-Right did not move all unlocked selected nodes together")
    view.undoMove(nil)
    try require(NSDictionary(dictionary: session.root).isEqual(to: baselineRoot),
                "Single Undo did not restore multi-node movement")

    // Select All (⌘A) + Escape deselection.
    key(0, "a", modifiers: [.command])
    try require(view.selectedNodeIDs.count == initialNodes.count, "⌘A did not select all nodes")
    key(53)
    try require(view.selectedNodeIDs.isEmpty && view.selectedNodeID == nil, "Escape did not clear ⌘A selection")

    // Zoom In (+), Zoom Out (-), Zoom to Fit (⇧1), and Reset Zoom (⇧0 / ⌘0) preserve session & round-trip coordinates.
    try require(abs(view.zoomScale - 1.0) < 0.0001, "Initial zoomScale was not 1.0")
    key(24, "+")
    try require(abs(view.zoomScale - 1.25) < 0.0001, "+ shortcut did not zoom in to 1.25x")
    let testWorld = CGPoint(x: 180, y: 148)
    let zoomedViewPt = view.viewPoint(forWorldPoint: testWorld)
    mouse(.leftMouseDown, world: testWorld)
    mouse(.leftMouseUp, world: testWorld)
    try require(view.selectedNodeID == "origin" && zoomedViewPt.x != testWorld.x - view.visibleWorldRect.minX,
                "Hit-testing failed at zoomed scale")
    key(18, "!", modifiers: [.shift]) // Shift-1: Zoom to Fit
    try require(view.zoomScale != 1.25, "Shift-1 did not adjust zoom to fit content")
    key(29, ")", modifiers: [.shift]) // Shift-0: Reset Zoom to 100%
    try require(abs(view.zoomScale - 1.0) < 0.0001 &&
                NSDictionary(dictionary: session.root).isEqual(to: baselineRoot) &&
                session.document.originalData == sourceBytes,
                "Zoom/Fit commands did not reset to 1.0 or mutated session/source bytes")

    print("PASS adjacent thoughts (N chooser/draft, rotated ray blockers, live growth, 2000-grapheme guard, chained N, Undo/Redo) and viewport/selection controls (Space tap/pan, marquee, ⌘A, zoom/fit)")
}
