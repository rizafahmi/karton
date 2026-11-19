import AppKit
import CanvasCore
import CanvasUI
import Foundation

@MainActor
func checkPNGExport(repository: URL) throws {
    // 1. Bundled Neo-Acid + Amatic SC typography registration, role/size mapping, and CoreText glyph fallback.
    try require(
        CanvasTypography.ensureRegistered(),
        "Bundled Neo-Acid and Amatic SC fonts failed to register with CoreText"
    )
    let expectedMappings: [(String, String, String)] = [
        ("sans", "s", "MonaSansExtraLight-Regular"),
        ("sans", "m", "MonaSansExtraLight-Regular"),
        ("sans", "l", "MonaSansExtraLight-Bold"),
        ("heading", "s", "Unbounded-ExtraBold"),
        ("heading", "m", "Unbounded-ExtraBold"),
        ("heading", "l", "Unbounded-ExtraBold"),
        ("mono", "s", "MonaspaceNeon-Regular"),
        ("mono", "m", "MonaspaceNeon-Regular"),
        ("mono", "l", "MonaspaceNeon-Bold"),
        ("handwritten", "s", "AmaticSC-Bold"),
        ("handwritten", "m", "AmaticSC-Bold"),
        ("handwritten", "l", "AmaticSC-Bold"),
    ]
    for (role, size, expectedPS) in expectedMappings {
        let resolved = CanvasTypography.font(role, size)
        let actualPS = CTFontCopyPostScriptName(resolved as CTFont) as String
        try require(
            actualPS == expectedPS,
            "Role '\(role)' size '\(size)' resolved to '\(actualPS)' instead of '\(expectedPS)'"
        )
        let runs = CanvasTypography.glyphRunPostScriptNames(
            for: "Hello 日本語 👩🏽‍💻", role: role, size: size
        )
        try require(
            runs.first == expectedPS && runs.count >= 3 && runs.contains("AppleColorEmoji"),
            "Role '\(role)' size '\(size)' did not use primary face '\(expectedPS)' with CJK/emoji cascade fallback (got \(runs))"
        )
    }

    // 2. Empty canvas refusal and dimension/cap validation before bitmap allocation.
    let blankDoc = try CanvasDocument.blank()
    let blankSession = CanvasSession(document: blankDoc)
    let blankView = CanvasView(session: blankSession)
    try require(!blankView.canExportPNG, "Blank canvas should not report canExportPNG")
    do {
        _ = try blankView.exportPNGData()
        throw CheckFailure(description: "Exported PNG from an empty canvas")
    } catch let error as CanvasDocumentError {
        try require(
            error.localizedDescription.localizedCaseInsensitiveContains("empty"),
            "Unexpected empty-canvas error: \(error.localizedDescription)"
        )
    }

    let sampleBounds = CGRect(x: 100, y: 100, width: 336, height: 136) // +64 padding -> 400 x 200 (2:1)
    let defaultPlan = try CanvasPNGExportPlan.resolve(contentWorldBounds: sampleBounds)
    try require(
        defaultPlan.pixelWidth == 2_048 && defaultPlan.pixelHeight == 1_024
            && defaultPlan.paddedWorldBounds == CGRect(x: 68, y: 68, width: 400, height: 200),
        "Default PNG export plan did not resolve 2048x1024 with 32-unit padding (got \(defaultPlan.pixelWidth)x\(defaultPlan.pixelHeight))"
    )
    // Boundary acceptance: 8192x2048 = 16,777,216 pixels (exact per-side and total cap)
    let maxSidePlan = try CanvasPNGExportPlan.resolve(
        contentWorldBounds: CGRect(x: 0, y: 0, width: 736, height: 136), // padded: 800 x 200 (4:1)
        sizing: .longestSide(8_192)
    )
    try require(
        maxSidePlan.pixelWidth == 8_192 && maxSidePlan.pixelHeight == 2_048,
        "Max 8192x2048 boundary plan failed"
    )
    let maxSquarePlan = try CanvasPNGExportPlan.resolve(
        contentWorldBounds: sampleBounds,
        sizing: .exact(width: 4_096, height: 4_096)
    )
    try require(
        maxSquarePlan.pixelWidth == 4_096 && maxSquarePlan.pixelHeight == 4_096
            && maxSquarePlan.offsetX == 0 && maxSquarePlan.offsetY == 1_024,
        "Exact 4096x4096 letterboxed plan did not center 2:1 content with 1024px vertical letterbox"
    )

    let invalidSizings: [(CGRect, CanvasPNGExportSizing, Double, String)] = [
        (sampleBounds, .longestSide(0), 32, "at least 1"),
        (sampleBounds, .longestSide(-50), 32, "at least 1"),
        (sampleBounds, .longestSide(8_193), 32, "8192"),
        // Square bounds with 8192 longest side -> 8192x8192 = 67,108,864 > 16,777,216 total cap
        (CGRect(x: 0, y: 0, width: 100, height: 100), .longestSide(8_192), 32, "16777216"),
        (sampleBounds, .exact(width: 0, height: 500), 32, "at least 1"),
        (sampleBounds, .exact(width: 500, height: -1), 32, "at least 1"),
        (sampleBounds, .exact(width: 8_193, height: 100), 32, "8192"),
        (sampleBounds, .exact(width: 4_097, height: 4_096), 32, "16777216"),
        (sampleBounds, .longestSide(512), -1, "padding"),
        (sampleBounds, .longestSide(512), .nan, "padding"),
    ]
    for (bounds, sizing, pad, expectedFragment) in invalidSizings {
        do {
            _ = try CanvasPNGExportPlan.resolve(contentWorldBounds: bounds, sizing: sizing, padding: pad)
            throw CheckFailure(description: "Accepted invalid PNG sizing \(sizing) padding \(pad)")
        } catch let error as CanvasDocumentError {
            try require(
                error.localizedDescription.localizedCaseInsensitiveContains(expectedFragment),
                "Expected '\(expectedFragment)' in refusal for \(sizing), got: \(error.localizedDescription)"
            )
        }
    }

    // 3. Full-diagram export: rotated shapes, dark/light fills, standalone line/arrow, self-loop, labels,
    //    true alpha without paper/grid/selection/chrome, zoom/DPR invariance, and Keynote slide compositing.
    let diagramRoot: [String: Any] = [
        "version": 2,
        "paper": ["background": "lines", "grid": 20],
        "appearance": ["font": "sans"],
        "nodes": [
            [
                "id": "rect-dark", "type": "shape", "x": 100, "y": 120, "width": 180, "height": 100,
                "data": [
                    "kind": "rect", "fill": "ink", "stroke": "ink", "width": 2, "radius": 8,
                    "font": "heading", "size": "m", "text": "Keynote Ready",
                ],
            ],
            [
                "id": "tri-rot", "type": "shape", "x": 380, "y": 110, "width": 160, "height": 120,
                "data": [
                    "kind": "triangle", "fill": "yellow", "stroke": "ink", "width": 4,
                    "rotation": 35, "font": "handwritten", "size": "l", "text": "Idea 日本語",
                ],
            ],
            [
                "id": "code-box", "type": "code", "x": 100, "y": 300, "width": 220, "height": 90,
                "data": ["content": "mix canvas.doctor\n:ok", "language": "elixir", "fill": "surface", "stroke": "ink"],
            ],
            [
                "id": "free-arrow", "type": "shape-line", "x": 380, "y": 310, "width": 180, "height": 50,
                "data": ["from": [12, 12], "to": [168, 38], "stroke": "red", "width": 4, "arrow": "both"],
            ],
        ],
        "edges": [
            [
                "id": "edge-main", "source": "rect-dark", "source_handle": "right",
                "target": "tri-rot", "target_handle": "left", "path": "bezier",
                "marker": "arrow", "label": "Connects",
                "data": ["connector_style": ["stroke": "violet", "width": 4, "dash": false]],
            ],
            [
                "id": "edge-loop", "source": "rect-dark", "source_handle": "top",
                "target": "rect-dark", "target_handle": "left", "path": "bezier",
                "marker": "dot", "label": "Self Loop",
                "data": ["connector_style": ["stroke": "green", "width": 2, "dash": true]],
            ],
        ],
    ]
    let diagramBytes = try encoded(diagramRoot)
    let diagramDoc = try CanvasDocument(data: diagramBytes)
    let diagramSession = CanvasSession(document: diagramDoc)
    let appDelegate = CanvasAppDelegate()
    appDelegate.installMenu()
    let view = appDelegate.showSession(diagramSession, name: "ExportDiagram")
    defer { appDelegate.closeAllWindows() }
    guard let window = view.window else {
        throw CheckFailure(description: "Missing window for ExportDiagram")
    }

    // Create an undo + redo history state to verify export never clears or splits undo/redo.
    view.keyDown(with: NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48
    )!)
    view.keyDown(with: NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124
    )!)
    view.undoMove(nil)
    try require(
        view.undoManager?.canRedo == true && NSDictionary(dictionary: diagramSession.root).isEqual(to: diagramRoot),
        "Expected clean baseline with active redo before PNG export"
    )

    // Verify contentWorldBounds includes self-loop exterior route (above y=120 and left of x=100) and rotated triangle corners.
    let worldBounds = view.contentWorldBounds()
    try require(
        worldBounds.minX < 100 && worldBounds.minY < 120 && worldBounds.maxX > 540 && worldBounds.maxY > 390,
        "contentWorldBounds (\(worldBounds)) did not include self-loop exterior route and rotated triangle bounds"
    )

    // Export at default 2,048px longest side at zoom 1.0 with no selection.
    view.deselectAll()
    let pngDataZoom1 = try view.exportPNGData()
    guard let repZoom1 = NSBitmapImageRep(data: pngDataZoom1) else {
        throw CheckFailure(description: "Could not decode exported PNG data")
    }
    let plan = try view.exportPNGPlan()
    try require(
        repZoom1.pixelsWide == plan.pixelWidth && repZoom1.pixelsHigh == plan.pixelHeight
            && max(repZoom1.pixelsWide, repZoom1.pixelsHigh) == 2_048,
        "Exported PNG dimensions (\(repZoom1.pixelsWide)x\(repZoom1.pixelsHigh)) did not match 2,048px longest-side plan (\(plan.pixelWidth)x\(plan.pixelHeight))"
    )

    // Select an edge ("edge-main"), open Style inspector, zoom to 0.4x, pan viewport, and export entire canvas.
    // Then zoom to 2.5x, select all nodes, and export with default automatic scope.
    // All three PNG exports must be pixel-identical (zoom/pan/selection-chrome/inspector invariant).
    let edgeMidPt = view.viewPoint(forWorldPoint: CGPoint(x: 330, y: 170))
    view.mouseDown(with: NSEvent.mouseEvent(
        with: .leftMouseDown, location: view.convert(edgeMidPt, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1
    )!)
    view.mouseUp(with: NSEvent.mouseEvent(
        with: .leftMouseUp, location: view.convert(edgeMidPt, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1
    )!)
    view.showStyleInspector(nil)
    view.setZoom(0.4)
    view.setVisibleWorldOrigin(CGPoint(x: -400, y: -300))
    let pngDataZoom04 = try view.exportPNGData(scope: .entireCanvas)

    view.setZoom(2.5)
    view.selectAll(nil)
    let pngDataZoom25 = try view.exportPNGData()

    try require(
        pngDataZoom1 == pngDataZoom04 && pngDataZoom1 == pngDataZoom25,
        "PNG export output changed across viewport zoom, scroll origin, selection, or open Style inspector"
    )
    view.deselectAll()
    view.closeStyleInspector(nil)
    view.resetZoom(nil)

    // Verify true alpha in padding corners and along the outer 1-pixel perimeter (unclipped content).
    for (px, py) in [
        (0, 0), (repZoom1.pixelsWide - 1, 0),
        (0, repZoom1.pixelsHigh - 1), (repZoom1.pixelsWide - 1, repZoom1.pixelsHigh - 1),
        (8, 8), (repZoom1.pixelsWide - 9, repZoom1.pixelsHigh - 9),
    ] {
        let c = repZoom1.colorAt(x: px, y: py)!
        try require(
            c.alphaComponent == 0,
            "Padding pixel (\(px), \(py)) was not transparent (alpha=\(c.alphaComponent)) — paper/grid leaked into PNG"
        )
    }
    for x in 0..<repZoom1.pixelsWide {
        try require(
            repZoom1.colorAt(x: x, y: 0)!.alphaComponent == 0
                && repZoom1.colorAt(x: x, y: repZoom1.pixelsHigh - 1)!.alphaComponent == 0,
            "Content clipped against top/bottom PNG edge at x=\(x)"
        )
    }
    for y in 0..<repZoom1.pixelsHigh {
        try require(
            repZoom1.colorAt(x: 0, y: y)!.alphaComponent == 0
                && repZoom1.colorAt(x: repZoom1.pixelsWide - 1, y: y)!.alphaComponent == 0,
            "Content clipped against left/right PNG edge at y=\(y)"
        )
    }

    // Helper to map world point to exported pixel coordinates.
    func exportPixel(for world: CGPoint, in exportPlan: CanvasPNGExportPlan) -> (Int, Int) {
        let px = Int(round(exportPlan.offsetX + (world.x - exportPlan.paddedWorldBounds.minX) * exportPlan.scale))
        let py = Int(round(exportPlan.offsetY + (world.y - exportPlan.paddedWorldBounds.minY) * exportPlan.scale))
        return (px, py)
    }

    // Verify empty space between nodes has alpha == 0 (no paper lines/dots), while shape fills and strokes are opaque.
    let (emptyX, emptyY) = exportPixel(for: CGPoint(x: 340, y: 260), in: plan)
    try require(
        repZoom1.colorAt(x: emptyX, y: emptyY)!.alphaComponent == 0,
        "Interior gap between nodes had non-zero alpha — grid lines leaked into export"
    )
    let (darkRectX, darkRectY) = exportPixel(for: CGPoint(x: 115, y: 135), in: plan)
    let darkRectColor = repZoom1.colorAt(x: darkRectX, y: darkRectY)!.usingColorSpace(.sRGB)!
    try require(
        darkRectColor.alphaComponent > 0.99 && darkRectColor.redComponent < 0.1,
        "Ink-filled rectangle corner did not render opaque Ebony Ink in PNG"
    )
    // Verify white text on dark `ink` fill rendered inside rect-dark.
    let (darkTextMinX, darkTextMinY) = exportPixel(for: CGPoint(x: 120, y: 145), in: plan)
    let (darkTextMaxX, darkTextMaxY) = exportPixel(for: CGPoint(x: 260, y: 195), in: plan)
    var foundWhiteTextGlyph = false
    for py in darkTextMinY...darkTextMaxY {
        for px in darkTextMinX...darkTextMaxX {
            if let c = repZoom1.colorAt(x: px, y: py)?.usingColorSpace(.sRGB),
               c.alphaComponent > 0.9 && c.redComponent > 0.85 && c.greenComponent > 0.85 && c.blueComponent > 0.85 {
                foundWhiteTextGlyph = true
                break
            }
        }
        if foundWhiteTextGlyph { break }
    }
    try require(foundWhiteTextGlyph, "White heading text inside ink-filled shape was missing in exported PNG")

    // Verify Keynote light (#ffffff) and dark (#121519) slide compositing:
    // Compositing the exported PNG onto both light and dark slide backgrounds must preserve background transparency
    // while keeping dark strokes, yellow triangle fill, and label pills distinct on both slides.
    for slideColor in [
        NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
        NSColor(srgbRed: 0x12 / 255.0, green: 0x15 / 255.0, blue: 0x19 / 255.0, alpha: 1),
    ] {
        let slideRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: plan.pixelWidth,
            pixelsHigh: plan.pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: slideRep)
        slideColor.setFill()
        NSRect(x: 0, y: 0, width: plan.pixelWidth, height: plan.pixelHeight).fill()
        let image = NSImage(size: NSSize(width: plan.pixelWidth, height: plan.pixelHeight))
        image.addRepresentation(repZoom1)
        image.draw(in: NSRect(x: 0, y: 0, width: plan.pixelWidth, height: plan.pixelHeight))
        NSGraphicsContext.restoreGraphicsState()

        let bgSample = slideRep.colorAt(x: 5, y: 5)!.usingColorSpace(.sRGB)!
        let expectedSlide = slideColor.usingColorSpace(.sRGB)!
        try require(
            abs(bgSample.redComponent - expectedSlide.redComponent) < 0.02
                && abs(bgSample.greenComponent - expectedSlide.greenComponent) < 0.02
                && abs(bgSample.blueComponent - expectedSlide.blueComponent) < 0.02,
            "Exported PNG did not let Keynote slide background show through transparent margin"
        )
        let (triX, triY) = exportPixel(for: CGPoint(x: 460, y: 185), in: plan)
        let triSample = slideRep.colorAt(x: triX, y: triY)!.usingColorSpace(.sRGB)!
        try require(
            abs(triSample.redComponent - expectedSlide.redComponent)
                + abs(triSample.greenComponent - expectedSlide.greenComponent)
                + abs(triSample.blueComponent - expectedSlide.blueComponent) > 0.35,
            "Rotated yellow triangle was not visible on Keynote slide"
        )
    }

    // 4. Exact dimensions with transparent letterboxing (never stretched).
    let exactPlan = try view.exportPNGPlan(sizing: .exact(width: 600, height: 600))
    let exactData = try view.exportPNGData(sizing: .exact(width: 600, height: 600))
    guard let exactRep = NSBitmapImageRep(data: exactData) else {
        throw CheckFailure(description: "Could not decode exact-dimension PNG")
    }
    try require(
        exactRep.pixelsWide == 600 && exactRep.pixelsHigh == 600
            && (exactPlan.offsetX > 10 || exactPlan.offsetY > 10),
        "Exact 600x600 export of non-square diagram did not letterbox proportionally"
    )
    if exactPlan.offsetY > 10 {
        let bandY = Int(exactPlan.offsetY / 2)
        for x in stride(from: 20, to: 580, by: 40) {
            try require(
                exactRep.colorAt(x: x, y: bandY)!.alphaComponent == 0,
                "Letterbox band at y=\(bandY) was not transparent"
            )
        }
    }

    // Verify exporting did not alter session root, original bytes, or redo history.
    try require(
        NSDictionary(dictionary: diagramSession.root).isEqual(to: diagramRoot)
            && diagramSession.document.originalData == diagramBytes
            && view.undoManager?.canRedo == true,
        "PNG export mutated committed session state, original bytes, or redo history"
    )

    // 5. Pending editor/preview flushing and invalid-draft refusal.
    // 5a. N chooser without placed draft cancels cleanly without history change.
    let rectPt = view.viewPoint(forWorldPoint: CGPoint(x: 180, y: 170))
    view.mouseDown(with: NSEvent.mouseEvent(
        with: .leftMouseDown, location: view.convert(rectPt, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1
    )!)
    view.mouseUp(with: NSEvent.mouseEvent(
        with: .leftMouseUp, location: view.convert(rectPt, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: 1
    )!)
    view.beginAdjacentThought()
    try require(view.isChoosingAdjacentThoughtDirection, "Expected N direction chooser")
    _ = try view.exportPNGData(sizing: .longestSide(512))
    try require(
        !view.hasAdjacentThoughtPreview
            && NSDictionary(dictionary: diagramSession.root).isEqual(to: diagramRoot)
            && view.undoManager?.canRedo == true,
        "Exporting during N direction chooser did not cancel chooser cleanly without history change"
    )

    // 5b. Valid adjacent thought draft flushes and commits once before snapshot capture.
    view.beginAdjacentThought()
    view.keyDown(with: NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 126
    )!) // Up arrow
    try require(view.hasAdjacentThoughtDraft, "Expected active adjacent thought draft")
    view.adjacentThoughtTextView?.string = "Flushed by export"
    let flushedThoughtPNG = try view.exportPNGData(sizing: .longestSide(512))
    try require(
        !view.hasAdjacentThoughtPreview
            && (diagramSession.root["nodes"] as? [[String: Any]])?.count == 5
            && !flushedThoughtPNG.isEmpty,
        "Valid adjacent thought draft was not flushed before PNG export"
    )
    view.undoMove(nil)
    try require(
        NSDictionary(dictionary: diagramSession.root).isEqual(to: diagramRoot),
        "Flushed thought commit did not undo in a single step"
    )

    // 5c. Invalid 2,001-grapheme caption draft refuses export with draft text intact.
    view.mouseDown(with: NSEvent.mouseEvent(
        with: .leftMouseDown, location: view.convert(rectPt, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 2, pressure: 1
    )!)
    guard let captionEditor = view.inlineTextEditorView else {
        throw CheckFailure(description: "Expected inline caption editor")
    }
    captionEditor.string = String(repeating: "z", count: 2_001)
    do {
        _ = try view.exportPNGData(sizing: .longestSide(512))
        throw CheckFailure(description: "Exported PNG while an invalid 2001-grapheme draft was active")
    } catch let error as CanvasDocumentError {
        try require(
            error.localizedDescription.localizedCaseInsensitiveContains("2000"),
            "Unexpected invalid-draft refusal error: \(error.localizedDescription)"
        )
    }
    try require(
        view.hasActiveInlineTextEditor
            && view.inlineTextEditorView?.string.count == 2_001
            && NSDictionary(dictionary: diagramSession.root).isEqual(to: diagramRoot),
        "Refused export lost invalid draft text or mutated session"
    )
    view.cancelInlineText()

    // 5d. Active G geometry preview commits once when exporting.
    view.beginGeometryEditing()
    view.keyDown(with: NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.shift],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124
    )!) // Shift-Right +10 width
    try require(view.hasGeometryPreview, "Expected active geometry preview")
    _ = try view.exportPNGData(sizing: .longestSide(512))
    try require(
        !view.hasGeometryPreview && diagramSession.geometry(of: "rect-dark")?.width == 190,
        "Active geometry preview did not flush and commit before PNG export"
    )
    view.undoMove(nil)
    try require(
        NSDictionary(dictionary: diagramSession.root).isEqual(to: diagramRoot),
        "Undo after geometry-flushed export did not restore baseline"
    )

    // 6. Interactive PNGExportSheet via File -> Export PNG… menu action:
    //    validation errors, cancelled destination picker, live slide preview, theme persistence,
    //    and actual PNG file writes for light and dark slides.
    view.deselectAll()
    let savedThemeDefault = UserDefaults.standard.object(forKey: CanvasPNGExportTheme.userDefaultsKey)
    UserDefaults.standard.removeObject(forKey: CanvasPNGExportTheme.userDefaultsKey)
    defer {
        if let savedThemeDefault {
            UserDefaults.standard.set(savedThemeDefault, forKey: CanvasPNGExportTheme.userDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: CanvasPNGExportTheme.userDefaultsKey)
        }
    }

    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("canvas-png-checks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    guard let fileMenu = NSApp.mainMenu?.item(withTitle: "File")?.submenu,
          let exportItem = fileMenu.item(withTitle: "Export PNG…") else {
        throw CheckFailure(description: "File -> Export PNG… menu item not found")
    }
    try require(
        appDelegate.validateMenuItem(exportItem),
        "Export PNG… menu item was not enabled for non-empty canvas"
    )

    var destinationCalls = 0
    view.pngExportDestinationProvider = { _ in
        destinationCalls += 1
        return nil // Simulate user cancelling NSSavePanel first
    }
    appDelegate.exportPNG(nil)
    try require(
        view.isPNGExportSheetOpen && !appDelegate.validateMenuItem(exportItem),
        "Export PNG… did not present sheet or disable menu item while sheet is open"
    )
    guard let exportPanel = view.activePNGExportPanel,
          let contentView = exportPanel.contentView else {
        throw CheckFailure(description: "Missing active PNGExportSheet panel")
    }
    func findControl<T: NSView>(_ id: String, as type: T.Type) throws -> T {
        guard let found = contentView.subviews.first(where: { $0.identifier?.rawValue == id }) as? T else {
            throw CheckFailure(description: "Missing control '\(id)' in PNGExportSheet")
        }
        return found
    }
    let previewView = try findControl("export-png-preview", as: NSView.self)
    let themePopup = try findControl("export-png-theme", as: NSPopUpButton.self)
    let modePopup = try findControl("export-png-mode", as: NSPopUpButton.self)
    let longestField = try findControl("export-png-longest", as: NSTextField.self)
    let widthField = try findControl("export-png-width", as: NSTextField.self)
    let heightField = try findControl("export-png-height", as: NSTextField.self)
    let summaryLabel = try findControl("export-png-summary", as: NSTextField.self)
    let errorLabel = try findControl("export-png-error", as: NSTextField.self)
    let confirmBtn = try findControl("export-png-confirm", as: NSButton.self)

    try require(
        themePopup.indexOfSelectedItem == 0
            && summaryLabel.stringValue.contains("Dark ink for light slides"),
        "PNGExportSheet did not default to Light slides (dark ink)"
    )

    func samplePreviewCorner(_ view: NSView) throws -> NSColor {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CheckFailure(description: "Could not allocate bitmap for PNGExportPreviewView")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let color = rep.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB) else {
            throw CheckFailure(description: "Could not sample preview backdrop pixel")
        }
        return color
    }
    let lightPreviewBg = try samplePreviewCorner(previewView)
    try require(
        lightPreviewBg.redComponent > 0.9 && lightPreviewBg.greenComponent > 0.9 && lightPreviewBg.blueComponent > 0.9,
        "Light slide preview backdrop did not render Raw Gallery Plaster (got \(lightPreviewBg))"
    )

    // Invalid longest side > 8192 shows error in sheet without calling destination provider.
    longestField.stringValue = "9000"
    confirmBtn.performClick(nil)
    try require(
        view.isPNGExportSheetOpen && !errorLabel.isHidden
            && errorLabel.stringValue.contains("8192") && destinationCalls == 0,
        "Over-cap longest side in PNGExportSheet did not show visible error without opening Save panel"
    )

    // Valid longest side with cancelled Save panel keeps sheet open and writes nothing.
    longestField.stringValue = "1024"
    confirmBtn.performClick(nil)
    try require(
        view.isPNGExportSheetOpen && destinationCalls == 1,
        "Cancelled Save panel did not leave PNGExportSheet intact"
    )

    // Switch to Exact dimensions (800 x 600), provide destination URL, and confirm export.
    modePopup.selectItem(at: 1)
    _ = modePopup.target?.perform(modePopup.action, with: modePopup)
    widthField.stringValue = "800"
    heightField.stringValue = "600"
    let outputURL = tempDir.appendingPathComponent("keynote-slide.png")
    view.pngExportDestinationProvider = { _ in outputURL }
    confirmBtn.performClick(nil)

    try require(
        !view.isPNGExportSheetOpen && FileManager.default.fileExists(atPath: outputURL.path),
        "Confirming PNGExportSheet did not write PNG file and dismiss sheet"
    )
    let diskBytes = try Data(contentsOf: outputURL)
    let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    try require(
        Array(diskBytes.prefix(8)) == pngSignature,
        "Written file does not start with valid PNG signature"
    )
    guard let diskRep = NSBitmapImageRep(data: diskBytes) else {
        throw CheckFailure(description: "Written PNG file could not be decoded")
    }
    try require(
        diskRep.pixelsWide == 800 && diskRep.pixelsHigh == 600
            && diskRep.colorAt(x: 0, y: 0)?.alphaComponent == 0,
        "Written PNG file did not match exact 800x600 transparent output"
    )

    // 7. Analytic cubic Bézier extrema & stroked-path bounds regression:
    //    100×50 nodes at (0,0) and (0, 1_000_000) connected top→top have an analytic curve minimum
    //    y ≈ -136,271.24 (at t = (3 - sqrt(5))/4 ≈ 0.1910), whereas 24-step uniform sampling only
    //    reaches y ≈ -135,272 (missing ~999 world units, exceeding the 32-unit padding).
    let longBezierRoot: [String: Any] = [
        "version": 2,
        "nodes": [
            ["id": "top-a", "type": "shape", "x": 0, "y": 0, "width": 100, "height": 50, "data": ["kind": "rect"]],
            ["id": "top-b", "type": "shape", "x": 0, "y": 1_000_000, "width": 100, "height": 50, "data": ["kind": "rect"]],
        ],
        "edges": [
            [
                "id": "e-extreme", "source": "top-a", "source_handle": "top",
                "target": "top-b", "target_handle": "top", "path": "bezier",
                "marker": "arrow",
                "data": ["connector_style": ["stroke": "red", "width": 4, "dash": false]],
            ],
        ],
    ]
    let longBezierView = CanvasView(session: CanvasSession(document: try CanvasDocument(data: encoded(longBezierRoot))))
    let longBezierBounds = longBezierView.contentWorldBounds()
    // Analytic curve minY is -136,271.2429686843; with 4pt stroke (strokePad = 2), minY <= -136,273.24.
    try require(
        longBezierBounds.minY <= -136_273.2,
        "contentWorldBounds.minY (\(longBezierBounds.minY)) missed analytic cubic Bézier extremum (-136,273.24)"
    )

    // Verify exported pixels of an asymmetric top→top Bézier curve (where true extremum at t≈0.191
    // differs from 24-step samples) are unclipped at padding: 1 and present near the top edge.
    let asymmetricCurveRoot: [String: Any] = [
        "version": 2,
        "nodes": [
            [
                "id": "n1", "type": "shape", "x": 0, "y": 0, "width": 100, "height": 50,
                "data": ["kind": "rect", "fill": "none", "stroke": "ink"],
            ],
            [
                "id": "n2", "type": "shape", "x": 200, "y": 3_000, "width": 100, "height": 50,
                "data": ["kind": "rect", "fill": "none", "stroke": "ink"],
            ],
        ],
        "edges": [
            [
                "id": "e-asym", "source": "n1", "source_handle": "top",
                "target": "n2", "target_handle": "top", "path": "bezier",
                "marker": "none",
                "data": ["connector_style": ["stroke": "red", "width": 4, "dash": false]],
            ],
        ],
    ]
    let asymView = CanvasView(session: CanvasSession(document: try CanvasDocument(data: encoded(asymmetricCurveRoot))))
    let asymPNG = try asymView.exportPNGData(sizing: .longestSide(2_048), padding: 2)
    guard let asymRep = NSBitmapImageRep(data: asymPNG) else {
        throw CheckFailure(description: "Could not decode asymmetric Bézier PNG")
    }
    for x in 0..<asymRep.pixelsWide {
        try require(
            asymRep.colorAt(x: x, y: 0)!.alphaComponent == 0,
            "Asymmetric top→top Bézier clipped top row y=0 at x=\(x)"
        )
    }
    var foundCurveApex = false
    for y in 1...8 {
        for x in 0..<asymRep.pixelsWide {
            if let c = asymRep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
               c.alphaComponent > 0.25 && c.redComponent > 0.5 {
                foundCurveApex = true
                break
            }
        }
        if foundCurveApex { break }
    }
    try require(foundCurveApex, "Exported PNG did not render the analytic Bézier apex near the top padding boundary")

    // 8. Export-only dark-slide PNG theme: WCAG contrast, light-ink transparent PNG pixels,
    //    live dark-slide preview, and remembered UserDefaults theme across sheet opens.
    func darkLuminance(_ color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.sRGB)!
        func ch(_ v: CGFloat) -> CGFloat { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(rgb.redComponent) + 0.7152 * ch(rgb.greenComponent) + 0.0722 * ch(rgb.blueComponent)
    }
    func darkContrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = darkLuminance(a), lb = darkLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    for fill in ["none", "surface", "gray", "accent", "blue", "green", "violet", "yellow", "red", "ink"] {
        let bg = fill == "none" ? CanvasTheme.darkCanvasBackground : CanvasTheme.palette(fill, theme: .dark)
        let fg = CanvasTheme.textColor(onFill: fill, theme: .dark)
        let ratio = darkContrast(bg, fg)
        try require(ratio >= 4.5, "Dark-slide export fill '\(fill)' contrast \(ratio) fell below 4.5:1")
    }

    let darkPNGData = try view.exportPNGData(theme: .dark)
    guard let darkRep = NSBitmapImageRep(data: darkPNGData) else {
        throw CheckFailure(description: "Could not decode dark-slide PNG")
    }
    try require(
        darkRep.pixelsWide == plan.pixelWidth && darkRep.pixelsHigh == plan.pixelHeight
            && darkRep.colorAt(x: 0, y: 0)?.alphaComponent == 0
            && darkRep.colorAt(x: emptyX, y: emptyY)?.alphaComponent == 0,
        "Dark-slide PNG export did not preserve exact dimensions and true alpha transparency"
    )
    // In dark-slide export, `ink`-filled rect-dark resolves to Silver White (#e7ecf2) with Ebony Ink text.
    let darkModeInkRect = darkRep.colorAt(x: darkRectX, y: darkRectY)!.usingColorSpace(.sRGB)!
    try require(
        darkModeInkRect.alphaComponent > 0.99
            && darkModeInkRect.redComponent > 0.85
            && darkModeInkRect.greenComponent > 0.88
            && darkModeInkRect.blueComponent > 0.90,
        "Dark-slide PNG `ink`-filled rectangle did not resolve to Silver White (#e7ecf2)"
    )
    var foundDarkGlyphOnInkRect = false
    for py in darkTextMinY...darkTextMaxY {
        for px in darkTextMinX...darkTextMaxX {
            if let c = darkRep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB),
               c.alphaComponent > 0.9 && c.redComponent < 0.12 && c.greenComponent < 0.12 && c.blueComponent < 0.12 {
                foundDarkGlyphOnInkRect = true
                break
            }
        }
        if foundDarkGlyphOnInkRect { break }
    }
    try require(foundDarkGlyphOnInkRect, "Dark-slide PNG `ink`-filled rectangle did not render Ebony Ink heading text")

    // In dark-slide export, `surface`-filled code-box resolves to Obsidian Elevated (#222831) with Silver White text.
    let (codeBgX, codeBgY) = exportPixel(for: CGPoint(x: 305, y: 375), in: plan)
    let codeBgColor = darkRep.colorAt(x: codeBgX, y: codeBgY)!.usingColorSpace(.sRGB)!
    try require(
        codeBgColor.alphaComponent > 0.99
            && codeBgColor.redComponent < 0.22
            && codeBgColor.greenComponent < 0.24
            && codeBgColor.blueComponent < 0.28,
        "Dark-slide PNG `surface`-filled code block did not render Obsidian Elevated (#222831)"
    )
    let (codeMinX, codeMinY) = exportPixel(for: CGPoint(x: 108, y: 308), in: plan)
    let (codeMaxX, codeMaxY) = exportPixel(for: CGPoint(x: 290, y: 360), in: plan)
    var foundLightCodeText = false
    for py in codeMinY...codeMaxY {
        for px in codeMinX...codeMaxX {
            if let c = darkRep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB),
               c.alphaComponent > 0.9 && c.redComponent > 0.80 && c.greenComponent > 0.84 && c.blueComponent > 0.88 {
                foundLightCodeText = true
                break
            }
        }
        if foundLightCodeText { break }
    }
    try require(foundLightCodeText, "Dark-slide PNG `surface`-filled code block did not render Silver White code text")

    // Verify interactive PNGExportSheet dark-slide toggle updates preview, writes dark PNG, and remembers preference.
    appDelegate.exportPNG(nil)
    guard let darkPanel = view.activePNGExportPanel,
          let darkContent = darkPanel.contentView,
          let darkPreview = darkContent.subviews.first(where: { $0.identifier?.rawValue == "export-png-preview" }),
          let darkThemePopup = darkContent.subviews.first(where: { $0.identifier?.rawValue == "export-png-theme" }) as? NSPopUpButton,
          let darkSummary = darkContent.subviews.first(where: { $0.identifier?.rawValue == "export-png-summary" }) as? NSTextField,
          let darkConfirm = darkContent.subviews.first(where: { $0.identifier?.rawValue == "export-png-confirm" }) as? NSButton else {
        throw CheckFailure(description: "Missing dark-slide controls in reopened PNGExportSheet")
    }
    darkThemePopup.selectItem(at: 1)
    _ = darkThemePopup.target?.perform(darkThemePopup.action, with: darkThemePopup)
    try require(
        darkSummary.stringValue.contains("Light ink for dark slides"),
        "Switching PNGExportSheet to Dark slides did not update summary copy"
    )
    let darkPreviewBg = try samplePreviewCorner(darkPreview)
    try require(
        darkPreviewBg.redComponent < 0.14 && darkPreviewBg.greenComponent < 0.16 && darkPreviewBg.blueComponent < 0.18,
        "Dark slide preview backdrop did not render Obsidian Clay (#121519) (got \(darkPreviewBg))"
    )
    let darkOutputURL = tempDir.appendingPathComponent("keynote-dark-slide.png")
    view.pngExportDestinationProvider = { _ in darkOutputURL }
    darkConfirm.performClick(nil)
    try require(
        !view.isPNGExportSheetOpen && FileManager.default.fileExists(atPath: darkOutputURL.path),
        "Dark-slide PNGExportSheet did not write PNG file and dismiss"
    )
    let darkDiskBytes = try Data(contentsOf: darkOutputURL)
    try require(
        darkDiskBytes == darkPNGData,
        "Dark-slide PNG written from sheet did not match direct dark-theme PNG export"
    )
    try require(
        CanvasPNGExportTheme.loadDefault() == .dark,
        "Confirming dark-slide export did not persist dark theme default"
    )
    // Reopening the sheet picks up the persisted Dark slides preference and cancelling leaves state untouched.
    appDelegate.exportPNG(nil)
    guard let reopenedPanel = view.activePNGExportPanel,
          let reopenedContent = reopenedPanel.contentView,
          let reopenedThemePopup = reopenedContent.subviews.first(where: { $0.identifier?.rawValue == "export-png-theme" }) as? NSPopUpButton,
          let reopenedCancel = reopenedContent.subviews.first(where: { $0.identifier?.rawValue == "export-png-cancel" }) as? NSButton else {
        throw CheckFailure(description: "Missing controls in second reopened PNGExportSheet")
    }
    try require(
        reopenedThemePopup.indexOfSelectedItem == 1,
        "Reopened PNGExportSheet did not remember persisted Dark slides selection"
    )
    reopenedCancel.performClick(nil)
    try require(
        NSDictionary(dictionary: diagramSession.root).isEqual(to: diagramRoot)
            && diagramSession.document.originalData == diagramBytes,
        "Dark-slide PNG export mutated committed session state or original document bytes"
    )

    // 9. Selection-scoped PNG export: when items are selected, only selected items (and connections
    //    between selected nodes, including self-loops) are exported; PNGExportSheet defaults to
    //    Selection and allows switching back to Entire canvas.
    // 9a. Explicit .selection with no selection refuses cleanly.
    view.deselectAll()
    do {
        _ = try view.exportPNGData(scope: .selection)
        throw CheckFailure(description: "Accepted explicit .selection PNG export when nothing was selected")
    } catch let error as CanvasDocumentError {
        try require(
            error.localizedDescription.localizedCaseInsensitiveContains("selected"),
            "Unexpected empty-selection export error: \(error.localizedDescription)"
        )
    }

    // 9b. Single unconnected node ("code-box"): tightly cropped to code-box only, while .entireCanvas still exports all.
    view.selectNode("code-box")
    let codeBounds = view.contentWorldBounds(scope: .selection)
    let codePlan = try view.exportPNGPlan()
    try require(
        codeBounds.minX >= 98 && codeBounds.minY >= 298 && codeBounds.maxX <= 322 && codeBounds.maxY <= 392
            && codePlan.contentWorldBounds == codeBounds
            && codePlan.pixelHeight < plan.pixelHeight,
        "Single-node selection bounds/plan did not crop tightly to code-box (bounds=\(codeBounds), plan=\(codePlan.pixelWidth)x\(codePlan.pixelHeight))"
    )
    let codeOnlyPNG = try view.exportPNGData()
    let codeOnlyExplicit = try view.exportPNGData(scope: .selection)
    let fullWhileSelected = try view.exportPNGData(scope: .entireCanvas)
    try require(
        codeOnlyPNG == codeOnlyExplicit && fullWhileSelected == pngDataZoom1,
        "Selection-scoped .automatic did not match .selection or .entireCanvas differed from full canvas"
    )
    guard let codeOnlyRep = NSBitmapImageRep(data: codeOnlyPNG) else {
        throw CheckFailure(description: "Could not decode single-node selection PNG")
    }
    try require(
        codeOnlyRep.pixelsWide == codePlan.pixelWidth && codeOnlyRep.pixelsHigh == codePlan.pixelHeight
            && codeOnlyRep.colorAt(x: 0, y: 0)?.alphaComponent == 0,
        "Single-node selection PNG dimensions or padding transparency did not match plan"
    )
    // Verify no selection cobalt chrome leaked onto code-box border in selection export.
    let (codeBorderX, codeBorderY) = exportPixel(for: CGPoint(x: 210, y: 300), in: codePlan)
    let codeBorderColor = codeOnlyRep.colorAt(x: codeBorderX, y: codeBorderY)!.usingColorSpace(.sRGB)!
    try require(
        !(codeBorderColor.blueComponent > 0.7 && codeBorderColor.redComponent < 0.25),
        "Selection cobalt chrome leaked into single-node selection PNG"
    )

    // 9c. Single node with self-loop ("rect-dark"): includes its self-loop ("edge-loop") and excludes
    //     "edge-main" (whose target "tri-rot" is unselected) and all other nodes.
    view.selectNode("rect-dark")
    let rectOnlyBounds = view.contentWorldBounds(scope: .selection)
    try require(
        rectOnlyBounds.minX < 100 && rectOnlyBounds.minY < 120 && rectOnlyBounds.maxX < 320 && rectOnlyBounds.maxY < 240,
        "rect-dark selection bounds (\(rectOnlyBounds)) did not include self-loop while excluding tri-rot and code-box"
    )
    let rectOnlyPlan = try view.exportPNGPlan()
    let rectOnlyPNG = try view.exportPNGData()
    guard let rectOnlyRep = NSBitmapImageRep(data: rectOnlyPNG) else {
        throw CheckFailure(description: "Could not decode rect-dark selection PNG")
    }
    let (rectFillX, rectFillY) = exportPixel(for: CGPoint(x: 115, y: 135), in: rectOnlyPlan)
    let rectFillColor = rectOnlyRep.colorAt(x: rectFillX, y: rectFillY)!.usingColorSpace(.sRGB)!
    try require(
        rectFillColor.alphaComponent > 0.99 && rectFillColor.redComponent < 0.1,
        "rect-dark selection PNG did not render opaque ink-filled rectangle"
    )

    // 9d. Multi-selection via Shift-click ("rect-dark" + "tri-rot"): includes both shapes, connecting
    //     "edge-main", and "edge-loop", while excluding "code-box" and "free-arrow" below y=290.
    let triPt = view.viewPoint(forWorldPoint: CGPoint(x: 460, y: 185))
    view.mouseDown(with: NSEvent.mouseEvent(
        with: .leftMouseDown, location: view.convert(triPt, to: nil), modifierFlags: [.shift],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 2, clickCount: 1, pressure: 1
    )!)
    view.mouseUp(with: NSEvent.mouseEvent(
        with: .leftMouseUp, location: view.convert(triPt, to: nil), modifierFlags: [.shift],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 2, clickCount: 1, pressure: 1
    )!)
    try require(view.selectedNodeIDs == Set(["rect-dark", "tri-rot"]), "Expected rect-dark and tri-rot selected")
    let pairBounds = view.contentWorldBounds(scope: .selection)
    try require(
        pairBounds.maxX > 540 && pairBounds.maxY < 290,
        "Multi-node selection bounds (\(pairBounds)) did not include rotated triangle while excluding lower code-box/free-arrow"
    )
    let pairPlan = try view.exportPNGPlan()
    let pairPNG = try view.exportPNGData()
    guard let pairRep = NSBitmapImageRep(data: pairPNG) else {
        throw CheckFailure(description: "Could not decode multi-node selection PNG")
    }
    let (pairTriX, pairTriY) = exportPixel(for: CGPoint(x: 460, y: 185), in: pairPlan)
    let pairTriColor = pairRep.colorAt(x: pairTriX, y: pairTriY)!.usingColorSpace(.sRGB)!
    try require(
        pairTriColor.alphaComponent > 0.99 && pairTriColor.redComponent > 0.8 && pairTriColor.greenComponent > 0.7,
        "Multi-node selection PNG did not render selected yellow triangle"
    )
    // Verify connecting edge "edge-main" (violet stroke around x=330, y=170) is present between the two selected nodes.
    let (connMinX, connMinY) = exportPixel(for: CGPoint(x: 295, y: 150), in: pairPlan)
    let (connMaxX, connMaxY) = exportPixel(for: CGPoint(x: 365, y: 190), in: pairPlan)
    var foundConnectingEdge = false
    for py in connMinY...connMaxY {
        for px in connMinX...connMaxX {
            if let c = pairRep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB),
               c.alphaComponent > 0.8 && c.blueComponent > 0.5 && c.redComponent > 0.25 {
                foundConnectingEdge = true
                break
            }
        }
        if foundConnectingEdge { break }
    }
    try require(foundConnectingEdge, "Multi-node selection PNG did not include connecting edge between selected nodes")

    // 9e. Single connection selected ("edge-main" only): exports only that edge + label without shape fills or selection cobalt.
    view.selectConnection("edge-main")
    let edgeOnlyBounds = view.contentWorldBounds(scope: .selection)
    try require(
        edgeOnlyBounds.minX >= 275 && edgeOnlyBounds.maxX <= 435
            && edgeOnlyBounds.minY >= 120 && edgeOnlyBounds.maxY <= 200,
        "Single-connection selection bounds (\(edgeOnlyBounds)) did not crop tightly to edge-main"
    )
    let edgeOnlyPNG = try view.exportPNGData()
    guard let edgeOnlyRep = NSBitmapImageRep(data: edgeOnlyPNG) else {
        throw CheckFailure(description: "Could not decode single-connection selection PNG")
    }
    try require(
        edgeOnlyRep.colorAt(x: 0, y: 0)?.alphaComponent == 0 && edgeOnlyPNG != pngDataZoom1,
        "Single-connection selection PNG did not export cropped transparent edge"
    )

    // 9f. Interactive PNGExportSheet with selection:
    //     defaults to Selected items, writes selection-only PNG, and allows switching to Entire canvas.
    UserDefaults.standard.set(CanvasPNGExportTheme.light.rawValue, forKey: CanvasPNGExportTheme.userDefaultsKey)
    view.selectNode("code-box")
    appDelegate.exportPNG(nil)
    guard let selPanel = view.activePNGExportPanel,
          let selContent = selPanel.contentView,
          let selScopePopup = selContent.subviews.first(where: { $0.identifier?.rawValue == "export-png-scope" }) as? NSPopUpButton,
          let selSummary = selContent.subviews.first(where: { $0.identifier?.rawValue == "export-png-summary" }) as? NSTextField,
          let selConfirm = selContent.subviews.first(where: { $0.identifier?.rawValue == "export-png-confirm" }) as? NSButton else {
        throw CheckFailure(description: "Missing export-png-scope controls in PNGExportSheet when item is selected")
    }
    try require(
        selScopePopup.indexOfSelectedItem == 0
            && selScopePopup.itemTitle(at: 0) == "Selected item"
            && selScopePopup.itemTitle(at: 1) == "Entire canvas"
            && selSummary.stringValue.contains("Selected item")
            && selSummary.stringValue.contains("\(codePlan.pixelWidth) × \(codePlan.pixelHeight)"),
        "PNGExportSheet with 1 selected item did not default to Selected item with cropped dimensions (summary: \(selSummary.stringValue))"
    )
    let selOutputURL = tempDir.appendingPathComponent("selection-only.png")
    view.pngExportDestinationProvider = { _ in selOutputURL }
    selConfirm.performClick(nil)
    try require(
        !view.isPNGExportSheetOpen && FileManager.default.fileExists(atPath: selOutputURL.path),
        "Selection-scoped PNGExportSheet did not write PNG file and dismiss"
    )
    let selDiskBytes = try Data(contentsOf: selOutputURL)
    try require(
        selDiskBytes == codeOnlyPNG,
        "PNG written from selection-scoped sheet did not match direct selection-only PNG export"
    )

    // Reopen sheet with 2 items selected, switch scope to Entire canvas, and confirm full-canvas export.
    view.selectNode("rect-dark")
    view.mouseDown(with: NSEvent.mouseEvent(
        with: .leftMouseDown, location: view.convert(triPt, to: nil), modifierFlags: [.shift],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 3, clickCount: 1, pressure: 1
    )!)
    view.mouseUp(with: NSEvent.mouseEvent(
        with: .leftMouseUp, location: view.convert(triPt, to: nil), modifierFlags: [.shift],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 3, clickCount: 1, pressure: 1
    )!)
    appDelegate.exportPNG(nil)
    guard let multiPanel = view.activePNGExportPanel,
          let multiContent = multiPanel.contentView,
          let multiScopePopup = multiContent.subviews.first(where: { $0.identifier?.rawValue == "export-png-scope" }) as? NSPopUpButton,
          let multiSummary = multiContent.subviews.first(where: { $0.identifier?.rawValue == "export-png-summary" }) as? NSTextField,
          let multiConfirm = multiContent.subviews.first(where: { $0.identifier?.rawValue == "export-png-confirm" }) as? NSButton else {
        throw CheckFailure(description: "Missing export-png-scope controls for multi-selection PNGExportSheet")
    }
    try require(
        multiScopePopup.indexOfSelectedItem == 0
            && multiScopePopup.itemTitle(at: 0) == "Selected items (2)"
            && multiSummary.stringValue.contains("Selected items (2)"),
        "PNGExportSheet with 2 selected items did not default to 'Selected items (2)'"
    )
    multiScopePopup.selectItem(at: 1)
    _ = multiScopePopup.target?.perform(multiScopePopup.action, with: multiScopePopup)
    try require(
        multiSummary.stringValue.contains("\(plan.pixelWidth) × \(plan.pixelHeight)")
            && !multiSummary.stringValue.contains("Selected items"),
        "Switching PNGExportSheet scope to Entire canvas did not update summary to full-canvas dimensions"
    )
    let fullFromSheetURL = tempDir.appendingPathComponent("entire-canvas-from-selection.png")
    view.pngExportDestinationProvider = { _ in fullFromSheetURL }
    multiConfirm.performClick(nil)
    try require(
        !view.isPNGExportSheetOpen && (try Data(contentsOf: fullFromSheetURL)) == pngDataZoom1,
        "Switching PNGExportSheet scope to Entire canvas did not write full-canvas PNG"
    )
    try require(
        view.selectedNodeIDs == Set(["rect-dark", "tri-rot"])
            && NSDictionary(dictionary: diagramSession.root).isEqual(to: diagramRoot)
            && diagramSession.document.originalData == diagramBytes,
        "Selection-scoped PNG export altered selection, committed session state, or original document bytes"
    )

    // With no selection, export-png-scope is omitted from the sheet.
    view.deselectAll()
    appDelegate.exportPNG(nil)
    guard let noSelPanel = view.activePNGExportPanel,
          let noSelContent = noSelPanel.contentView,
          let noSelCancel = noSelContent.subviews.first(where: { $0.identifier?.rawValue == "export-png-cancel" }) as? NSButton else {
        throw CheckFailure(description: "Missing controls in no-selection PNGExportSheet")
    }
    try require(
        !noSelContent.subviews.contains(where: { $0.identifier?.rawValue == "export-png-scope" }),
        "PNGExportSheet unexpectedly showed export-png-scope when nothing was selected"
    )
    noSelCancel.performClick(nil)

    print("PASS bundled Neo-Acid typography + glyph fallback, transparent PNG export (bounds, 32pt pad, caps, zoom/DPR invariance, letterboxing, draft flush, light/dark Keynote slide themes, selection scope, live preview, and Export PNG sheet)")
}
