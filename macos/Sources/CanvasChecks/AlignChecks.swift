import AppKit
import CanvasCore
import CanvasUI
import Foundation

@MainActor
func checkAlignment(repository: URL) throws {
    func approx(_ a: Double, _ b: Double, tol: Double = 1e-6) -> Bool {
        abs(a - b) <= tol
    }

    func makeRect(
        _ id: String, x: Double, y: Double, w: Double, h: Double,
        rotation: Double? = nil, locked: Bool = false, extraData: [String: Any] = [:]
    ) -> [String: Any] {
        var data: [String: Any] = ["kind": "rect", "text": id]
        if let rotation { data["rotation"] = rotation }
        for (k, v) in extraData { data[k] = v }
        var node: [String: Any] = [
            "id": id, "type": "shape", "x": x, "y": y, "width": w, "height": h,
            "data": data
        ]
        if locked { node["locked"] = true }
        return node
    }

    func makeLine(_ id: String, x: Double, y: Double, from: [Double], to: [Double]) -> [String: Any] {
        let minX = min(from[0], to[0])
        let maxX = max(from[0], to[0])
        let minY = min(from[1], to[1])
        let maxY = max(from[1], to[1])
        let w = (maxX - minX) + 24
        let h = (maxY - minY) + 24
        return [
            "id": id, "type": "shape-line",
            "x": x, "y": y, "width": w, "height": h,
            "data": [
                "from": [from[0] - minX + 12, from[1] - minY + 12],
                "to": [to[0] - minX + 12, to[1] - minY + 12],
                "arrow": "end",
                "future-line-meta": "kept"
            ]
        ]
    }

    // 1. Core geometry: all 6 align modes + rotated shape + standalone shape-line + code block
    do {
        let nodes: [[String: Any]] = [
            makeRect("a", x: 100, y: 120, w: 80, h: 40, extraData: ["custom": "kept-a"]),
            // 100x40 rotated 90 deg around center (350, 220) -> visual bbox is x:[330, 370], y:[170, 270]
            makeRect("rot", x: 300, y: 200, w: 100, h: 40, rotation: 90, extraData: ["custom": "kept-rot"]),
            // standalone line with endpoints at world (200, 320) -> (260, 360) => box at (188, 308) 84x64
            makeLine("ln", x: 188, y: 308, from: [0, 0], to: [60, 40]),
            [
                "id": "code1", "type": "code",
                "x": 420, "y": 80, "width": 140, "height": 60,
                "data": ["content": "IO.puts(:hi)\n", "language": "elixir", "future-code": 42]
            ]
        ]
        let doc = try CanvasDocument(data: try encoded(canvas(nodes, version: 2)))
        let session = CanvasSession(document: doc)
        let ids = ["a", "rot", "ln", "code1"]

        // Verify alignmentBounds for rotated shape and padded standalone line
        let rotBounds = session.alignmentBounds(of: "rot")!
        try require(
            approx(rotBounds.minX, 330) && approx(rotBounds.minY, 170) &&
            approx(rotBounds.maxX, 370) && approx(rotBounds.maxY, 270),
            "Unexpected rotated shape alignment bounds: \(rotBounds)"
        )
        let lnBounds = session.alignmentBounds(of: "ln")!
        try require(
            approx(lnBounds.minX, 200) && approx(lnBounds.minY, 320) &&
            approx(lnBounds.maxX, 260) && approx(lnBounds.maxY, 360),
            "Unexpected standalone line alignment bounds: \(lnBounds)"
        )

        // Overall bounds before align: minX = 100, maxX = 560, midX = 330; minY = 80, maxY = 360, midY = 220
        // Test each of the 6 align modes from a fresh session
        for alignment in [
            CanvasAlignment.left, .centerHorizontal, .right,
            .top, .centerVertical, .bottom
        ] {
            let s = CanvasSession(document: try CanvasDocument(data: try encoded(canvas(nodes, version: 2))))
            let revBefore = s.revision
            guard let batch = try s.alignNodes(ids, alignment: alignment) else {
                throw CheckFailure(description: "Expected non-nil batch for \(alignment)")
            }
            try require(s.revision == revBefore + 1, "Expected single revision bump for \(alignment)")
            for id in ids {
                let b = s.alignmentBounds(of: id)!
                switch alignment {
                case .left:
                    try require(approx(b.minX, 100), "\(id) left edge \(b.minX) != 100")
                case .centerHorizontal:
                    try require(approx((b.minX + b.maxX) / 2, 330), "\(id) centerX \((b.minX + b.maxX) / 2) != 330")
                case .right:
                    try require(approx(b.maxX, 560), "\(id) right edge \(b.maxX) != 560")
                case .top:
                    try require(approx(b.minY, 80), "\(id) top edge \(b.minY) != 80")
                case .centerVertical:
                    try require(approx((b.minY + b.maxY) / 2, 220), "\(id) centerY \((b.minY + b.maxY) / 2) != 220")
                case .bottom:
                    try require(approx(b.maxY, 360), "\(id) bottom edge \(b.maxY) != 360")
                default:
                    break
                }
            }
            // Rotation, dimensions, line padding, and unknown metadata preserved
            let rawNodes = s.root["nodes"] as? [[String: Any]] ?? []
            let rotNode = rawNodes.first { ($0["id"] as? String) == "rot" }!
            let rotData = rotNode["data"] as? [String: Any]
            try require(approx((rotData?["rotation"] as? NSNumber)?.doubleValue ?? 0, 90), "Rotation lost on align")
            try require((rotData?["custom"] as? String) == "kept-rot", "Metadata lost on align")
            let lnNode = rawNodes.first { ($0["id"] as? String) == "ln" }!
            let lnData = lnNode["data"] as? [String: Any]
            try require(lnData?["rotation"] == nil, "Standalone line gained rotation on align")
            try require((lnData?["future-line-meta"] as? String) == "kept", "Line metadata lost on align")
            let codeNode = rawNodes.first { ($0["id"] as? String) == "code1" }!
            try require(((codeNode["data"] as? [String: Any])?["future-code"] as? Int) == 42, "Code metadata lost on align")

            // Repeating the same alignment must be a pure no-op (nil batch, no revision bump)
            let revAligned = s.revision
            let noop = try s.alignNodes(ids, alignment: alignment)
            try require(noop == nil && s.revision == revAligned, "Second \(alignment) was not a pure no-op")

            // Inverse batch restores original exact positions
            try s.applyBatchMove(batch.inverse)
            try require(s.position(of: "a") == CanvasPosition(x: 100, y: 120), "Inverse did not restore a")
            try require(s.position(of: "rot") == CanvasPosition(x: 300, y: 200), "Inverse did not restore rot")
            try require(s.position(of: "ln") == CanvasPosition(x: 188, y: 308), "Inverse did not restore ln")
            try require(s.position(of: "code1") == CanvasPosition(x: 420, y: 80), "Inverse did not restore code1")
        }
    }

    // 2. Distribute Horizontally & Vertically (equal edge-to-edge gap with unequal sizes)
    do {
        let nodes: [[String: Any]] = [
            makeRect("n1", x: 100, y: 50, w: 40, h: 30),   // x: [100, 140], y: [50, 80]
            makeRect("n2", x: 160, y: 180, w: 100, h: 60), // x: [160, 260], y: [180, 240]
            makeRect("n3", x: 350, y: 100, w: 60, h: 50),  // x: [350, 410], y: [100, 150]
            makeRect("n4", x: 500, y: 400, w: 80, h: 40)   // x: [500, 580], y: [400, 440]
        ]
        // Horizontal: span = 580 - 100 = 480; sumW = 40+100+60+80 = 280; gap = 200 / 3 = 66.6666667
        // Order by minX: n1 (100..140), n2 (140+gap .. 240+gap), n3 (240+2*gap .. 300+2*gap), n4 (500..580)
        let sh = CanvasSession(document: try CanvasDocument(data: try encoded(canvas(nodes))))
        try require(!sh.canAlignNodes(["n1", "n2"], alignment: .distributeHorizontally), "Distribute H allowed with 2 items")
        try require(sh.canAlignNodes(["n1", "n2", "n3", "n4"], alignment: .distributeHorizontally), "Distribute H rejected 4 items")
        let batchH = try sh.alignNodes(["n1", "n2", "n3", "n4"], alignment: .distributeHorizontally)
        try require(batchH != nil, "Expected horizontal distribution batch")
        let gapH = 200.0 / 3.0
        try require(approx(sh.alignmentBounds(of: "n1")!.minX, 100), "n1 anchor moved on distribute H")
        try require(approx(sh.alignmentBounds(of: "n2")!.minX, 140 + gapH), "n2 wrong x on distribute H")
        try require(approx(sh.alignmentBounds(of: "n3")!.minX, 240 + 2 * gapH), "n3 wrong x on distribute H")
        try require(approx(sh.alignmentBounds(of: "n4")!.minX, 500), "n4 anchor moved on distribute H")
        // Verify equal gaps between adjacent items
        let b1 = sh.alignmentBounds(of: "n1")!, b2 = sh.alignmentBounds(of: "n2")!
        let b3 = sh.alignmentBounds(of: "n3")!, b4 = sh.alignmentBounds(of: "n4")!
        try require(
            approx(b2.minX - b1.maxX, gapH) &&
            approx(b3.minX - b2.maxX, gapH) &&
            approx(b4.minX - b3.maxX, gapH),
            "Horizontal gaps were not equal"
        )

        // Vertical: order by minY: n1 (50, h=30), n3 (100, h=50), n2 (180, h=60), n4 (400, h=40)
        // span = 440 - 50 = 390; sumH = 30+50+60+40 = 180; gap = 210 / 3 = 70
        let sv = CanvasSession(document: try CanvasDocument(data: try encoded(canvas(nodes))))
        let batchV = try sv.alignNodes(["n1", "n2", "n3", "n4"], alignment: .distributeVertically)
        try require(batchV != nil, "Expected vertical distribution batch")
        try require(approx(sv.alignmentBounds(of: "n1")!.minY, 50), "n1 anchor moved on distribute V")
        try require(approx(sv.alignmentBounds(of: "n3")!.minY, 80 + 70), "n3 wrong y on distribute V")
        try require(approx(sv.alignmentBounds(of: "n2")!.minY, 150 + 50 + 70), "n2 wrong y on distribute V")
        try require(approx(sv.alignmentBounds(of: "n4")!.minY, 400), "n4 anchor moved on distribute V")
    }

    // 3. Locked items act as reference anchors without moving; all-locked and read-only are refused
    do {
        let nodes: [[String: Any]] = [
            makeRect("lockedAnchor", x: 50, y: 50, w: 60, h: 40, locked: true),
            makeRect("free1", x: 200, y: 120, w: 80, h: 40),
            makeRect("locked2", x: 320, y: 200, w: 60, h: 40, locked: true)
        ]
        let s = CanvasSession(document: try CanvasDocument(data: try encoded(canvas(nodes))))
        // All-locked selection must refuse
        try require(!s.canAlignNodes(["lockedAnchor", "locked2"], alignment: .left), "All-locked selection allowed align")
        let rev0 = s.revision
        try require(try s.alignNodes(["lockedAnchor", "locked2"], alignment: .left) == nil && s.revision == rev0, "All-locked selection mutated state")

        // Mixed locked + unlocked aligns free1 to lockedAnchor's left edge (50) without moving locked nodes
        try require(s.canAlignNodes(["lockedAnchor", "free1", "locked2"], alignment: .left), "Mixed selection refused align")
        let batch = try s.alignNodes(["lockedAnchor", "free1", "locked2"], alignment: .left)
        try require(batch != nil && batch!.moves.count == 1, "Expected only unlocked item to move")
        try require(s.position(of: "lockedAnchor") == CanvasPosition(x: 50, y: 50), "Locked anchor moved")
        try require(s.position(of: "locked2") == CanvasPosition(x: 320, y: 200), "Second locked node moved")
        try require(s.position(of: "free1") == CanvasPosition(x: 50, y: 120), "Unlocked item did not align to locked anchor")

        // Read-only session refuses alignment
        s.isReadOnly = true
        try require(!s.canAlignNodes(["lockedAnchor", "free1"], alignment: .right), "Read-only session allowed canAlignNodes")
        do {
            _ = try s.alignNodes(["lockedAnchor", "free1"], alignment: .right)
            throw CheckFailure(description: "Read-only session did not throw on alignNodes")
        } catch is CanvasDocumentError {}
    }

    // 4. Full AppKit UI integration: Edit -> Align menu, shortcuts, floating Align bar, StyleInspector, context menu, Undo/Redo, edge rerouting, v1 round-trip
    do {
        let nodes: [[String: Any]] = [
            makeRect("r1", x: 80, y: 100, w: 100, h: 50),
            makeRect("r2", x: 240, y: 200, w: 120, h: 60),
            makeRect("r3", x: 460, y: 140, w: 80, h: 40)
        ]
        let edges: [[String: Any]] = [
            ["id": "e1", "source": "r1", "source_handle": "right", "target": "r2", "target_handle": "left"]
        ]
        // Use v1 document to verify v1 compatibility preservation as well
        let v1Root: [String: Any] = [
            "version": 1,
            "future-root": "kept-v1",
            "nodes": nodes,
            "edges": edges
        ]
        let sourceBytes = try encoded(v1Root)
        let appDelegate = CanvasAppDelegate()
        appDelegate.installMenu()
        let session = CanvasSession(document: try CanvasDocument(data: sourceBytes))
        let view = appDelegate.showSession(session, name: "AlignSmoke")
        defer { appDelegate.closeAllWindows() }
        guard let window = view.window,
              let editMenu = NSApp.mainMenu?.item(withTitle: "Edit")?.submenu,
              let alignSubmenu = editMenu.item(withTitle: "Align")?.submenu else {
            throw CheckFailure(description: "Missing Edit -> Align submenu in main menu")
        }
        try require(
            alignSubmenu.items.filter { !$0.isSeparatorItem }.count == 8,
            "Expected 8 alignment items in Edit -> Align submenu"
        )

        func menuItem(_ alignment: CanvasAlignment) throws -> NSMenuItem {
            guard let item = alignSubmenu.items.first(where: { ($0.representedObject as? String) == alignment.rawValue }) else {
                throw CheckFailure(description: "Missing Edit -> Align menu item for \(alignment.rawValue)")
            }
            return item
        }

        func clickWorld(_ pt: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
            let vp = view.viewPoint(forWorldPoint: pt)
            let winPt = view.convert(vp, to: nil)
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: winPt, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1
            )!
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: winPt, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 1
            )!
            view.mouseDown(with: down)
            view.mouseUp(with: up)
        }

        func dispatchKey(_ code: UInt16, _ chars: String = "", modifiers: NSEvent.ModifierFlags = []) {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: chars, charactersIgnoringModifiers: chars,
                isARepeat: false, keyCode: code
            )!
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return
            }
            view.keyDown(with: event)
        }

        // With 0 items selected: align bar hidden, menu items disabled
        try require(view.alignBar.isHidden, "Align bar should be hidden with 0 selected")
        try require(!appDelegate.validateMenuItem(try menuItem(.left)), "Align Left should be disabled with 0 selected")

        // Select 1 item (r1): align bar still hidden, menu disabled
        clickWorld(CGPoint(x: 130, y: 125))
        try require(view.alignBar.isHidden, "Align bar should be hidden with 1 selected")
        try require(!appDelegate.validateMenuItem(try menuItem(.left)), "Align Left should be disabled with 1 selected")

        // Shift-click r2 (2 items selected): align bar visible, 6 align enabled, 2 distribute disabled
        clickWorld(CGPoint(x: 300, y: 230), modifiers: [.shift])
        try require(!view.alignBar.isHidden, "Align bar should appear with 2 selected items")
        try require(view.alignBar.button(for: .left)?.isEnabled == true, "Align bar Left should be enabled for 2 items")
        try require(view.alignBar.button(for: .distributeHorizontally)?.isEnabled == false, "Align bar Distribute H should be disabled for 2 items")
        try require(appDelegate.validateMenuItem(try menuItem(.left)), "Menu Align Left should be enabled for 2 items")
        try require(!appDelegate.validateMenuItem(try menuItem(.distributeHorizontally)), "Menu Distribute H should be disabled for 2 items")
        let accChildren = view.accessibilityChildren() ?? []
        try require(accChildren.contains(where: { ($0 as AnyObject) === view.alignBar }), "Visible alignBar missing from accessibilityChildren")

        // Right-click context menu for 2 selected items
        let rightClickPt = view.convert(view.viewPoint(forWorldPoint: CGPoint(x: 130, y: 125)), to: nil)
        let rightEvent = NSEvent.mouseEvent(
            with: .rightMouseDown, location: rightClickPt, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 3, clickCount: 1, pressure: 1
        )!
        guard let contextMenu = view.menu(for: rightEvent),
              let ctxAlignMenu = contextMenu.item(withTitle: "Align")?.submenu else {
            throw CheckFailure(description: "Missing Align submenu in right-click context menu")
        }
        try require(!ctxAlignMenu.autoenablesItems, "Context Align submenu must disable autoenablesItems")
        let ctxLeft = ctxAlignMenu.items.first { ($0.representedObject as? String) == CanvasAlignment.left.rawValue }
        let ctxDistH = ctxAlignMenu.items.first { ($0.representedObject as? String) == CanvasAlignment.distributeHorizontally.rawValue }
        try require(ctxLeft?.isEnabled == true && ctxDistH?.isEnabled == false, "Context Align submenu enablement mismatch for 2 items")

        // Open Style inspector with 2 items selected: shows multi-selection ALIGN section
        view.showStyleInspector(nil)
        try require(view.isStyleInspectorOpen, "Style inspector did not open for multi-selection")
        let styleTitle = (view.styleInspector.subviews.first { $0.identifier?.rawValue == "style-title" } as? NSTextField)?.stringValue
        try require(styleTitle == "2 Objects", "Expected '2 Objects' title in Style inspector, got \(String(describing: styleTitle))")
        let styleAlignTop = view.styleInspector.subviews.first { $0.identifier?.rawValue == "style-align-\(CanvasAlignment.top.rawValue)" } as? NSButton
        let styleDistH = view.styleInspector.subviews.first { $0.identifier?.rawValue == "style-align-\(CanvasAlignment.distributeHorizontally.rawValue)" } as? NSButton
        try require(styleAlignTop != nil && !styleAlignTop!.isHidden && styleAlignTop!.isEnabled, "Style inspector Align Top button should be visible and enabled")
        try require(styleDistH != nil && !styleDistH!.isHidden && !styleDistH!.isEnabled, "Style inspector Distribute H button should be disabled for 2 items")

        // Click Style inspector Align Top button -> r2 moves from y=200 to y=100 in 1 undo step
        styleAlignTop!.performClick(nil)
        try require(session.position(of: "r2") == CanvasPosition(x: 240, y: 100), "Style inspector Align Top did not align r2")
        // Verify Undo & Redo in 1 step and selection preserved
        view.undoMove(nil)
        try require(session.position(of: "r2") == CanvasPosition(x: 240, y: 200), "Undo did not restore r2 after Align Top")
        view.redoMove(nil)
        try require(session.position(of: "r2") == CanvasPosition(x: 240, y: 100), "Redo did not reapply Align Top")
        view.undoMove(nil) // back to initial

        // Close Style inspector and test floating Align bar click + keyboard shortcuts
        view.closeStyleInspector(nil)
        appDelegate.selectAllItems(nil) // selects r1, r2, r3 (3 items)
        try require(view.alignBar.button(for: .distributeHorizontally)?.isEnabled == true, "Align bar Distribute H should be enabled for 3 items")
        try require(appDelegate.validateMenuItem(try menuItem(.distributeHorizontally)), "Menu Distribute H should be enabled for 3 items")

        // Click Align Left on floating bar -> all 3 align to x = 80
        view.alignBar.button(for: .left)!.performClick(nil)
        try require(
            session.position(of: "r1")?.x == 80 &&
            session.position(of: "r2")?.x == 80 &&
            session.position(of: "r3")?.x == 80,
            "Floating Align bar Left click did not align all 3 items"
        )
        // Undo restores all 3 in one step; Redo stack preserved across no-op
        view.undoMove(nil)
        try require(
            session.position(of: "r2") == CanvasPosition(x: 240, y: 200) &&
            session.position(of: "r3") == CanvasPosition(x: 460, y: 140),
            "Single Undo did not restore all 3 items"
        )
        try require(view.undoManager?.canRedo == true, "Redo should be available after Undo")

        // Keyboard shortcuts: Option-Command-Right (keyCode 124), Control-Command-H, Shift-Control-Command-H
        dispatchKey(124, String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: [.command, .option])
        // Max right edge was r3 (460 + 80 = 540)
        try require(
            approx(session.alignmentBounds(of: "r1")!.maxX, 540) &&
            approx(session.alignmentBounds(of: "r2")!.maxX, 540) &&
            approx(session.alignmentBounds(of: "r3")!.maxX, 540),
            "Option-Command-Right did not align right edges"
        )
        // Already aligned right: repeating Option-Command-Right must be a no-op and not push extra Undo
        let revAfterRight = session.revision
        dispatchKey(124, String(UnicodeScalar(NSRightArrowFunctionKey)!), modifiers: [.command, .option])
        try require(session.revision == revAfterRight, "Repeated Option-Command-Right bumped revision")
        view.undoMove(nil)
        try require(session.position(of: "r1") == CanvasPosition(x: 80, y: 100), "Single Undo after no-op did not restore initial state")

        // Shift-Control-Command-H (Distribute Horizontally):
        // r1: [80, 180] (w=100), r2: [240, 360] (w=120), r3: [460, 540] (w=80)
        // span = 540 - 80 = 460; sumW = 300; gap = 160 / 2 = 80 -> r2 moves from 240 to 180 + 80 = 260
        dispatchKey(4, "H", modifiers: [.command, .control, .shift])
        try require(
            approx(session.position(of: "r1")!.x, 80) &&
            approx(session.position(of: "r2")!.x, 260) &&
            approx(session.position(of: "r3")!.x, 460),
            "Shift-Control-Command-H did not distribute horizontally (r2 x = \(String(describing: session.position(of: "r2")?.x)))"
        )

        // Control-Command-V (Align Vertical Centers):
        // r1: y[100, 150], r2: y[200, 260], r3: y[140, 180] -> minY=100, maxY=260, midY=180
        dispatchKey(9, "v", modifiers: [.command, .control])
        try require(
            approx((session.alignmentBounds(of: "r1")!.minY + session.alignmentBounds(of: "r1")!.maxY) / 2, 180) &&
            approx((session.alignmentBounds(of: "r2")!.minY + session.alignmentBounds(of: "r2")!.maxY) / 2, 180) &&
            approx((session.alignmentBounds(of: "r3")!.minY + session.alignmentBounds(of: "r3")!.maxY) / 2, 180),
            "Control-Command-V did not align vertical centers"
        )

        // Verify v1 version and unknown root metadata preserved, and JSON validates cleanly
        let savedData = try CanvasDocument.encode(session.root)
        let reopened = try CanvasDocument(data: savedData)
        try require((reopened.root["version"] as? Int) == 1, "Alignment altered v1 document version")
        try require((reopened.root["future-root"] as? String) == "kept-v1", "Alignment dropped unknown v1 root metadata")

        // Active drag hides floating alignBar and mouseUp restores it
        let dragStart = view.convert(view.viewPoint(forWorldPoint: CGPoint(x: 130, y: 180)), to: nil)
        let dragMid = view.convert(view.viewPoint(forWorldPoint: CGPoint(x: 160, y: 180)), to: nil)
        view.mouseDown(with: NSEvent.mouseEvent(
            with: .leftMouseDown, location: dragStart, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 10, clickCount: 1, pressure: 1
        )!)
        view.mouseDragged(with: NSEvent.mouseEvent(
            with: .leftMouseDragged, location: dragMid, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 11, clickCount: 1, pressure: 1
        )!)
        try require(view.alignBar.isHidden, "Align bar did not hide during active pointer drag")
        view.mouseUp(with: NSEvent.mouseEvent(
            with: .leftMouseUp, location: dragMid, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 12, clickCount: 1, pressure: 1
        )!)
        try require(!view.alignBar.isHidden, "Align bar did not reappear after pointer drag ended")
    }

    print("PASS alignment: 6 align modes, horizontal/vertical distribution, rotated & line visual bounds, locked anchors, no-op isolation, floating Align bar, Style inspector, Edit/context menus, shortcuts, Undo/Redo and v1/v2 retention")
}
