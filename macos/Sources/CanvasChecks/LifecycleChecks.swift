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

    // Open ShapeTextEditor sheet via Return, then press Delete/Backspace and ⌘D/⌘L inside the text sheet.
    dispatchAppKey(36, "\r")
    guard let sheet = appWindow.attachedSheet,
          let sheetEditor = sheet.firstResponder as? NSTextView else {
        throw CheckFailure(description: "Return did not open and focus ShapeTextEditor sheet")
    }
    for title in ["Duplicate", "Delete", "Bring to Front", "Send to Back", "Lock", "Edit Geometry"] {
        let item = try editItem(title)
        try require(!appDelegate.validateMenuItem(item),
                    "Menu item '\(title)' stayed enabled while text sheet was attached")
    }
    sheetEditor.string = "Back!"
    sheetEditor.setSelectedRange(NSRange(location: 5, length: 0))
    // Dispatch Backspace through NSApp (which checks mainMenu.performKeyEquivalent first, then sheet responder)
    dispatchAppKey(51, "\u{7f}")
    try require(sheetEditor.string == "Back" &&
                appSession.position(of: "back") != nil &&
                appWindow.attachedSheet != nil,
                "Backspace inside ShapeTextEditor deleted the canvas node or failed to delete text character")
    // Also verify CanvasAppDelegate.deleteSelection routes to NSTextView.deleteBackward when invoked while editor is firstResponder
    sheetEditor.string = "Back?"
    sheetEditor.setSelectedRange(NSRange(location: 5, length: 0))
    appDelegate.deleteSelection(nil)
    try require(sheetEditor.string == "Back" && appSession.position(of: "back") != nil,
                "CanvasAppDelegate.deleteSelection did not route to active NSTextView")
    // Cancel sheet via Escape
    dispatchAppKey(53, "\u{1b}")
    try require(appWindow.attachedSheet == nil &&
                NSDictionary(dictionary: appSession.root).isEqual(to: baselineRoot),
                "Escape did not dismiss text sheet cleanly")

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
    print("PASS AppDelegate menu validation, NSApp key-equivalent routing, text-sheet Delete isolation and G-preview guards")
    print("PASS lifecycle: connection selection/deletion, Tab traversal, node deletion with incident edges, duplicate quotas, stacking and lock/unlock")
}
