import AppKit
import CanvasCore
import CanvasUI
import Foundation

@MainActor
func runPolishChecks(repository: URL) throws {
    let fm = FileManager.default
    let tempRoot = fm.temporaryDirectory.appendingPathComponent("CanvasPolishChecks-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempRoot) }

    // 1. Regression for ⌘Q / window-teardown SIGSEGV:
    //    Verify NSWindowController.document is detached BEFORE CanvasNativeDocument deallocates
    //    both on windowWillClose (triggered by NSWindow.close / termination) and closeAllWindows().
    do {
        let recoveryDir = tempRoot.appendingPathComponent("TeardownRecovery", isDirectory: true)
        let recoveryStore = CanvasRecoveryStore(directoryURL: recoveryDir)
        let delegate = CanvasAppDelegate(recoveryStore: recoveryStore)
        delegate.persistsWindowFrameSize = false
        delegate.installMenu()

        delegate.newDocument(nil)
        weak var weakDoc1: CanvasNativeDocument?
        let window1: NSWindow
        let retainedController: NSWindowController?
        do {
            guard let doc1 = delegate.activeNativeDocument(),
                  let win1 = doc1.canvasView.window else {
                throw CheckFailure(description: "Failed to open document for teardown regression check")
            }
            window1 = win1
            weakDoc1 = doc1
            try require(
                window1.contentMinSize == CanvasAppDelegate.minimumDocumentContentSize &&
                !window1.isRestorable,
                "Document window missing contentMinSize (640x440) or isRestorable=false"
            )
            retainedController = window1.windowController
            try require(retainedController?.document as AnyObject === doc1, "Window controller not attached to document initially")
        }

        // Simulate NSApplication.terminate sequence: applicationShouldTerminate -> window.close()
        let reply = delegate.applicationShouldTerminate(NSApplication.shared)
        try require(reply == .terminateNow, "Clean document did not approve applicationShouldTerminate")
        autoreleasepool {
            window1.close()
        }
        try require(
            retainedController?.document == nil &&
            window1.windowController == nil &&
            window1.delegate == nil &&
            delegate.openNativeDocuments.isEmpty,
            "windowWillClose did not detach NSWindowController.document before releasing CanvasNativeDocument"
        )
        _ = weakDoc1

        // Repeat with multiple windows + closeAllWindows()
        delegate.newDocument(nil)
        delegate.newDocument(nil)
        let secondWindow = delegate.openNativeDocuments.last?.canvasView.window
        let secondController = secondWindow?.windowController
        delegate.closeAllWindows()
        try require(
            secondController?.document == nil &&
            secondWindow?.windowController == nil &&
            delegate.openNativeDocuments.isEmpty,
            "closeAllWindows did not detach NSWindowController.document"
        )

        // 2. Dock reopen (applicationShouldHandleReopen) reopens Welcome when no windows exist,
        //    and closing Welcome clears welcome reference so a second reopen works too.
        try require(!delegate.isWelcomeWindowOpen, "Welcome window should be closed before Dock reopen test")
        let reopenHandled = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        try require(reopenHandled && delegate.isWelcomeWindowOpen, "applicationShouldHandleReopen did not show Welcome window")
        delegate.closeAllWindows()
        try require(!delegate.isWelcomeWindowOpen, "closeAllWindows did not close Welcome window")
        _ = delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)
        try require(delegate.isWelcomeWindowOpen, "Second Dock reopen did not show Welcome window")
        delegate.closeAllWindows()
    }

    // 3. About Karton window + standard macOS App/View menus + dynamic version formatting + .karton/.json save suggestions
    do {
        let title = CanvasAppDelegate.aboutVersionTitle(for: Bundle.main)
        try require(title.hasPrefix("Karton "), "Unexpected About title: \(title)")
        let delegate = CanvasAppDelegate()
        delegate.installMenu()
        let appSubmenu = NSApplication.shared.mainMenu?.item(withTitle: "Karton")?.submenu
        let appTitles = appSubmenu?.items.map(\.title) ?? []
        try require(
            appTitles.contains("Services") && appTitles.contains("Hide Karton") &&
            appTitles.contains("Hide Others") && appTitles.contains("Show All"),
            "App menu missing standard macOS Services/Hide items: \(appTitles)"
        )
        let viewSubmenu = NSApplication.shared.mainMenu?.item(withTitle: "View")?.submenu
        try require(
            viewSubmenu?.item(withTitle: "Show Style Inspector") != nil,
            "View menu missing Show Style Inspector item"
        )
        delegate.showAboutPanel(nil)
        try require(delegate.activeAboutWindow != nil, "showAboutPanel did not open custom Neo-Acid About window")
        delegate.closeAllWindows()
        try require(delegate.activeAboutWindow == nil, "closeAllWindows did not close About window")

        // Verify .karton default save suggestion for untitled boards and .json preservation on existing .json files
        let untitled = try CanvasNativeDocument(untitledDisplayName: "Ideas")
        try require(
            untitled.suggestedSaveFilename() == "Ideas.karton",
            "Untitled document should suggest .karton extension, got \(untitled.suggestedSaveFilename())"
        )
        let tmpKartonDir = FileManager.default.temporaryDirectory.appendingPathComponent("karton-ext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpKartonDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpKartonDir) }
        let kartonFile = tmpKartonDir.appendingPathComponent("board.karton")
        try untitled.saveDocumentAs(to: kartonFile)
        let reopenedKarton = try CanvasNativeDocument(opening: kartonFile)
        try require(reopenedKarton.suggestedSaveFilename() == "board.karton", "Opened .karton did not keep .karton filename")
        let legacyJSON = tmpKartonDir.appendingPathComponent("legacy.json")
        try FileManager.default.copyItem(at: repository.appendingPathComponent("shared/fixtures/v1/document.json"), to: legacyJSON)
        let reopenedJSON = try CanvasNativeDocument(opening: legacyJSON)
        try require(reopenedJSON.suggestedSaveFilename() == "legacy.json", "Opened .json did not preserve .json filename")
    }

    // 4. Multi-selection shared-property styling in StyleInspectorView + atomic Undo/Redo + Mixed label
    do {
        let nodes: [[String: Any]] = [
            [
                "id": "r1", "type": "shape", "x": 80, "y": 80, "width": 160, "height": 96,
                "future-r1": "kept",
                "data": ["kind": "rect", "fill": "yellow", "stroke": "ink", "text": "One"]
            ],
            [
                "id": "r2", "type": "shape", "x": 280, "y": 80, "width": 160, "height": 96,
                "data": ["kind": "ellipse", "fill": "blue", "stroke": "ink", "text": "Two"]
            ],
            [
                "id": "r3", "type": "shape", "x": 480, "y": 80, "width": 160, "height": 96,
                "locked": true,
                "data": ["kind": "rect", "fill": "red", "stroke": "ink", "text": "Locked"]
            ]
        ]
        let doc = try CanvasDocument(data: try encoded(canvas(nodes, version: 2)))
        let session = CanvasSession(document: doc)
        let delegate = CanvasAppDelegate()
        delegate.persistsWindowFrameSize = false
        let view = delegate.showSession(session, name: "MultiStyleSmoke")
        defer { delegate.closeAllWindows() }

        view.selectAll(nil) // selects r1 (rect), r2 (ellipse), r3 (locked rect)
        view.showStyleInspector(nil)
        let inspector = view.styleInspector
        func popup(_ property: CanvasStyleProperty) -> NSPopUpButton? {
            inspector.subviews.first(where: { $0.identifier?.rawValue == "style-\(property.rawValue)" }) as? NSPopUpButton
        }
        // Intersection of rect + ellipse omits .radius, keeps .fill, .stroke, .width, .dash, .font, .size, .align
        try require(
            popup(.radius) == nil &&
            popup(.fill)?.titleOfSelectedItem == "Mixed" &&
            popup(.fill)?.selectedItem?.image != nil &&
            popup(.stroke)?.titleOfSelectedItem == "Ink" &&
            popup(.stroke)?.selectedItem?.image != nil &&
            view.alignBar.isHidden,
            "Multi-selection Style inspector did not compute property intersection, swatch icons, or hide duplicate alignBar"
        )
        // Quick 1-click swatch button in Style inspector updates unlocked nodes atomically too
        guard let violetSwatch = inspector.subviews.first(where: { $0.identifier?.rawValue == "style-fill-swatch-violet" }) as? NSButton else {
            throw CheckFailure(description: "Missing 1-click Neo-Acid fill swatch button in StyleInspectorView")
        }
        violetSwatch.performClick(nil)
        try require(
            session.effectiveNodeStyle(of: "r1")?[.fill] == .string("violet") &&
            session.effectiveNodeStyle(of: "r2")?[.fill] == .string("violet") &&
            session.effectiveNodeStyle(of: "r3")?[.fill] == .string("red"),
            "1-click Fill swatch button did not style multi-selection atomically"
        )
        view.undoMove(nil)
        // Choosing "Green" fill updates unlocked r1 & r2 in ONE transaction while leaving locked r3 red!
        let revBefore = session.revision
        let fillPopup = popup(.fill)!
        let greenIndex = fillPopup.indexOfItem(withTitle: "Green")
        try require(greenIndex >= 0, "Multi-selection fill popup missing Green")
        fillPopup.selectItem(at: greenIndex)
        _ = fillPopup.target?.perform(fillPopup.action!, with: fillPopup)
        try require(
            session.revision == revBefore + 1 &&
            session.effectiveNodeStyle(of: "r1")?[.fill] == .string("green") &&
            session.effectiveNodeStyle(of: "r2")?[.fill] == .string("green") &&
            session.effectiveNodeStyle(of: "r3")?[.fill] == .string("red"),
            "Multi-selection style edit did not update unlocked nodes atomically while protecting locked node"
        )
        // Single Undo reverts both r1 and r2 and preserves r1 unknown metadata!
        view.undoMove(nil)
        let r1Raw = (session.root["nodes"] as? [[String: Any]])?.first(where: { $0["id"] as? String == "r1" })
        try require(
            session.effectiveNodeStyle(of: "r1")?[.fill] == .string("yellow") &&
            session.effectiveNodeStyle(of: "r2")?[.fill] == .string("blue") &&
            r1Raw?["future-r1"] as? String == "kept",
            "Single Undo did not revert multi-selection style edit cleanly"
        )
    }

    // 5. Cursor feedback & narrow-window (720x520) overlay non-collision
    do {
        let v2URL = repository.appendingPathComponent("shared/fixtures/v2/code-compatibility.json")
        let doc = try CanvasDocument(data: try Data(contentsOf: v2URL))
        let session = CanvasSession(document: doc)
        let view = CanvasView(session: session)
        view.isToolDockVisible = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        scroll.documentView = view
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.close() }

        // Cursor checks for armed tools
        view.armCreationTool(.shape(.rectangle))
        try require(view.resolvedCursor(at: CGPoint(x: 200, y: 200)) === NSCursor.crosshair, "Armed shape tool did not use crosshair cursor")
        view.armCreationTool(.shape(.text))
        try require(view.resolvedCursor(at: CGPoint(x: 200, y: 200)) === NSCursor.iBeam, "Armed text tool did not use I-beam cursor")
        view.armCreationTool(.select)

        // Overlay non-overlap at narrow 720x520 with dock, zoom control, status banner, align bar, and style inspector!
        view.selectAll(nil)
        view.showStyleInspector(nil)
        view.statusBanner.configure(kind: .readOnly("Narrow window layout verification"))
        view.positionAllOverlays()

        let dockF = view.toolDock.frame
        let zoomF = view.zoomControl.frame
        let bannerF = view.statusBanner.frame
        let styleF = view.styleInspector.frame

        try require(!dockF.intersects(zoomF), "Tool dock overlapped zoom control at 720x520: \(dockF) vs \(zoomF)")
        try require(view.alignBar.isHidden, "Floating align bar should stay hidden while Style inspector is open")
        try require(!bannerF.intersects(styleF), "Status banner overlapped style inspector at 720x520: \(bannerF) vs \(styleF)")
        try require(!dockF.intersects(styleF), "Tool dock overlapped style inspector at 720x520: \(dockF) vs \(styleF)")

        // Code editor overlay fits cleanly inside narrow 720x520 between banner and dock
        view.closeStyleInspector(nil)
        try require(!view.alignBar.isHidden, "Floating align bar should reappear when Style inspector closes on multi-selection")
        try require(!dockF.intersects(view.alignBar.frame), "Tool dock overlapped align bar at 720x520")
        view.beginNewCodeBlock()
        view.positionAllOverlays()
        if let codeF = view.activeCodeEditor?.frame {
            try require(!codeF.intersects(bannerF), "Code editor overlapped status banner at 720x520")
            try require(!codeF.intersects(dockF), "Code editor overlapped tool dock at 720x520")
        } else {
            throw CheckFailure(description: "Code editor failed to open in narrow window check")
        }
        view.cancelCodeEditor()
    }

    // 6. Lazy CanvasCodeHighlighter startup: fresh instance loads zero engines until needed
    do {
        let t0 = CFAbsoluteTimeGetCurrent()
        let fresh = CanvasCodeHighlighter()
        let initMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        try require(
            !fresh.isLightEngineLoaded && !fresh.isDarkEngineLoaded && !fresh.isDetectorLoaded && initMs < 20.0,
            "Fresh CanvasCodeHighlighter eagerly initialized JS engines (\(String(format: "%.1f", initMs)) ms)"
        )
        let t1 = CFAbsoluteTimeGetCurrent()
        _ = fresh.highlight(source: "defmodule A, do: :ok", language: "elixir", isDark: false)
        let firstLightMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000.0
        try require(
            fresh.isLightEngineLoaded && !fresh.isDarkEngineLoaded && !fresh.isDetectorLoaded,
            "Explicit-language light highlight unnecessarily initialized dark or detector JS engines"
        )
        let t2 = CFAbsoluteTimeGetCurrent()
        _ = fresh.highlight(source: "defmodule A, do: :ok", language: "elixir", isDark: false)
        let cachedMs = (CFAbsoluteTimeGetCurrent() - t2) * 1000.0
        try require(cachedMs < 5.0, "Cached code highlight took \(String(format: "%.2f", cachedMs)) ms")
        print(String(format: "PASS polish checks: quit/teardown UAF regression, Dock reopen, window minSize, dynamic About version, multi-selection Style + Mixed/Undo, NSCursor, narrow 720x520 zero-overlap overlays, and lazy highlighter (init=%.2fms, firstLight=%.1fms, cached=%.2fms)", initMs, firstLightMs, cachedMs))
    }
}

/// Renders real showcase PNG bitmaps (UI windows at narrow 720x520, default 1000x700, 2x Retina,
/// Welcome window, Shortcuts sheet, and light/dark Keynote PNG exports) for visual inspection.
@MainActor
func renderShowcaseArtifacts(repository: URL, outputDir: URL) throws {
    let app = NSApplication.shared
    let previousAppearance = app.appearance
    app.appearance = NSAppearance(named: .aqua)
    defer { app.appearance = previousAppearance }

    let fm = FileManager.default
    try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

    func saveBitmap(_ view: NSView, scale: CGFloat = 1.0, to filename: String) throws {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let pxW = max(1, Int((bounds.width * scale).rounded()))
        let pxH = max(1, Int((bounds.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxW,
            pixelsHigh: pxH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw CheckFailure(description: "Could not allocate bitmap for \(filename)")
        }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw CheckFailure(description: "Could not encode PNG for \(filename)")
        }
        try png.write(to: outputDir.appendingPathComponent(filename), options: .atomic)
    }

    func compositeSlide(transparentPNG: Data, background: NSColor, to filename: String) throws {
        guard let img = NSImage(data: transparentPNG),
              let srcRep = NSBitmapImageRep(data: transparentPNG) else {
            throw CheckFailure(description: "Could not decode transparent PNG for \(filename)")
        }
        let w = srcRep.pixelsWide
        let h = srcRep.pixelsHigh
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w,
            pixelsHigh: h,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            throw CheckFailure(description: "Could not create slide composite context for \(filename)")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        background.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CheckFailure(description: "Could not encode composite slide PNG for \(filename)")
        }
        try data.write(to: outputDir.appendingPathComponent(filename), options: .atomic)
    }

    // 1. Render Welcome window (with 3 recent items) at 2x Retina
    let recentStore = CanvasRecentDocumentsStore(defaultsKey: "local.elixircanvas.showcase.\(UUID().uuidString)")
    defer { recentStore.clear() }
    for rel in ["examples/welcome.karton", "examples/kitchensink.karton", "shared/fixtures/v2/code-compatibility.json"] {
        recentStore.record(repository.appendingPathComponent(rel))
    }
    let delegate = CanvasAppDelegate(recentDocumentsStore: recentStore)
    delegate.persistsWindowFrameSize = false
    delegate.showWelcome()
    if let welcomeWin = NSApp.windows.first(where: { $0.contentView is WelcomeContentView }),
       let content = welcomeWin.contentView {
        try saveBitmap(content, scale: 2.0, to: "01-welcome-2x.png")
    }
    delegate.closeAllWindows()

    // 2. Render Shortcuts Sheet at 2x Retina
    let shortcuts = CanvasShortcutsSheet {}
    if let content = shortcuts.panel.contentView {
        try saveBitmap(content, scale: 2.0, to: "02-shortcuts-sheet-2x.png")
    }

    // 3. Render showcase documents at narrow (720x520), default (1000x700), Retina 2x, plus Keynote light & dark PNGs
    let sources: [(name: String, relPath: String, withOverlays: Bool)] = [
        ("v1-compatibility", "shared/fixtures/v1/compatibility.json", true),
        ("v2-code-compatibility", "shared/fixtures/v2/code-compatibility.json", true),
        ("welcome-example", "examples/welcome.karton", false),
        ("kitchensink-example", "examples/kitchensink.karton", false),
    ]

    for source in sources {
        let srcURL = repository.appendingPathComponent(source.relPath)
        let copyURL = outputDir.appendingPathComponent("\(source.name)-copy.json")
        try Data(contentsOf: srcURL).write(to: copyURL)
        let doc = try CanvasDocument(data: try Data(contentsOf: copyURL))
        let session = CanvasSession(document: doc)

        for (sizeLabel, size, scale) in [
            ("narrow-720x520", NSSize(width: 720, height: 520), CGFloat(1.0)),
            ("default-1000x700", NSSize(width: 1000, height: 700), CGFloat(1.0)),
            ("retina-1000x700-2x", NSSize(width: 1000, height: 700), CGFloat(2.0)),
        ] {
            let view = CanvasView(session: session)
            view.isToolDockVisible = true
            let scroll = NSScrollView(frame: NSRect(origin: .zero, size: size))
            scroll.drawsBackground = true
            scroll.backgroundColor = CanvasTheme.canvasBackground
            scroll.documentView = view
            let win = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.isReleasedWhenClosed = false
            win.contentView = scroll
            view.zoomToFit(nil)
            if source.withOverlays && sizeLabel == "narrow-720x520" {
                view.selectAll(nil)
                view.showStyleInspector(nil)
                view.statusBanner.configure(kind: .readOnly("Read-only preview check on narrow window"))
            } else if source.name == "v2-code-compatibility" && sizeLabel == "default-1000x700" {
                view.showStyleInspector(nil)
            }
            view.positionAllOverlays()
            try saveBitmap(scroll, scale: scale, to: "\(source.name)-\(sizeLabel).png")
            win.orderOut(nil)
            win.close()
        }

        // Keynote light & dark transparent PNG exports + composited slide previews
        let exportView = CanvasView(session: session)
        let lightPNG = try exportView.exportPNGData(sizing: .longestSide(1200), theme: .light, scope: .entireCanvas)
        let darkPNG = try exportView.exportPNGData(sizing: .longestSide(1200), theme: .dark, scope: .entireCanvas)
        try lightPNG.write(to: outputDir.appendingPathComponent("\(source.name)-keynote-light.png"), options: .atomic)
        try darkPNG.write(to: outputDir.appendingPathComponent("\(source.name)-keynote-dark.png"), options: .atomic)
        try compositeSlide(
            transparentPNG: lightPNG,
            background: CanvasTheme.canvasBackground,
            to: "\(source.name)-slide-light-composite.png"
        )
        try compositeSlide(
            transparentPNG: darkPNG,
            background: CanvasTheme.darkCanvasBackground,
            to: "\(source.name)-slide-dark-composite.png"
        )
    }

    // 4. Render CodeSnippetEditorView open inside narrow 720x520 window
    do {
        let v2Doc = try CanvasDocument(data: try Data(contentsOf: repository.appendingPathComponent("shared/fixtures/v2/code-compatibility.json")))
        let session = CanvasSession(document: v2Doc)
        let view = CanvasView(session: session)
        view.isToolDockVisible = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        scroll.documentView = view
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.contentView = scroll
        view.zoomToFit(nil)
        view.beginNewCodeBlock()
        if let editor = view.activeCodeEditor {
            editor.sourceTextView.string = "defmodule Showcase do\n  def greet(name), do: \"Hello, #{name}!\"\nend"
            editor.selectLanguage("auto")
        }
        view.positionAllOverlays()
        try saveBitmap(scroll, scale: 2.0, to: "03-code-editor-narrow-720x520-2x.png")
        view.cancelCodeEditor()
        win.orderOut(nil)
        win.close()
    }

    // 5. Render About Karton window at 2x
    do {
        let aboutRect = NSRect(x: 0, y: 0, width: 360, height: 278)
        let aboutView = AboutContentView(frame: aboutRect, versionLabel: "Karton 1.0 (1)")
        let win = NSWindow(
            contentRect: aboutRect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.appearance = NSAppearance(named: .aqua)
        win.isReleasedWhenClosed = false
        win.contentView = aboutView
        try saveBitmap(aboutView, scale: 2.0, to: "04-about-2x.png")
        win.orderOut(nil)
        win.close()
    }

    // 6. Render single-node Style Inspector (showing 10-swatch Fill row + swatch/glyph popups) at 2x
    do {
        let welcomeDoc = try CanvasDocument(data: try Data(contentsOf: repository.appendingPathComponent("examples/welcome.karton")))
        let session = CanvasSession(document: welcomeDoc)
        let view = CanvasView(session: session)
        view.isToolDockVisible = true
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        scroll.documentView = view
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.appearance = NSAppearance(named: .aqua)
        win.isReleasedWhenClosed = false
        win.contentView = scroll
        view.zoomToFit(nil)
        if let firstNodeID = (session.root["nodes"] as? [[String: Any]])?.first?["id"] as? String {
            view.selectNode(firstNodeID)
        }
        view.showStyleInspector(nil)
        view.positionAllOverlays()
        try saveBitmap(scroll, scale: 2.0, to: "05-style-inspector-single-2x.png")
        win.orderOut(nil)
        win.close()
    }

    print("Rendered showcase artifacts into \(outputDir.path)")
}
