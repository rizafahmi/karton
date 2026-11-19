import AppKit
import CanvasCore
import CoreFoundation

// Coordinates in the document, including text overflow and connector routing, are
// kept separate from view coordinates so negative positions remain scrollable.
public final class CanvasView: NSView {
    private struct Node {
        let id: String
        let type: String
        var box: CGRect
        var data: [String: Any]
        var kind: String { data["kind"] as? String ?? "rect" }
        var rotation: CGFloat { number(data["rotation"], 0) }
        var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }
        var geometry: CanvasGeometry {
            CanvasGeometry(x: box.minX, y: box.minY, width: box.width, height: box.height,
                           rotation: (data["rotation"] as? NSNumber)?.doubleValue)
        }
        var lineGeometry: CanvasLineGeometry? {
            guard type == "shape-line",
                  let from = data["from"] as? [Any], from.count == 2,
                  let to = data["to"] as? [Any], to.count == 2 else { return nil }
            return CanvasLineGeometry(
                x: box.minX, y: box.minY, width: box.width, height: box.height,
                from: CanvasPosition(x: Double(number(from[0])), y: Double(number(from[1]))),
                to: CanvasPosition(x: Double(number(to[0])), y: Double(number(to[1]))),
                rotation: (data["rotation"] as? NSNumber)?.doubleValue
            )
        }
    }

    private struct EdgeDrawing {
        let id: String
        let source: String
        let target: String
        let path: NSBezierPath
        let samples: [CGPoint]
        let end: CGPoint
        let previous: CGPoint
        let label: String
        let labelPoint: CGPoint
        let labelRect: CGRect?
        let style: [String: Any]
        let marker: String
        let animated: Bool
    }

    private final class ThoughtDraftTextView: NSTextView {
        private let draftUndoManager = UndoManager()
        override var undoManager: UndoManager? { draftUndoManager }
        var onCommit: (() -> Void)?
        var onCancel: (() -> Void)?
        var onChange: ((String) -> Void)?

        func resetUndo() {
            draftUndoManager.removeAllActions()
        }
        override var string: String {
            didSet {
                onChange?(string)
            }
        }

        override func didChangeText() {
            super.didChangeText()
            onChange?(string)
        }

        override func keyDown(with event: NSEvent) {
            if !hasMarkedText() {
                if event.keyCode == 53 {
                    onCancel?()
                    return
                }
                if event.keyCode == 36 || event.keyCode == 76 {
                    if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                        insertNewlineIgnoringFieldEditor(nil)
                    } else {
                        onCommit?()
                    }
                    return
                }
            }
            super.keyDown(with: event)
        }
    }

    private enum InlineTextState {
        case adjacentChoosing(sourceID: String)
        case adjacentEditing(sourceID: String, direction: CanvasThoughtDirection, geometry: CanvasGeometry, text: String, error: String?)
        case newText(position: CanvasPosition, geometry: CanvasGeometry, text: String, error: String?)
        case shapeCaption(id: String, beforeText: String?, beforeGeometry: CanvasGeometry, previewGeometry: CanvasGeometry, text: String, error: String?)
    }

    private struct MarqueeGesture {
        let start: CGPoint
        var current: CGPoint
        let baseSelection: Set<String>

        var worldRect: CGRect {
            CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
        }
    }

    private enum ConnectionDragMode: Equatable {
        case create(sourceID: String, sourceSide: CanvasConnectionSide?)
        case reconnect(edgeID: String, draggingTarget: Bool)
    }

    private struct ConnectionDropTarget: Equatable {
        let nodeID: String
        let side: CanvasConnectionSide?
    }

    private struct ConnectionDragGesture {
        let mode: ConnectionDragMode
        let startPoint: CGPoint
        var currentPoint: CGPoint
        var hasDragged: Bool = false
        var target: ConnectionDropTarget?
    }

    private struct CreationDragGesture {
        let tool: CanvasCreationTool
        let startPoint: CGPoint
        var currentPoint: CGPoint
        var hasDragged: Bool = false
    }

    private var nodes: [Node]
    private var edges: [EdgeDrawing]
    private var paper: [String: Any]
    private var fontRole: String
    private var defaultAlign: String?
    private var origin: CGPoint
    public private(set) var zoomScale: CGFloat = 1.0
    private let session: CanvasSession
    private let history: UndoManager
    public override var undoManager: UndoManager? { history }
    private var selectedID: String?
    public private(set) var selectedNodeIDs: Set<String> = []
    private var selectedEdgeID: String?
    public private(set) var focusedNodeID: String?
    public private(set) var focusedConnectionID: String?
    private var spaceSelectionMode = false
    private var isSpacePressed = false
    private var spacePanDragged = false
    private var spacePanStart: (viewportPoint: CGPoint, worldOrigin: CGPoint)?
    private var marqueeGesture: MarqueeGesture?
    private var drag: (
        ids: [String],
        mouse: CGPoint,
        positions: [String: CanvasPosition],
        currentPositions: [String: CanvasPosition]
    )? {
        didSet { onDraftStateDidChange?() }
    }
    private var connectionDrag: ConnectionDragGesture? {
        didSet { onDraftStateDidChange?() }
    }
    private var hoveredNodeID: String?
    private var connectionEditor: ConnectionEditor?
    private var attachmentPreview: AttachmentPreviewSheet?
    public var attachmentPasteboard: NSPasteboard = .general
    public static let clipboardPasteboardType = NSPasteboard.PasteboardType("local.elixircanvas.native.clipboard")
    private var pngExportSheet: PNGExportSheet?
    public var pngExportDestinationProvider: ((String) -> URL?)?
    public var onDraftStateDidChange: (() -> Void)?
    private var geometryGesture: GeometryGesture? {
        didSet { onDraftStateDidChange?() }
    }
    private var lineEndpointGesture: LineEndpointGesture? {
        didSet { onDraftStateDidChange?() }
    }
    private var inlineTextState: InlineTextState? {
        didSet { onDraftStateDidChange?() }
    }
    private let thoughtScrollView = NSScrollView()
    private let thoughtInputView = ThoughtDraftTextView(frame: NSRect(x: 0, y: 0, width: 160, height: 96))
    public let styleInspector = StyleInspectorView()
    public private(set) var isStyleInspectorOpen = false
    public let toolDock = CanvasToolDockView()
    public let alignBar = CanvasAlignBarView()
    public var isToolDockVisible: Bool = false {
        didSet {
            toolDock.isHidden = !isToolDockVisible
            refreshToolDock()
            positionToolDock()
            positionAlignBar()
            needsDisplay = true
        }
    }
    public let statusBanner = CanvasStatusBannerView()
    public private(set) var activeCreationTool: CanvasCreationTool = .select {
        didSet {
            refreshToolDock()
            needsDisplay = true
        }
    }
    private var creationDrag: CreationDragGesture? {
        didSet { onDraftStateDidChange?() }
    }
    private var shortcutsSheet: CanvasShortcutsSheet?
    public var isShortcutsSheetOpen: Bool { shortcutsSheet != nil }
    public var activeShortcutsPanel: NSPanel? { shortcutsSheet?.panel }
    public var selectedNodeID: String? { selectedID }
    public var isReadOnly: Bool { session.isReadOnly }
    public var selectedConnectionID: String? { selectedEdgeID }
    public var hasGeometryPreview: Bool { geometryGesture != nil || lineEndpointGesture != nil }
    public var hasActiveInlineTextEditor: Bool {
        switch inlineTextState {
        case .adjacentEditing, .newText, .shapeCaption: return true
        case .adjacentChoosing, .none: return false
        }
    }
    public var hasActivePointerDrag: Bool {
        guard let drag else { return false }
        return drag.currentPositions != drag.positions
    }
    public var hasActiveConnectionDrag: Bool { connectionDrag != nil }
    public var hasActiveCreationDrag: Bool { creationDrag != nil }
    public var hasPendingDraftOrPreview: Bool {
        hasActiveInlineTextEditor || isChoosingAdjacentThoughtDirection || hasGeometryPreview || hasActivePointerDrag || hasActiveConnectionDrag || hasActiveCreationDrag
    }
    public var recoverableTextDraft: CanvasRecoverableTextDraft? {
        guard !thoughtInputView.hasMarkedText() else { return nil }
        switch inlineTextState {
        case .adjacentEditing(let sourceID, let direction, let geo, let text, _):
            return .adjacentEditing(sourceID: sourceID, direction: direction, geometry: geo, text: text)
        case .newText(let position, let geo, let text, _):
            return .newText(position: position, geometry: geo, text: text)
        case .shapeCaption(let id, let beforeText, let beforeGeo, let previewGeo, let text, _):
            return .shapeCaption(
                id: id,
                beforeText: beforeText,
                beforeGeometry: beforeGeo,
                previewGeometry: previewGeo,
                text: text
            )
        case .adjacentChoosing, .none:
            return nil
        }
    }
    public var inlineTextEditorView: NSTextView? {
        hasActiveInlineTextEditor ? thoughtInputView : nil
    }
    public var inlineTextError: String? {
        switch inlineTextState {
        case .adjacentEditing(_, _, _, _, let err),
             .newText(_, _, _, let err),
             .shapeCaption(_, _, _, _, _, let err):
            return err
        case .adjacentChoosing, .none:
            return nil
        }
    }
    public var hasAdjacentThoughtPreview: Bool {
        switch inlineTextState {
        case .adjacentChoosing, .adjacentEditing: return true
        case .newText, .shapeCaption, .none: return false
        }
    }
    public var isChoosingAdjacentThoughtDirection: Bool {
        if case .adjacentChoosing = inlineTextState { return true }
        return false
    }
    public var hasAdjacentThoughtDraft: Bool {
        if case .adjacentEditing = inlineTextState { return true }
        return false
    }
    public var adjacentThoughtDraftGeometry: CanvasGeometry? {
        if case .adjacentEditing(_, _, let geo, _, _) = inlineTextState { return geo }
        return nil
    }
    public var adjacentThoughtDraftText: String? {
        if case .adjacentEditing(_, _, _, let text, _) = inlineTextState { return text }
        return nil
    }
    public var adjacentThoughtError: String? {
        if case .adjacentEditing(_, _, _, _, let error) = inlineTextState { return error }
        return nil
    }
    public var adjacentThoughtTextView: NSTextView? {
        hasAdjacentThoughtDraft ? thoughtInputView : nil
    }
    public var visibleWorldRect: CGRect {
        let rect = visibleRect.width > 0 ? visibleRect : bounds
        return CGRect(
            x: rect.minX / zoomScale + origin.x,
            y: rect.minY / zoomScale + origin.y,
            width: rect.width / zoomScale,
            height: rect.height / zoomScale
        )
    }
    public var canInsertAdjacentThought: Bool {
        !hasGeometryPreview && inlineTextState == nil && drag == nil && adjacentThoughtSourceID != nil
    }
    private var adjacentThoughtSourceID: String? {
        guard selectedEdgeID == nil, focusedConnectionID == nil else { return nil }
        if spaceSelectionMode, let focusedID = focusedNodeID {
            return session.canInsertAdjacentThought(from: focusedID) ? focusedID : nil
        }
        guard selectedNodeIDs.count <= 1,
              let id = selectedID ?? focusedNodeID else { return nil }
        return session.canInsertAdjacentThought(from: id) ? id : nil
    }
    public var canEditGeometry: Bool {
        guard selectedNodeIDs.count <= 1, inlineTextState == nil else { return false }
        return selectedID.map { session.canTransform($0) || session.canEditLineEndpoints($0) } ?? false
    }
    public var canInsertConnection: Bool {
        !isReadOnly && nodes.contains { $0.type != "shape-line" }
    }
    public var canEditTextSelection: Bool {
        !hasGeometryPreview && inlineTextState == nil && drag == nil &&
            selectedNodeIDs.count <= 1 && (selectedID.map { session.canEditText($0) } ?? false)
    }
    public var canPreviewAttachment: Bool {
        !hasGeometryPreview && inlineTextState == nil && drag == nil &&
            selectedNodeIDs.count <= 1 && (selectedID.map { session.attachment(of: $0) != nil } ?? false)
    }
    public var canEditConnectionSelection: Bool {
        !hasGeometryPreview && inlineTextState == nil && drag == nil && canInsertConnection &&
            (selectedEdgeID.map { session.hasConnection($0) } ?? false)
    }
    public var canExportPNG: Bool {
        drag == nil && connectionDrag == nil && creationDrag == nil &&
            connectionEditor == nil && attachmentPreview == nil && pngExportSheet == nil && shortcutsSheet == nil &&
            (!nodes.isEmpty || hasActiveInlineTextEditor)
    }
    public var isPNGExportSheetOpen: Bool { pngExportSheet != nil }
    public var activePNGExportPanel: NSPanel? { pngExportSheet?.panel }
    private var orderedSelectedNodeIDs: [String] {
        let set = selectedNodeIDs.isEmpty ? (selectedID.map { Set([$0]) } ?? []) : selectedNodeIDs
        return nodes.map(\.id).filter { set.contains($0) }
    }
    private var orderedUnlockedSelectedNodeIDs: [String] {
        orderedSelectedNodeIDs.filter { !session.isLocked($0) }
    }
    public var canCopySelection: Bool {
        !hasGeometryPreview && inlineTextState == nil && drag == nil &&
            connectionEditor == nil && attachmentPreview == nil && pngExportSheet == nil &&
            !orderedSelectedNodeIDs.isEmpty
    }
    public var canCutSelection: Bool {
        !isReadOnly && !hasGeometryPreview && inlineTextState == nil && drag == nil &&
            connectionEditor == nil && attachmentPreview == nil && pngExportSheet == nil &&
            !orderedUnlockedSelectedNodeIDs.isEmpty
    }
    public var canPaste: Bool {
        guard !isReadOnly, !hasGeometryPreview, inlineTextState == nil, drag == nil,
              connectionEditor == nil, attachmentPreview == nil, pngExportSheet == nil,
              let data = attachmentPasteboard.data(forType: Self.clipboardPasteboardType),
              (try? CanvasClipboardPayload.decode(from: data)) != nil else {
            return false
        }
        return true
    }
    public var canSelectAll: Bool {
        !hasGeometryPreview && inlineTextState == nil && drag == nil &&
            connectionEditor == nil && attachmentPreview == nil && pngExportSheet == nil &&
            !nodes.isEmpty
    }
    public var canDeleteSelection: Bool {
        guard !isReadOnly, !hasGeometryPreview, inlineTextState == nil, drag == nil else { return false }
        if !selectedNodeIDs.isEmpty {
            return selectedNodeIDs.contains { session.canDeleteNode($0) }
        }
        if let id = selectedID { return session.canDeleteNode(id) }
        if let edgeID = selectedEdgeID { return session.hasConnection(edgeID) }
        return false
    }
    public var canDuplicateSelection: Bool {
        guard !isReadOnly, !hasGeometryPreview, inlineTextState == nil, drag == nil else { return false }
        if !selectedNodeIDs.isEmpty {
            return selectedNodeIDs.contains { session.canDuplicateNode($0) }
        }
        guard let id = selectedID else { return false }
        return session.canDuplicateNode(id)
    }
    public var canBringToFront: Bool {
        guard !isReadOnly, !hasGeometryPreview, inlineTextState == nil, drag == nil else { return false }
        if selectedNodeIDs.count > 1 {
            let unlocked = nodes.map(\.id).filter { selectedNodeIDs.contains($0) && !session.isLocked($0) }
            guard !unlocked.isEmpty else { return false }
            let tail = Array(nodes.map(\.id).suffix(unlocked.count))
            return tail != unlocked
        }
        guard let id = selectedID else { return false }
        return session.canBringToFront(id)
    }
    public var canSendToBack: Bool {
        guard !isReadOnly, !hasGeometryPreview, inlineTextState == nil, drag == nil else { return false }
        if selectedNodeIDs.count > 1 {
            let unlocked = nodes.map(\.id).filter { selectedNodeIDs.contains($0) && !session.isLocked($0) }
            guard !unlocked.isEmpty else { return false }
            let head = Array(nodes.map(\.id).prefix(unlocked.count))
            return head != unlocked
        }
        guard let id = selectedID else { return false }
        return session.canSendToBack(id)
    }
    public func canAlign(_ alignment: CanvasAlignment) -> Bool {
        guard !isReadOnly, !hasGeometryPreview, inlineTextState == nil, drag == nil else { return false }
        return session.canAlignNodes(orderedSelectedNodeIDs, alignment: alignment)
    }
    public var canAlignSelection: Bool {
        canAlign(.left)
    }
    public var canDistributeSelection: Bool {
        canAlign(.distributeHorizontally)
    }
    public var canToggleLock: Bool {
        !isReadOnly && !hasGeometryPreview && inlineTextState == nil && drag == nil && selectedID != nil
    }
    public var isSelectedNodeLocked: Bool {
        selectedID.map { session.isLocked($0) } ?? false
    }
    public override var isFlipped: Bool { true }

    public convenience init(document: CanvasDocument) {
        self.init(session: CanvasSession(document: document))
    }

    public init(session: CanvasSession, undoManager: UndoManager = UndoManager()) {
        let root = session.root
        let nodes = (root["nodes"] as? [[String: Any]] ?? []).map { raw in
            Node(id: raw["id"] as? String ?? "", type: raw["type"] as? String ?? "shape",
                 box: CGRect(x: number(raw["x"]), y: number(raw["y"]),
                             width: number(raw["width"]), height: number(raw["height"])),
                 data: raw["data"] as? [String: Any] ?? [:])
        }
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let appearance = root["appearance"] as? [String: Any]
        let role = appearance?["font"] as? String ?? "sans"
        let defaultAlign = appearance?["align"] as? String
        let edges = (root["edges"] as? [[String: Any]] ?? []).compactMap { raw -> EdgeDrawing? in
            guard let source = index[raw["source"] as? String ?? ""],
                  let target = index[raw["target"] as? String ?? ""] else { return nil }
            return Self.makeEdge(raw, source, target, role: role)
        }
        var bounds = CGRect.null
        for node in nodes {
            // Include rotated corners and the full laid-out text, not just the authored box.
            let textRect = Self.textRect(node, role: role)
            let local = node.box.union(textRect)
            let radius = hypot(max(abs(local.minX - node.center.x), abs(local.maxX - node.center.x)),
                               max(abs(local.minY - node.center.y), abs(local.maxY - node.center.y)))
            bounds = bounds.union(CGRect(x: node.center.x - radius, y: node.center.y - radius,
                                         width: radius * 2, height: radius * 2))
        }
        for edge in edges {
            bounds = bounds.union(edge.path.bounds.insetBy(dx: -20, dy: -20))
            if !edge.label.isEmpty {
                let size = Self.labelSize(edge.label, role: role)
                bounds = bounds.union(CGRect(x: edge.labelPoint.x - size.width / 2, y: edge.labelPoint.y - size.height / 2, width: size.width, height: size.height))
            }
        }
        if bounds.isNull { bounds = CGRect(x: 0, y: 0, width: 800, height: 600) }
        bounds = bounds.insetBy(dx: -80, dy: -80)
        self.nodes = nodes
        self.edges = edges
        self.paper = root["paper"] as? [String: Any] ?? [:]
        self.fontRole = role
        self.defaultAlign = defaultAlign
        self.session = session
        self.history = undoManager
        self.origin = bounds.origin
        let size = CGSize(width: max(800, bounds.width), height: max(600, bounds.height))
        super.init(frame: CGRect(origin: .zero, size: size))
        history.groupsByEvent = false
        thoughtScrollView.hasVerticalScroller = true
        thoughtScrollView.autohidesScrollers = true
        thoughtScrollView.borderType = .noBorder
        thoughtScrollView.drawsBackground = false
        thoughtScrollView.isHidden = true
        thoughtInputView.isRichText = false
        thoughtInputView.allowsUndo = true
        thoughtInputView.drawsBackground = false
        thoughtInputView.isAutomaticQuoteSubstitutionEnabled = false
        thoughtInputView.isAutomaticDashSubstitutionEnabled = false
        thoughtInputView.isAutomaticTextReplacementEnabled = false
        thoughtInputView.font = font(role, "m")
        thoughtInputView.alignment = alignment(defaultAlign ?? "center")
        thoughtInputView.textColor = CanvasTheme.primaryText
        thoughtInputView.insertionPointColor = CanvasTheme.primaryText
        thoughtInputView.minSize = .zero
        thoughtInputView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        thoughtInputView.textContainerInset = NSSize(width: 8, height: 8)
        thoughtInputView.isVerticallyResizable = false
        thoughtInputView.isHorizontallyResizable = false
        thoughtInputView.autoresizingMask = [.width]
        thoughtInputView.textContainer?.widthTracksTextView = true
        thoughtInputView.textContainer?.lineFragmentPadding = 0
        thoughtInputView.setAccessibilityLabel("Canvas text editor")
        thoughtInputView.onCommit = { [weak self] in self?.commitInlineText() }
        thoughtInputView.onCancel = { [weak self] in self?.cancelInlineText() }
        thoughtInputView.onChange = { [weak self] updated in self?.updateInlineText(updated) }
        thoughtScrollView.documentView = thoughtInputView
        addSubview(thoughtScrollView)
        styleInspector.isHidden = true
        styleInspector.onSelectStyle = { [weak self] property, value in
            try self?.applyStyle(property, to: value)
        }
        styleInspector.onAlign = { [weak self] alignment in
            self?.alignSelection(alignment)
        }
        styleInspector.onClose = { [weak self] in
            self?.closeStyleInspector(nil)
        }
        addSubview(styleInspector)
        toolDock.isHidden = true
        toolDock.onSelectTool = { [weak self] tool in
            self?.activateToolFromDock(tool)
        }
        toolDock.onConnect = { [weak self] in
            self?.beginConnection()
        }
        toolDock.onAdjacentThought = { [weak self] in
            self?.beginAdjacentThought()
        }
        toolDock.onToggleStyle = { [weak self] in
            self?.toggleStyleInspector(nil)
        }
        toolDock.onExportPNG = { [weak self] in
            self?.beginPNGExport()
        }
        toolDock.onShowShortcuts = { [weak self] in
            self?.beginShortcutsHelp()
        }
        addSubview(toolDock)
        alignBar.isHidden = true
        alignBar.onAlign = { [weak self] alignment in
            self?.alignSelection(alignment)
        }
        addSubview(alignBar)
        statusBanner.isHidden = true
        addSubview(statusBanner)
    }

    public required init?(coder: NSCoder) { fatalError("CanvasView requires a document") }

    public override var acceptsFirstResponder: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        CanvasTheme.canvasBackground.setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.scaleBy(x: zoomScale, y: zoomScale)
        context.translateBy(x: -origin.x, y: -origin.y)
        let worldDirty = CGRect(
            x: dirtyRect.minX / zoomScale + origin.x,
            y: dirtyRect.minY / zoomScale + origin.y,
            width: dirtyRect.width / zoomScale,
            height: dirtyRect.height / zoomScale
        )
        drawPaper(worldDirty)
        let reconnectingEdgeID: String?
        if case .reconnect(let eid, _) = connectionDrag?.mode {
            reconnectingEdgeID = eid
        } else {
            reconnectingEdgeID = nil
        }
        for edge in edges where edge.id != reconnectingEdgeID {
            Self.drawEdge(edge, role: fontRole, isSelected: edge.id == selectedEdgeID)
        }
        for node in nodes {
            let isEditingCaption: Bool
            if case .shapeCaption(let editingID, _, _, _, _, _) = inlineTextState, editingID == node.id {
                isEditingCaption = true
            } else {
                isEditingCaption = false
            }
            Self.drawNode(node, role: fontRole, defaultAlign: defaultAlign, hideCaption: isEditingCaption)
        }
        if selectedNodeIDs.count > 1 {
            for node in nodes where selectedNodeIDs.contains(node.id) {
                drawMultiSelectionOutline(node, isFocused: node.id == focusedNodeID)
            }
        } else if let selectedID, let node = nodes.first(where: { $0.id == selectedID }) {
            drawSelection(node)
        }
        if connectionDrag == nil, !isReadOnly, !hasGeometryPreview, inlineTextState == nil, drag == nil,
           let hid = hoveredNodeID, hid != selectedID,
           let hoverNode = nodes.first(where: { $0.id == hid }), hoverNode.type != "shape-line" {
            drawConnectionPorts(for: hoverNode, activeSide: nil)
        }
        if spaceSelectionMode, let focusedID = focusedNodeID, !selectedNodeIDs.contains(focusedID),
           let node = nodes.first(where: { $0.id == focusedID }) {
            drawFocusedNodeOutline(node)
        }
        if let marquee = marqueeGesture, marquee.worldRect.width > 0 || marquee.worldRect.height > 0 {
            let rect = marquee.worldRect
            CanvasTheme.selectionCobalt.withAlphaComponent(0.12).setFill()
            rect.fill()
            let border = NSBezierPath(rect: rect)
            CanvasTheme.selectionCobalt.setStroke()
            border.lineWidth = 1 / zoomScale
            border.stroke()
        }
        if let activeConnDrag = connectionDrag {
            drawConnectionDragPreview(activeConnDrag)
        }
        if let activeCreation = creationDrag {
            drawCreationDragPreview(activeCreation)
        }
        if let inlineTextState {
            drawInlineTextPreview(inlineTextState)
        }
        context.restoreGState()
        if let geometryGesture { drawGeometryHelp(geometryGesture.handle) }
        if let lineEndpointGesture { drawLineEndpointHelp(lineEndpointGesture.endpoint) }
        if connectionDrag != nil {
            drawHelpBanner("Drag to an object or side port to connect · Release to commit · Escape: cancel")
        } else if activeCreationTool != .select {
            drawHelpBanner(activeCreationTool.helpBannerText)
        }
        if let inlineTextState { drawInlineTextHelp(inlineTextState) }
        positionInlineTextEditor()
        positionStyleInspector()
        positionToolDock()
        positionAlignBar()
        positionStatusBanner()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    public override func mouseMoved(with event: NSEvent) {
        guard !isReadOnly, !hasGeometryPreview, inlineTextState == nil, drag == nil, connectionDrag == nil else {
            if hoveredNodeID != nil {
                hoveredNodeID = nil
                needsDisplay = true
            }
            return
        }
        let point = worldPoint(for: event)
        let hitID = nodes.reversed().first(where: { node in
            guard node.type != "shape-line" else { return false }
            return containsNearNode(point, node: node, padding: 20) || connectionPort(at: point, node: node) != nil
        })?.id
        if hitID != hoveredNodeID {
            hoveredNodeID = hitID
            needsDisplay = true
        }
    }

    public override func mouseExited(with event: NSEvent) {
        if hoveredNodeID != nil {
            hoveredNodeID = nil
            needsDisplay = true
        }
    }

    public override func mouseDown(with event: NSEvent) {
        if inlineTextState != nil {
            guard finishInlineTextBeforeCanvasAction() else { return }
        }
        window?.makeFirstResponder(self)
        if isSpacePressed {
            let clipOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
            let viewPt = convert(event.locationInWindow, from: nil)
            let viewportPt = CGPoint(x: viewPt.x - clipOrigin.x, y: viewPt.y - clipOrigin.y)
            spacePanStart = (viewportPoint: viewportPt, worldOrigin: visibleWorldRect.origin)
            spacePanDragged = false
            return
        }
        let point = worldPoint(for: event)
        if activeCreationTool != .select {
            guard !isReadOnly else {
                activeCreationTool = .select
                NSSound.beep()
                return
            }
            cancelGeometry()
            creationDrag = CreationDragGesture(
                tool: activeCreationTool,
                startPoint: point,
                currentPoint: point,
                hasDragged: false
            )
            drag = nil
            marqueeGesture = nil
            connectionDrag = nil
            needsDisplay = true
            return
        }
        if !isReadOnly {
            if let edgeID = selectedEdgeID,
               let edge = edges.first(where: { $0.id == edgeID }) {
                let startPt = edge.samples.first ?? edge.end
                let endPt = edge.end
                if hypot(point.x - endPt.x, point.y - endPt.y) < 12.0 {
                    connectionDrag = ConnectionDragGesture(
                        mode: .reconnect(edgeID: edgeID, draggingTarget: true),
                        startPoint: point,
                        currentPoint: point,
                        target: nil
                    )
                    drag = nil
                    marqueeGesture = nil
                    needsDisplay = true
                    return
                }
                if hypot(point.x - startPt.x, point.y - startPt.y) < 12.0 {
                    connectionDrag = ConnectionDragGesture(
                        mode: .reconnect(edgeID: edgeID, draggingTarget: false),
                        startPoint: point,
                        currentPoint: point,
                        target: nil
                    )
                    drag = nil
                    marqueeGesture = nil
                    needsDisplay = true
                    return
                }
            }
        }
        if selectedNodeIDs.count <= 1, let id = selectedID, session.canTransform(id),
           let node = nodes.first(where: { $0.id == id }),
           let handle = geometryHandle(at: point, node: node) {
            var gesture = geometryGesture ?? GeometryGesture(id: id, geometry: node.geometry)
            gesture.startPointer(at: CanvasPosition(x: point.x, y: point.y), handle: handle)
            geometryGesture = gesture
            drag = nil
            marqueeGesture = nil
            needsDisplay = true
            return
        }
        if selectedNodeIDs.count <= 1, let id = selectedID, session.canEditLineEndpoints(id),
           let node = nodes.first(where: { $0.id == id }),
           let lineGeometry = node.lineGeometry,
           let endpoint = lineEndpointHandle(at: point, lineGeometry: lineGeometry) {
            var gesture = lineEndpointGesture ?? LineEndpointGesture(id: id, geometry: lineGeometry)
            gesture.startPointer(at: CanvasPosition(x: point.x, y: point.y), endpoint: endpoint)
            lineEndpointGesture = gesture
            drag = nil
            marqueeGesture = nil
            needsDisplay = true
            return
        }
        if !isReadOnly {
            if selectedNodeIDs.count <= 1, let id = selectedID,
               let node = nodes.first(where: { $0.id == id }),
               let side = connectionPort(at: point, node: node) {
                cancelGeometry()
                connectionDrag = ConnectionDragGesture(
                    mode: .create(sourceID: node.id, sourceSide: side),
                    startPoint: point,
                    currentPoint: point,
                    target: nil
                )
                drag = nil
                marqueeGesture = nil
                needsDisplay = true
                return
            }
            if let portHit = nodes.reversed().compactMap({ node -> (Node, CanvasConnectionSide)? in
                guard node.id != selectedID, let side = connectionPort(at: point, node: node) else { return nil }
                return (node, side)
            }).first {
                cancelGeometry()
                connectionDrag = ConnectionDragGesture(
                    mode: .create(sourceID: portHit.0.id, sourceSide: portHit.1),
                    startPoint: point,
                    currentPoint: point,
                    target: nil
                )
                drag = nil
                marqueeGesture = nil
                needsDisplay = true
                return
            }
            if event.modifierFlags.contains(.option),
               let hitNode = nodes.reversed().first(where: { $0.type != "shape-line" && contains(point, node: $0) }) {
                cancelGeometry()
                connectionDrag = ConnectionDragGesture(
                    mode: .create(sourceID: hitNode.id, sourceSide: nil),
                    startPoint: point,
                    currentPoint: point,
                    target: nil
                )
                drag = nil
                marqueeGesture = nil
                needsDisplay = true
                return
            }
        }
        cancelGeometry()
        let shift = event.modifierFlags.contains(.shift)
        if let hitNode = nodes.reversed().first(where: { contains(point, node: $0) }) {
            if shift {
                spaceSelectionMode = true
                if selectedNodeIDs.contains(hitNode.id) {
                    selectedNodeIDs.remove(hitNode.id)
                } else {
                    selectedNodeIDs.insert(hitNode.id)
                }
                selectedID = nodes.first(where: { selectedNodeIDs.contains($0.id) })?.id
                focusedNodeID = hitNode.id
                selectedEdgeID = nil
                focusedConnectionID = nil
            } else if !selectedNodeIDs.contains(hitNode.id) || selectedNodeIDs.count <= 1 {
                selectSingleNode(hitNode.id)
            } else {
                focusedNodeID = hitNode.id
            }
            marqueeGesture = nil
        } else if let hitEdge = edges.reversed().first(where: { contains(point, edge: $0) }) {
            selectSingleConnection(hitEdge.id)
            marqueeGesture = nil
        } else {
            if !shift {
                clearSelection()
            }
            marqueeGesture = MarqueeGesture(
                start: point,
                current: point,
                baseSelection: shift ? selectedNodeIDs : []
            )
        }
        drag = nil
        refreshStyleInspector()
        if event.clickCount == 2 {
            marqueeGesture = nil
            activatePrimaryEditor()
            needsDisplay = true
            return
        }
        if marqueeGesture == nil && !isReadOnly {
            let activeIDs = selectedNodeIDs.isEmpty ? (selectedID.map { [$0] } ?? []) : nodes.map(\.id).filter { selectedNodeIDs.contains($0) }
            let unlockedIDs = activeIDs.filter { !session.isLocked($0) }
            var initialPositions: [String: CanvasPosition] = [:]
            for id in unlockedIDs {
                if let pos = session.position(of: id) {
                    initialPositions[id] = pos
                }
            }
            if !initialPositions.isEmpty {
                drag = (ids: unlockedIDs, mouse: point, positions: initialPositions, currentPositions: initialPositions)
            }
        }
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        if let panStart = spacePanStart {
            spacePanDragged = true
            let clipOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
            let viewPt = convert(event.locationInWindow, from: nil)
            let viewportPt = CGPoint(x: viewPt.x - clipOrigin.x, y: viewPt.y - clipOrigin.y)
            let worldDX = (viewportPt.x - panStart.viewportPoint.x) / zoomScale
            let worldDY = (viewportPt.y - panStart.viewportPoint.y) / zoomScale
            setVisibleWorldOrigin(CGPoint(
                x: panStart.worldOrigin.x - worldDX,
                y: panStart.worldOrigin.y - worldDY
            ))
            return
        }
        if var activeCreation = creationDrag {
            let point = worldPoint(for: event)
            activeCreation.currentPoint = point
            if hypot(point.x - activeCreation.startPoint.x, point.y - activeCreation.startPoint.y) >= 8.0 {
                activeCreation.hasDragged = true
            }
            creationDrag = activeCreation
            needsDisplay = true
            return
        }
        if var activeConnDrag = connectionDrag {
            let point = worldPoint(for: event)
            activeConnDrag.currentPoint = point
            if hypot(point.x - activeConnDrag.startPoint.x, point.y - activeConnDrag.startPoint.y) >= 4.0 {
                activeConnDrag.hasDragged = true
                activeConnDrag.target = resolveConnectionDropTarget(at: point, for: activeConnDrag)
            } else {
                activeConnDrag.target = nil
            }
            connectionDrag = activeConnDrag
            needsDisplay = true
            return
        }
        if var gesture = geometryGesture, gesture.pointerStart != nil {
            let point = worldPoint(for: event)
            do {
                try gesture.drag(to: CanvasPosition(x: point.x, y: point.y))
                geometryGesture = gesture
                renderGeometry(gesture.id, geometry: gesture.current)
            } catch { NSSound.beep() }
            return
        }
        if var gesture = lineEndpointGesture, gesture.pointerStart != nil {
            let point = worldPoint(for: event)
            do {
                try gesture.drag(to: CanvasPosition(x: point.x, y: point.y))
                lineEndpointGesture = gesture
                renderLineGeometry(gesture.id, geometry: gesture.current)
            } catch { NSSound.beep() }
            return
        }
        if var marquee = marqueeGesture {
            let point = worldPoint(for: event)
            marquee.current = point
            marqueeGesture = marquee
            let rect = marquee.worldRect
            let hitIDs = nodes.filter { node in
                let b = node.geometry.rotatedAxisAlignedBounds
                return CGRect(x: b.x, y: b.y, width: b.width, height: b.height).intersects(rect)
            }.map(\.id)
            selectedNodeIDs = marquee.baseSelection.union(hitIDs)
            selectedID = nodes.first(where: { selectedNodeIDs.contains($0.id) })?.id
            selectedEdgeID = nil
            if selectedNodeIDs.count > 1 { spaceSelectionMode = true }
            refreshStyleInspector()
            needsDisplay = true
            return
        }
        guard var activeDrag = drag else { return }
        let point = worldPoint(for: event)
        let dx = Double(point.x - activeDrag.mouse.x)
        let dy = Double(point.y - activeDrag.mouse.y)
        var didPreviewMove = false
        for id in activeDrag.ids {
            guard let initial = activeDrag.positions[id],
                  !session.isLocked(id) else { continue }
            let position = CanvasPosition(x: initial.x + dx, y: initial.y + dy)
            guard position.x.isFinite, position.y.isFinite,
                  abs(position.x) <= 1_000_000, abs(position.y) <= 1_000_000,
                  let index = nodes.firstIndex(where: { $0.id == id }) else { continue }
            activeDrag.currentPositions[id] = position
            nodes[index].box.origin = CGPoint(x: position.x, y: position.y)
            didPreviewMove = true
        }
        self.drag = activeDrag
        if didPreviewMove {
            rebuildEdges()
            refreshAlignBar()
            needsDisplay = true
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if spacePanStart != nil {
            spacePanStart = nil
            return
        }
        if let activeCreation = creationDrag {
            let point = worldPoint(for: event)
            creationDrag = nil
            activeCreationTool = .select
            commitCreationDrag(activeCreation, at: point)
            return
        }
        if let activeConnDrag = connectionDrag {
            let point = worldPoint(for: event)
            connectionDrag = nil
            commitConnectionDrag(activeConnDrag, at: point)
            return
        }
        if geometryGesture?.pointerStart != nil {
            commitGeometry()
            return
        }
        if lineEndpointGesture?.pointerStart != nil {
            commitLineEndpoints()
            return
        }
        if marqueeGesture != nil {
            marqueeGesture = nil
            refreshStyleInspector()
            needsDisplay = true
            return
        }
        guard let activeDrag = drag else { return }
        self.drag = nil
        var changed: [String] = []
        for id in activeDrag.ids {
            guard let initial = activeDrag.positions[id],
                  let target = activeDrag.currentPositions[id],
                  target != initial else { continue }
            if (try? moveWithoutHistory(id, to: target)) != nil {
                changed.append(id)
            }
        }
        if !changed.isEmpty {
            registerUndoMoves(changed, to: activeDrag.positions)
            refreshAlignBar()
        } else {
            syncFromSession()
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        guard inlineTextState == nil, !hasGeometryPreview, window?.attachedSheet == nil,
              connectionEditor == nil, attachmentPreview == nil, pngExportSheet == nil else {
            return nil
        }
        let point = worldPoint(for: event)
        if let hitNode = nodes.reversed().first(where: { contains(point, node: $0) }) {
            if !selectedNodeIDs.contains(hitNode.id) {
                selectSingleNode(hitNode.id)
                refreshStyleInspector()
                refreshToolDock()
                needsDisplay = true
            }
        }
        let menu = NSMenu(title: "Canvas")
        menu.autoenablesItems = false
        if orderedSelectedNodeIDs.count >= 2 {
            let alignItem = NSMenuItem(title: "Align", action: nil, keyEquivalent: "")
            let alignMenu = NSMenu(title: "Align")
            alignMenu.autoenablesItems = false
            let groups: [[CanvasAlignment]] = [
                [.left, .centerHorizontal, .right],
                [.top, .centerVertical, .bottom],
                [.distributeHorizontally, .distributeVertically]
            ]
            for (groupIdx, group) in groups.enumerated() {
                if groupIdx > 0 { alignMenu.addItem(.separator()) }
                for alignment in group {
                    let item = NSMenuItem(
                        title: alignment.actionName,
                        action: #selector(alignSelectionFromMenu(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = alignment.rawValue
                    item.isEnabled = canAlign(alignment)
                    alignMenu.addItem(item)
                }
            }
            alignItem.submenu = alignMenu
            menu.addItem(alignItem)
            menu.addItem(.separator())
        }
        if canCutSelection {
            let item = NSMenuItem(title: "Cut", action: #selector(cutSelection(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if canCopySelection {
            let item = NSMenuItem(title: "Copy", action: #selector(copySelection(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if canPaste {
            let item = NSMenuItem(title: "Paste", action: #selector(pasteSelection(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if canDuplicateSelection {
            let item = NSMenuItem(title: "Duplicate", action: #selector(duplicateSelection(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if canBringToFront || canSendToBack {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            if canBringToFront {
                let item = NSMenuItem(title: "Bring to Front", action: #selector(bringToFront(_:)), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            if canSendToBack {
                let item = NSMenuItem(title: "Send to Back", action: #selector(sendToBack(_:)), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }
        if canDeleteSelection {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            let item = NSMenuItem(title: "Delete", action: #selector(deleteSelection(_:)), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu.items.isEmpty ? nil : menu
    }

    public override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            let shouldToggle = isSpacePressed && !spacePanDragged && spacePanStart == nil &&
                !hasGeometryPreview && inlineTextState == nil && drag == nil
            isSpacePressed = false
            spacePanDragged = false
            spacePanStart = nil
            if shouldToggle {
                toggleFocusedSelection()
            }
            return
        }
        super.keyUp(with: event)
    }

    public override func magnify(with event: NSEvent) {
        let anchor = convert(event.locationInWindow, from: nil)
        setZoom(zoomScale * (1 + event.magnification), centeredAt: anchor)
    }

    public override func keyDown(with event: NSEvent) {
        if inlineTextState != nil {
            inlineTextKeyDown(event)
            return
        }
        if geometryGesture != nil {
            geometryKeyDown(event)
            return
        }
        if lineEndpointGesture != nil {
            lineEndpointKeyDown(event)
            return
        }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if flags == [.command] {
            let shifted = event.modifierFlags.contains(.shift)
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a" where !shifted:
                selectAll(nil)
                return
            case "c" where !shifted:
                copySelection(nil)
                return
            case "x" where !shifted:
                cutSelection(nil)
                return
            case "v" where !shifted:
                pasteSelection(nil)
                return
            case "d" where !shifted:
                duplicateSelection(nil)
                return
            case "l" where !shifted:
                toggleLock(nil)
                return
            case "z":
                if shifted { redoMove(nil) } else { undoMove(nil) }
                return
            case "+", "=":
                zoomIn(nil)
                return
            case "-", "_":
                zoomOut(nil)
                return
            case "0" where !shifted:
                resetZoom(nil)
                return
            case "]" where shifted, "}" where shifted:
                bringToFront(nil)
                return
            case "[" where shifted, "{" where shifted:
                sendToBack(nil)
                return
            case "/", "?":
                beginShortcutsHelp()
                return
            default:
                if shifted && event.keyCode == 30 {
                    bringToFront(nil)
                    return
                }
                if shifted && event.keyCode == 33 {
                    sendToBack(nil)
                    return
                }
                if event.keyCode == 24 {
                    zoomIn(nil)
                    return
                }
                if event.keyCode == 27 {
                    zoomOut(nil)
                    return
                }
                if !shifted && event.keyCode == 29 {
                    resetZoom(nil)
                    return
                }
            }
        }
        if flags == [.command, .option], !event.modifierFlags.contains(.shift) {
            switch event.keyCode {
            case 123:
                alignSelection(.left)
                return
            case 124:
                alignSelection(.right)
                return
            case 126:
                alignSelection(.top)
                return
            case 125:
                alignSelection(.bottom)
                return
            default:
                break
            }
        }
        if flags == [.command, .control] {
            let shifted = event.modifierFlags.contains(.shift)
            let char = event.charactersIgnoringModifiers?.lowercased()
            if char == "h" || event.keyCode == 4 {
                alignSelection(shifted ? .distributeHorizontally : .centerHorizontal)
                return
            }
            if char == "v" || event.keyCode == 9 {
                alignSelection(shifted ? .distributeVertically : .centerVertical)
                return
            }
        }
        if flags.isEmpty {
            if event.keyCode == 49 {
                if !event.isARepeat {
                    isSpacePressed = true
                    spacePanDragged = false
                }
                return
            }
            if event.keyCode == 51 || event.keyCode == 117 {
                deleteSelection(nil)
                return
            }
            if event.keyCode == 48 {
                traverseSelection(backwards: event.modifierFlags.contains(.shift))
                return
            }
            if event.keyCode == 53 {
                if creationDrag != nil || activeCreationTool != .select {
                    creationDrag = nil
                    activeCreationTool = .select
                    needsDisplay = true
                    return
                }
                if connectionDrag != nil {
                    connectionDrag = nil
                    needsDisplay = true
                    return
                }
                if drag != nil {
                    self.drag = nil
                    syncFromSession()
                    return
                }
                if marqueeGesture != nil {
                    marqueeGesture = nil
                    refreshAlignBar()
                    needsDisplay = true
                    return
                }
                if isStyleInspectorOpen {
                    closeStyleInspector(nil)
                    return
                }
                if selectedID != nil || !selectedNodeIDs.isEmpty || selectedEdgeID != nil ||
                   focusedNodeID != nil || focusedConnectionID != nil {
                    clearSelection()
                    refreshStyleInspector()
                    refreshToolDock()
                    needsDisplay = true
                    NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
                }
                return
            }
            if event.modifierFlags.contains(.shift) {
                if event.keyCode == 18 || event.charactersIgnoringModifiers == "1" || event.characters == "!" {
                    zoomToFit(nil)
                    return
                }
                if event.keyCode == 29 || event.charactersIgnoringModifiers == "0" || event.characters == ")" {
                    resetZoom(nil)
                    return
                }
            }
            if event.characters == "+" || event.characters == "=" || event.keyCode == 24 {
                zoomIn(nil)
                return
            }
            if event.characters == "-" || event.characters == "_" || event.keyCode == 27 {
                zoomOut(nil)
                return
            }
            if event.characters == "?" {
                beginShortcutsHelp()
                return
            }
            if event.charactersIgnoringModifiers == "v" || event.charactersIgnoringModifiers == "V" {
                creationDrag = nil
                activeCreationTool = .select
                needsDisplay = true
                return
            }
            if event.charactersIgnoringModifiers == "n" || event.charactersIgnoringModifiers == "N" {
                beginAdjacentThought()
                return
            }
            if event.charactersIgnoringModifiers == "s" || event.charactersIgnoringModifiers == "S" {
                showStyleInspector(nil)
                return
            }
            if event.charactersIgnoringModifiers == "g" || event.charactersIgnoringModifiers == "G" {
                beginGeometryEditing()
                return
            }
            if event.charactersIgnoringModifiers == "c" || event.charactersIgnoringModifiers == "C" {
                beginConnection()
                return
            }
            let kind: CanvasShapeKind?
            switch event.charactersIgnoringModifiers {
            case "r", "R": kind = .rectangle
            case "o", "O": kind = .ellipse
            case "d", "D": kind = .diamond
            case "i", "I": kind = .triangle
            case "t", "T": kind = .text
            default: kind = nil
            }
            if let kind {
                activeCreationTool = .select
                insertShape(kind)
                return
            }
            let lineKind: CanvasLineKind?
            switch event.charactersIgnoringModifiers {
            case "l", "L": lineKind = .line
            case "a", "A": lineKind = .arrow
            default: lineKind = nil
            }
            if let lineKind {
                activeCreationTool = .select
                insertLine(lineKind)
                return
            }
            if event.keyCode == 36 {
                if activeCreationTool != .select {
                    let tool = activeCreationTool
                    creationDrag = nil
                    activeCreationTool = .select
                    switch tool {
                    case .shape(let k): insertShape(k)
                    case .line(let k): insertLine(k)
                    case .select: break
                    }
                    return
                }
                activatePrimaryEditor()
                return
            }
        }
        let step = event.modifierFlags.contains(.shift) ? 10.0 : 1.0
        let delta: (Double, Double)
        switch event.keyCode {
        case 123: delta = (-step, 0)
        case 124: delta = (step, 0)
        case 125: delta = (0, step)
        case 126: delta = (0, -step)
        default:
            super.keyDown(with: event)
            return
        }
        let activeIDs = selectedNodeIDs.isEmpty ? (selectedID.map { [$0] } ?? []) : nodes.map(\.id).filter { selectedNodeIDs.contains($0) }
        let unlockedIDs = activeIDs.filter { !session.isLocked($0) }
        guard !unlockedIDs.isEmpty else {
            NSSound.beep()
            return
        }
        var beforePositions: [String: CanvasPosition] = [:]
        for id in unlockedIDs {
            if let current = session.position(of: id) {
                beforePositions[id] = current
            }
        }
        var movedIDs: [String] = []
        for id in unlockedIDs {
            guard let current = beforePositions[id] else { continue }
            let next = CanvasPosition(x: current.x + delta.0, y: current.y + delta.1)
            if (try? moveWithoutHistory(id, to: next)) != nil {
                movedIDs.append(id)
            }
        }
        if !movedIDs.isEmpty {
            registerUndoMoves(movedIDs, to: beforePositions)
        } else {
            NSSound.beep()
        }
    }

    @objc public func undoMove(_ sender: Any?) {
        guard !isReadOnly, window?.attachedSheet == nil, connectionEditor == nil,
              attachmentPreview == nil, drag == nil else {
            NSSound.beep()
            return
        }
        if connectionDrag != nil { connectionDrag = nil; needsDisplay = true; return }
        if inlineTextState != nil { cancelInlineText(); return }
        if hasGeometryPreview { cancelGeometry(); return }
        history.undo()
    }

    @objc public func redoMove(_ sender: Any?) {
        guard !isReadOnly, window?.attachedSheet == nil, connectionEditor == nil,
              attachmentPreview == nil, drag == nil else {
            NSSound.beep()
            return
        }
        if connectionDrag != nil { connectionDrag = nil; needsDisplay = true; return }
        if inlineTextState != nil { cancelInlineText(); return }
        if hasGeometryPreview { cancelGeometry(); return }
        history.redo()
    }

    @objc public override func selectAll(_ sender: Any?) {
        guard !hasGeometryPreview, inlineTextState == nil, drag == nil,
              window?.attachedSheet == nil, connectionEditor == nil else {
            NSSound.beep()
            return
        }
        guard !nodes.isEmpty else { return }
        selectedNodeIDs = Set(nodes.map(\.id))
        selectedID = nodes.first?.id
        focusedNodeID = selectedID
        selectedEdgeID = nil
        focusedConnectionID = nil
        spaceSelectionMode = selectedNodeIDs.count > 1
        refreshStyleInspector()
        needsDisplay = true
    }
    public func beginGeometryEditing() {
        guard !hasGeometryPreview, inlineTextState == nil, drag == nil,
              selectedNodeIDs.count <= 1, let window, window.attachedSheet == nil,
              let id = selectedID else { NSSound.beep(); return }
        if session.canTransform(id), let geometry = session.geometry(of: id) {
            geometryGesture = GeometryGesture(id: id, geometry: geometry)
            window.makeFirstResponder(self)
            refreshStyleInspector()
            needsDisplay = true
        } else if session.canEditLineEndpoints(id), let lineGeometry = session.lineGeometry(of: id) {
            lineEndpointGesture = LineEndpointGesture(id: id, geometry: lineGeometry)
            window.makeFirstResponder(self)
            refreshStyleInspector()
            needsDisplay = true
        } else {
            NSSound.beep()
        }
    }

    private func geometryKeyDown(_ event: NSEvent) {
        if event.keyCode == 53 { cancelGeometry(); return }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "z" {
            cancelGeometry()
            return
        }
        guard flags.isEmpty else {
            NSSound.beep()
            return
        }
        guard var gesture = geometryGesture else { return }
        switch event.keyCode {
        case 36: commitGeometry()
        case 48:
            gesture.cycle(backwards: event.modifierFlags.contains(.shift))
            geometryGesture = gesture
            needsDisplay = true
        case 123, 124, 125, 126:
            let x = event.keyCode == 123 ? -1.0 : (event.keyCode == 124 ? 1.0 : 0.0)
            let y = event.keyCode == 126 ? -1.0 : (event.keyCode == 125 ? 1.0 : 0.0)
            do {
                try gesture.nudge(x: x, y: y, accelerated: event.modifierFlags.contains(.shift))
                geometryGesture = gesture
                renderGeometry(gesture.id, geometry: gesture.current)
            } catch { NSSound.beep() }
        default: NSSound.beep()
        }
    }

    private func commitGeometry() {
        guard let gesture = geometryGesture else { return }
        do {
            try changeGeometry(gesture.id, to: gesture.current)
            geometryGesture = nil
            refreshStyleInspector()
            needsDisplay = true
        } catch { NSSound.beep() }
    }

    private func cancelGeometry() {
        if let gesture = geometryGesture {
            geometryGesture = nil
            renderGeometry(gesture.id, geometry: gesture.before)
        }
        if let gesture = lineEndpointGesture {
            lineEndpointGesture = nil
            renderLineGeometry(gesture.id, geometry: gesture.before)
        }
        refreshStyleInspector()
    }

    private func changeGeometry(_ id: String, to geometry: CanvasGeometry) throws {
        guard let before = session.geometry(of: id),
              try session.setGeometry(id, to: geometry) else { return }
        renderGeometry(id, geometry: geometry)
        recordUndo("Transform") { target in
            do { try target.changeGeometry(id, to: before) }
            catch { NSSound.beep() }
        }
    }

    private func renderGeometry(_ id: String, geometry: CanvasGeometry) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].box = CGRect(x: geometry.x, y: geometry.y, width: geometry.width, height: geometry.height)
        nodes[index].data["rotation"] = geometry.rotation
        rebuildEdges()
        needsDisplay = true
    }

    private func lineEndpointKeyDown(_ event: NSEvent) {
        if event.keyCode == 53 { cancelGeometry(); return }
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "z" {
            cancelGeometry()
            return
        }
        guard flags.isEmpty, var gesture = lineEndpointGesture else {
            NSSound.beep()
            return
        }
        switch event.keyCode {
        case 36: commitLineEndpoints()
        case 48:
            gesture.cycle(backwards: event.modifierFlags.contains(.shift))
            lineEndpointGesture = gesture
            needsDisplay = true
        case 123, 124, 125, 126:
            let x = event.keyCode == 123 ? -1.0 : (event.keyCode == 124 ? 1.0 : 0.0)
            let y = event.keyCode == 126 ? -1.0 : (event.keyCode == 125 ? 1.0 : 0.0)
            do {
                try gesture.nudge(x: x, y: y, accelerated: event.modifierFlags.contains(.shift))
                lineEndpointGesture = gesture
                renderLineGeometry(gesture.id, geometry: gesture.current)
            } catch { NSSound.beep() }
        default: NSSound.beep()
        }
    }

    private func commitLineEndpoints() {
        guard let gesture = lineEndpointGesture else { return }
        do {
            try changeLineGeometry(gesture.id, to: gesture.current)
            lineEndpointGesture = nil
            refreshStyleInspector()
            needsDisplay = true
        } catch { NSSound.beep() }
    }

    private func changeLineGeometry(_ id: String, to geometry: CanvasLineGeometry) throws {
        guard let before = session.lineGeometry(of: id),
              try session.setLineGeometry(id, to: geometry) else { return }
        renderLineGeometry(id, geometry: geometry)
        recordUndo("Edit Line Endpoints") { target in
            do { try target.changeLineGeometry(id, to: before) }
            catch { NSSound.beep() }
        }
    }

    private func renderLineGeometry(_ id: String, geometry: CanvasLineGeometry) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].box = CGRect(x: geometry.x, y: geometry.y, width: geometry.width, height: geometry.height)
        nodes[index].data["from"] = [geometry.from.x, geometry.from.y]
        nodes[index].data["to"] = [geometry.to.x, geometry.to.y]
        nodes[index].data["rotation"] = geometry.rotation
        rebuildEdges()
        needsDisplay = true
    }

    public func beginConnection(focusLabel: Bool = false) {
        guard let window, window.attachedSheet == nil,
              connectionEditor == nil, attachmentPreview == nil,
              !hasGeometryPreview, inlineTextState == nil, drag == nil, canInsertConnection else { NSSound.beep(); return }
        let connectible = nodes.filter { $0.type != "shape-line" }
        let options = connectible.enumerated().map { index, node in
            var caption = ""
            for character in Self.nodeText(node).prefix(48) {
                caption.append(character.isNewline ? " " : character)
            }
            let kind = node.type == "shape" ? node.kind : node.type
            let title = caption.isEmpty ? kind.capitalized : "\(caption) [\(kind)]"
            return ConnectionEditor.ObjectOption(id: node.id, title: "\(index + 1). \(title)")
        }
        let existing = selectedEdgeID.flatMap { session.connectionState(of: $0) }
        connectionEditor = ConnectionEditor(
            objects: options,
            selectedID: selectedID,
            existingConnection: existing,
            focusLabel: focusLabel && existing != nil,
            commit: { [weak self] source, sourceSide, target, targetSide, label in
                guard let self else { return }
                if let existing {
                    guard let update = try self.session.updateConnection(
                        existing.id,
                        source: source,
                        sourceSide: sourceSide,
                        target: target,
                        targetSide: targetSide,
                        label: label
                    ) else { return }
                    self.selectedID = nil
                    self.selectedEdgeID = existing.id
                    self.rebuildEdges()
                    self.refreshStyleInspector()
                    self.needsDisplay = true
                    self.registerUndoConnectionUpdate(update)
                } else {
                    let insertion = try self.session.insertConnection(
                        source: source, sourceSide: sourceSide,
                        target: target, targetSide: targetSide,
                        label: label
                    )
                    self.selectedID = nil
                    self.selectedEdgeID = insertion.id
                    self.rebuildEdges()
                    self.refreshStyleInspector()
                    self.needsDisplay = true
                    self.registerUndoConnection(insertion, restoring: false, actionName: "Connect")
                }
            },
            completion: { [weak self, weak window] in
                guard let self else { return }
                self.connectionEditor = nil
                window?.makeFirstResponder(self)
            }
        )
        connectionEditor?.present(on: window)
    }

    private func registerUndoConnectionUpdate(_ update: CanvasConnectionUpdate) {
        recordUndo("Edit Connection") { target in
            do {
                let inverse = update.inverse
                try target.session.applyConnectionUpdate(inverse)
                target.selectedID = nil
                target.selectedEdgeID = inverse.id
                target.rebuildEdges()
                target.refreshStyleInspector()
                target.needsDisplay = true
                target.registerUndoConnectionUpdate(inverse)
            } catch { NSSound.beep() }
        }
    }

    private func registerUndoConnection(
        _ insertion: CanvasConnectionInsertion, restoring: Bool, actionName: String = "Connect"
    ) {
        recordUndo(actionName) { target in
            do {
                if restoring {
                    try target.session.restoreInsertion(insertion)
                    target.selectedID = nil
                    target.selectedEdgeID = insertion.id
                } else {
                    try target.session.removeInsertion(insertion)
                    if target.selectedEdgeID == insertion.id { target.selectedEdgeID = nil }
                }
                target.rebuildEdges()
                target.refreshStyleInspector()
                target.needsDisplay = true
                target.registerUndoConnection(insertion, restoring: !restoring, actionName: actionName)
            } catch { NSSound.beep() }
        }
    }

    /// Inserts at the currently visible center, never at the source file's origin.
    public func insertShape(_ kind: CanvasShapeKind) {
        guard !isReadOnly else { NSSound.beep(); return }
        if inlineTextState != nil {
            guard finishInlineTextBeforeCanvasAction() else { return }
        }
        guard let window, window.attachedSheet == nil,
              connectionEditor == nil, attachmentPreview == nil,
              !hasGeometryPreview, drag == nil else { return }
        let center = CGPoint(x: visibleWorldRect.midX, y: visibleWorldRect.midY)
        let position = CanvasPosition(x: center.x - 80, y: center.y - (kind == .text ? 24 : 48))
        if kind == .text {
            beginNewTextShape(at: position)
        } else {
            do { try createShape(kind, at: position) }
            catch { NSSound.beep() }
            window.makeFirstResponder(self)
        }
    }

    public func insertLine(_ kind: CanvasLineKind) {
        guard !isReadOnly else { NSSound.beep(); return }
        if inlineTextState != nil {
            guard finishInlineTextBeforeCanvasAction() else { return }
        }
        guard let window, window.attachedSheet == nil,
              connectionEditor == nil, attachmentPreview == nil,
              !hasGeometryPreview, drag == nil else { return }
        let center = CanvasPosition(x: visibleWorldRect.midX, y: visibleWorldRect.midY)
        do {
            let insertion = try session.insertLine(kind, centeredAt: center)
            displayInsertion(insertion.id)
            registerUndoInsertion(insertion, restoring: false, actionName: kind == .arrow ? "Insert Arrow" : "Insert Line")
        } catch {
            NSSound.beep()
        }
        window.makeFirstResponder(self)
    }

    private func createShape(
        _ kind: CanvasShapeKind,
        at position: CanvasPosition,
        text: String? = nil,
        width: Double = 160,
        height: Double? = nil
    ) throws {
        let insertion = try session.insertShape(kind, at: position, text: text, width: width, height: height)
        displayInsertion(insertion.id)
        registerUndoInsertion(insertion, restoring: false, actionName: "Insert Shape")
    }

    private func displayInsertion(_ id: String) {
        guard let rawNodes = session.root["nodes"] as? [[String: Any]],
              let index = rawNodes.firstIndex(where: { $0["id"] as? String == id }) else { return }
        let raw = rawNodes[index]
        nodes.insert(Node(id: id, type: raw["type"] as? String ?? "shape",
                          box: CGRect(x: number(raw["x"]), y: number(raw["y"]),
                                      width: number(raw["width"]), height: number(raw["height"])),
                          data: raw["data"] as? [String: Any] ?? [:]), at: index)
        selectSingleNode(id)
        expandDrawingBounds()
        refreshStyleInspector()
        needsDisplay = true
    }

    private func registerUndoInsertion(
        _ insertion: CanvasShapeInsertion, restoring: Bool, actionName: String = "Insert Shape"
    ) {
        recordUndo(actionName) { target in
            do {
                if restoring {
                    try target.session.restoreInsertion(insertion)
                    target.displayInsertion(insertion.id)
                } else {
                    try target.session.removeInsertion(insertion)
                    target.nodes.removeAll { $0.id == insertion.id }
                    target.selectedNodeIDs.remove(insertion.id)
                    if target.selectedID == insertion.id { target.selectedID = target.selectedNodeIDs.first }
                    if target.focusedNodeID == insertion.id { target.focusedNodeID = target.selectedID }
                    target.refreshStyleInspector()
                    target.needsDisplay = true
                }
                target.registerUndoInsertion(insertion, restoring: !restoring, actionName: actionName)
            } catch { NSSound.beep() }
        }
    }

    @objc public func copy(_ sender: Any?) {
        copySelection(sender)
    }

    @objc public func cut(_ sender: Any?) {
        cutSelection(sender)
    }

    @objc public func paste(_ sender: Any?) {
        pasteSelection(sender)
    }

    @objc public func copySelection(_ sender: Any? = nil) {
        guard canCopySelection, window?.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        do {
            let payload = try session.copyNodes(orderedSelectedNodeIDs)
            let data = try payload.encodedData()
            attachmentPasteboard.clearContents()
            attachmentPasteboard.setData(data, forType: Self.clipboardPasteboardType)
        } catch {
            NSSound.beep()
        }
    }

    @objc public func cutSelection(_ sender: Any? = nil) {
        guard canCutSelection, window?.attachedSheet == nil else {
            NSSound.beep()
            return
        }
        let unlocked = orderedUnlockedSelectedNodeIDs
        do {
            let payload = try session.copyNodes(unlocked)
            let data = try payload.encodedData()
            let deletion = try session.deleteNodes(unlocked)
            attachmentPasteboard.clearContents()
            attachmentPasteboard.setData(data, forType: Self.clipboardPasteboardType)
            let remaining = orderedSelectedNodeIDs.filter { !Set(unlocked).contains($0) }
            applyNodeSelection(remaining)
            syncFromSession()
            registerUndoBatchDeletion(deletion, restoring: true, actionName: "Cut")
        } catch {
            NSSound.beep()
        }
    }

    @objc public func pasteSelection(_ sender: Any? = nil) {
        guard canPaste, window?.attachedSheet == nil,
              let data = attachmentPasteboard.data(forType: Self.clipboardPasteboardType) else {
            NSSound.beep()
            return
        }
        do {
            let payload = try CanvasClipboardPayload.decode(from: data)
            let insertion = try session.paste(payload)
            applyNodeSelection(insertion.nodeIDs)
            syncFromSession()
            registerUndoBatchInsertion(insertion, restoring: false, actionName: "Paste")
        } catch {
            NSSound.beep()
        }
    }

    @objc public func duplicateSelection(_ sender: Any? = nil) {
        guard !hasGeometryPreview, inlineTextState == nil, drag == nil, window?.attachedSheet == nil,
              connectionEditor == nil, attachmentPreview == nil, pngExportSheet == nil else {
            NSSound.beep()
            return
        }
        let unlocked = orderedUnlockedSelectedNodeIDs
        guard !unlocked.isEmpty else {
            NSSound.beep()
            return
        }
        do {
            if unlocked.count == 1 && orderedSelectedNodeIDs.count == 1 {
                let insertion = try session.duplicateNode(unlocked[0])
                displayInsertion(insertion.id)
                registerUndoInsertion(insertion, restoring: false, actionName: "Duplicate")
            } else {
                let insertion = try session.duplicateNodes(unlocked)
                applyNodeSelection(insertion.nodeIDs)
                syncFromSession()
                registerUndoBatchInsertion(insertion, restoring: false, actionName: "Duplicate")
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc public func deleteSelection(_ sender: Any? = nil) {
        guard !hasGeometryPreview, inlineTextState == nil, drag == nil, window?.attachedSheet == nil,
              connectionEditor == nil, attachmentPreview == nil, pngExportSheet == nil else {
            NSSound.beep()
            return
        }
        let unlocked = orderedUnlockedSelectedNodeIDs
        if unlocked.count == 1 && orderedSelectedNodeIDs.count == 1 {
            let id = unlocked[0]
            do {
                let deletion = try session.deleteNode(id)
                clearSelection()
                syncFromSession()
                registerUndoNodeDeletion(deletion, restoring: true)
            } catch {
                NSSound.beep()
            }
        } else if !unlocked.isEmpty {
            do {
                let deletion = try session.deleteNodes(unlocked)
                let remaining = orderedSelectedNodeIDs.filter { !Set(unlocked).contains($0) }
                applyNodeSelection(remaining)
                syncFromSession()
                registerUndoBatchDeletion(deletion, restoring: true, actionName: "Delete")
            } catch {
                NSSound.beep()
            }
        } else if let edgeID = selectedEdgeID, orderedSelectedNodeIDs.isEmpty {
            do {
                let deletion = try session.deleteConnection(edgeID)
                selectedEdgeID = nil
                focusedConnectionID = nil
                rebuildEdges()
                refreshStyleInspector()
                needsDisplay = true
                registerUndoConnection(deletion, restoring: true, actionName: "Delete Connection")
            } catch {
                NSSound.beep()
            }
        } else {
            NSSound.beep()
        }
    }

    private func registerUndoBatchInsertion(
        _ insertion: CanvasBatchInsertion,
        restoring: Bool,
        actionName: String
    ) {
        recordUndo(actionName) { target in
            do {
                if restoring {
                    try target.session.restoreBatchInsertion(insertion)
                    target.applyNodeSelection(insertion.nodeIDs)
                } else {
                    try target.session.removeBatchInsertion(insertion)
                    let removed = Set(insertion.nodeIDs)
                    let remaining = target.orderedSelectedNodeIDs.filter { !removed.contains($0) }
                    target.applyNodeSelection(remaining)
                }
                target.syncFromSession()
                target.registerUndoBatchInsertion(insertion, restoring: !restoring, actionName: actionName)
            } catch {
                NSSound.beep()
            }
        }
    }

    private func registerUndoBatchDeletion(
        _ deletion: CanvasBatchDeletion,
        restoring: Bool,
        actionName: String
    ) {
        recordUndo(actionName) { target in
            do {
                if restoring {
                    try target.session.restoreBatchDeletion(deletion)
                    target.applyNodeSelection(deletion.ids)
                } else {
                    _ = try target.session.deleteNodes(deletion.ids)
                    let removed = Set(deletion.ids)
                    let remaining = target.orderedSelectedNodeIDs.filter { !removed.contains($0) }
                    target.applyNodeSelection(remaining)
                }
                target.syncFromSession()
                target.registerUndoBatchDeletion(deletion, restoring: !restoring, actionName: actionName)
            } catch {
                NSSound.beep()
            }
        }
    }

    private func registerUndoNodeDeletion(_ deletion: CanvasNodeDeletion, restoring: Bool) {
        recordUndo("Delete") { target in
            do {
                if restoring {
                    try target.session.restoreNodeDeletion(deletion)
                    target.selectSingleNode(deletion.id)
                } else {
                    _ = try target.session.deleteNode(deletion.id)
                    if target.selectedID == deletion.id { target.selectedID = nil }
                    target.selectedNodeIDs.remove(deletion.id)
                    if let edgeID = target.selectedEdgeID, !target.session.hasConnection(edgeID) {
                        target.selectedEdgeID = nil
                    }
                }
                target.syncFromSession()
                target.registerUndoNodeDeletion(deletion, restoring: !restoring)
            } catch {
                NSSound.beep()
            }
        }
    }

    @objc public func bringToFront(_ sender: Any? = nil) {
        guard !hasGeometryPreview, inlineTextState == nil, drag == nil, window?.attachedSheet == nil,
              connectionEditor == nil, attachmentPreview == nil, pngExportSheet == nil else {
            NSSound.beep()
            return
        }
        let unlocked = orderedUnlockedSelectedNodeIDs
        guard !unlocked.isEmpty else {
            NSSound.beep()
            return
        }
        do {
            if unlocked.count == 1 && orderedSelectedNodeIDs.count == 1 {
                guard let move = try session.bringToFront(unlocked[0]) else { return }
                syncFromSession()
                registerUndoStackMove(move, actionName: "Bring to Front")
            } else {
                guard let move = try session.bringToFront(unlocked) else { return }
                syncFromSession()
                registerUndoBatchStackMove(move, actionName: "Bring to Front")
            }
        } catch {
            NSSound.beep()
        }
    }

    @objc public func sendToBack(_ sender: Any? = nil) {
        guard !hasGeometryPreview, inlineTextState == nil, drag == nil, window?.attachedSheet == nil,
              connectionEditor == nil, attachmentPreview == nil, pngExportSheet == nil else {
            NSSound.beep()
            return
        }
        let unlocked = orderedUnlockedSelectedNodeIDs
        guard !unlocked.isEmpty else {
            NSSound.beep()
            return
        }
        do {
            if unlocked.count == 1 && orderedSelectedNodeIDs.count == 1 {
                guard let move = try session.sendToBack(unlocked[0]) else { return }
                syncFromSession()
                registerUndoStackMove(move, actionName: "Send to Back")
            } else {
                guard let move = try session.sendToBack(unlocked) else { return }
                syncFromSession()
                registerUndoBatchStackMove(move, actionName: "Send to Back")
            }
        } catch {
            NSSound.beep()
        }
    }

    private func registerUndoBatchStackMove(_ move: CanvasBatchStackMove, actionName: String) {
        recordUndo(actionName) { target in
            do {
                let inverse = move.inverse
                try target.session.applyBatchStackMove(inverse)
                target.applyNodeSelection(inverse.ids)
                target.syncFromSession()
                target.registerUndoBatchStackMove(inverse, actionName: actionName)
            } catch {
                NSSound.beep()
            }
        }
    }

    private func registerUndoStackMove(_ move: CanvasStackMove, actionName: String) {
        recordUndo(actionName) { target in
            do {
                guard let inverse = try target.session.moveNode(move.id, toIndex: move.fromIndex) else { return }
                target.selectSingleNode(move.id)
                target.syncFromSession()
                target.registerUndoStackMove(inverse, actionName: actionName)
            } catch {
                NSSound.beep()
            }
        }
    }

    @objc public func alignSelectionFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let alignment = CanvasAlignment(rawValue: raw) else { return }
        alignSelection(alignment)
    }

    public func alignSelection(_ alignment: CanvasAlignment) {
        guard !isReadOnly, !hasGeometryPreview, inlineTextState == nil, drag == nil,
              window?.attachedSheet == nil, connectionEditor == nil,
              attachmentPreview == nil, pngExportSheet == nil else {
            NSSound.beep()
            return
        }
        let selected = orderedSelectedNodeIDs
        guard session.canAlignNodes(selected, alignment: alignment) else {
            NSSound.beep()
            return
        }
        do {
            guard let batch = try session.alignNodes(selected, alignment: alignment) else { return }
            syncFromSession()
            registerUndoBatchMove(batch, selectedIDs: selected, actionName: alignment.actionName)
        } catch {
            NSSound.beep()
        }
    }

    private func registerUndoBatchMove(
        _ batch: CanvasBatchMove,
        selectedIDs: [String],
        actionName: String
    ) {
        recordUndo(actionName) { target in
            do {
                let inverse = batch.inverse
                try target.session.applyBatchMove(inverse)
                target.applyNodeSelection(selectedIDs)
                target.syncFromSession()
                target.registerUndoBatchMove(inverse, selectedIDs: selectedIDs, actionName: actionName)
            } catch {
                NSSound.beep()
            }
        }
    }

    @objc public func toggleLock(_ sender: Any? = nil) {
        guard !hasGeometryPreview, inlineTextState == nil, drag == nil, window?.attachedSheet == nil,
              connectionEditor == nil,
              let id = selectedID else {
            NSSound.beep()
            return
        }
        let next: Bool? = session.isLocked(id) ? nil : true
        do {
            try changeLocked(id, to: next)
        } catch {
            NSSound.beep()
        }
    }

    private func changeLocked(_ id: String, to locked: Bool?) throws {
        let before = session.lockedValue(of: id)
        guard try session.setLocked(id, to: locked) else { return }
        refreshStyleInspector()
        needsDisplay = true
        recordUndo(locked == true ? "Lock" : "Unlock") { target in
            do { try target.changeLocked(id, to: before) }
            catch { NSSound.beep() }
        }
    }

    @objc public func toggleStyleInspector(_ sender: Any? = nil) {
        if isStyleInspectorOpen {
            closeStyleInspector(sender)
        } else {
            showStyleInspector(sender)
        }
    }

    @objc public func showStyleInspector(_ sender: Any? = nil) {
        guard window?.attachedSheet == nil, inlineTextState == nil, connectionEditor == nil else {
            NSSound.beep()
            return
        }
        isStyleInspectorOpen = true
        styleInspector.isHidden = false
        refreshStyleInspector()
        refreshToolDock()
        styleInspector.focusPrimaryControl()
        needsDisplay = true
    }

    @objc public func closeStyleInspector(_ sender: Any? = nil) {
        guard isStyleInspectorOpen else { return }
        isStyleInspectorOpen = false
        styleInspector.isHidden = true
        refreshToolDock()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    public func applyStyle(_ property: CanvasStyleProperty, to value: CanvasStyleValue) throws {
        guard !hasGeometryPreview, inlineTextState == nil, drag == nil, window?.attachedSheet == nil,
              connectionEditor == nil, attachmentPreview == nil else {
            throw CanvasDocumentError("Finish the active edit before changing styles.")
        }
        if let id = selectedID {
            guard let change = try session.setNodeStyle(id, property: property, to: value) else { return }
            syncFromSession()
            registerUndoStyleChange(change)
        } else if let edgeID = selectedEdgeID {
            guard let change = try session.setConnectionStyle(edgeID, property: property, to: value) else { return }
            rebuildEdges()
            refreshStyleInspector()
            needsDisplay = true
            registerUndoStyleChange(change)
        } else {
            guard let change = try session.setDocumentStyle(property: property, to: value) else { return }
            syncFromSession()
            registerUndoStyleChange(change)
        }
    }

    private func registerUndoStyleChange(_ change: CanvasStyleChange) {
        recordUndo("Style") { target in
            do {
                let inverse = change.inverse
                try target.session.applyStyleChange(inverse)
                target.syncFromSession()
                target.registerUndoStyleChange(inverse)
            } catch {
                NSSound.beep()
            }
        }
    }

    private func refreshStyleInspector() {
        refreshToolDock()
        guard isStyleInspectorOpen else { return }
        let selected = orderedSelectedNodeIDs
        styleInspector.update(
            session: session,
            selectedNodeID: selectedID,
            selectedNodeCount: selected.count,
            selectedConnectionID: selectedEdgeID,
            hasGeometryPreview: hasGeometryPreview,
            canAlign: session.canAlignNodes(selected, alignment: .left),
            canDistribute: session.canAlignNodes(selected, alignment: .distributeHorizontally)
        )
        positionStyleInspector()
    }

    private func positionStyleInspector() {
        guard isStyleInspectorOpen else { return }
        let area = visibleRect.width > 0 ? visibleRect : bounds
        let size = styleInspector.frame.size
        let bannerOffset: CGFloat = statusBanner.isHidden ? 0 : (statusBanner.frame.height + 12)
        styleInspector.frame.origin = CGPoint(
            x: max(12, area.maxX - size.width - 16),
            y: area.minY + 16 + bannerOffset
        )
    }

    public func refreshToolDock() {
        refreshAlignBar()
        guard isToolDockVisible else { return }
        toolDock.update(
            activeTool: activeCreationTool,
            isReadOnly: isReadOnly,
            canConnect: canInsertConnection,
            canInsertThought: canInsertAdjacentThought,
            isStyleOpen: isStyleInspectorOpen,
            canExport: canExportPNG
        )
    }

    public func positionToolDock() {
        guard isToolDockVisible else { return }
        let area = visibleRect.width > 0 ? visibleRect : bounds
        let size = toolDock.frame.size
        toolDock.frame.origin = CGPoint(
            x: max(area.minX + 12, floor(area.midX - size.width / 2)),
            y: max(area.minY + 12, area.maxY - size.height - 14)
        )
    }

    public func refreshAlignBar() {
        let selected = orderedSelectedNodeIDs
        let canAlignNow = !isReadOnly && !hasGeometryPreview && inlineTextState == nil &&
            !hasActivePointerDrag && marqueeGesture == nil && connectionDrag == nil && creationDrag == nil &&
            session.canAlignNodes(selected, alignment: .left)
        let canDistributeNow = canAlignNow && session.canAlignNodes(selected, alignment: .distributeHorizontally)
        alignBar.isHidden = !canAlignNow
        if canAlignNow {
            alignBar.update(canAlign: true, canDistribute: canDistributeNow)
            positionAlignBar()
        }
    }

    public func positionAlignBar() {
        guard !alignBar.isHidden else { return }
        let area = visibleRect.width > 0 ? visibleRect : bounds
        let size = alignBar.frame.size
        let bottomMargin: CGFloat = isToolDockVisible ? (toolDock.frame.height + 22) : 14
        alignBar.frame.origin = CGPoint(
            x: max(area.minX + 12, floor(area.midX - size.width / 2)),
            y: max(area.minY + 12, area.maxY - size.height - bottomMargin)
        )
    }

    public func positionStatusBanner() {
        guard !statusBanner.isHidden else { return }
        let area = visibleRect.width > 0 ? visibleRect : bounds
        statusBanner.layoutControls(maxWidth: max(420, area.width - 32))
        let size = statusBanner.frame.size
        statusBanner.frame.origin = CGPoint(
            x: max(area.minX + 12, floor(area.midX - size.width / 2)),
            y: area.minY + 12
        )
    }

    private func selectSingleNode(_ id: String) {
        selectedID = id
        selectedNodeIDs = [id]
        focusedNodeID = id
        selectedEdgeID = nil
        focusedConnectionID = nil
        spaceSelectionMode = false
    }

    public func selectNode(_ id: String) {
        guard session.position(of: id) != nil else { return }
        selectSingleNode(id)
        refreshStyleInspector()
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }

    public func selectConnection(_ id: String) {
        guard session.hasConnection(id) else { return }
        selectSingleConnection(id)
        refreshStyleInspector()
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }

    public func deselectAll() {
        clearSelection()
        refreshStyleInspector()
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .selectedChildrenChanged)
    }

    private func applyNodeSelection(_ ids: [String]) {
        guard !ids.isEmpty else {
            clearSelection()
            return
        }
        if ids.count == 1 {
            selectSingleNode(ids[0])
        } else {
            selectedNodeIDs = Set(ids)
            selectedID = ids.first
            focusedNodeID = ids.first
            selectedEdgeID = nil
            focusedConnectionID = nil
            spaceSelectionMode = true
        }
    }

    private func selectSingleConnection(_ id: String) {
        selectedID = nil
        selectedNodeIDs.removeAll()
        focusedNodeID = nil
        selectedEdgeID = id
        focusedConnectionID = id
        spaceSelectionMode = false
    }

    private func clearSelection() {
        selectedID = nil
        selectedNodeIDs.removeAll()
        selectedEdgeID = nil
        focusedNodeID = nil
        focusedConnectionID = nil
        spaceSelectionMode = false
    }

    private func toggleFocusedSelection() {
        if inlineTextState != nil {
            guard finishInlineTextBeforeCanvasAction() else { return }
        }
        spaceSelectionMode = true
        if let nodeID = focusedNodeID ?? selectedID {
            focusedNodeID = nodeID
            focusedConnectionID = nil
            if selectedNodeIDs.contains(nodeID) {
                selectedNodeIDs.remove(nodeID)
            } else {
                selectedNodeIDs.insert(nodeID)
                selectedEdgeID = nil
            }
            selectedID = nodes.first(where: { selectedNodeIDs.contains($0.id) })?.id
            refreshStyleInspector()
            needsDisplay = true
        } else if let edgeID = focusedConnectionID ?? selectedEdgeID {
            focusedConnectionID = edgeID
            focusedNodeID = nil
            if selectedEdgeID == edgeID {
                selectedEdgeID = nil
            } else {
                selectedEdgeID = edgeID
                selectedNodeIDs.removeAll()
                selectedID = nil
            }
            refreshStyleInspector()
            needsDisplay = true
        } else {
            NSSound.beep()
        }
    }

    private func traverseSelection(backwards: Bool) {
        if inlineTextState != nil {
            guard finishInlineTextBeforeCanvasAction() else { return }
        }
        enum Selectable: Equatable {
            case node(String)
            case edge(String)
        }
        let items = nodes.map { Selectable.node($0.id) } + edges.map { Selectable.edge($0.id) }
        guard !items.isEmpty else {
            NSSound.beep()
            return
        }
        let current: Selectable? =
            focusedNodeID.map(Selectable.node) ??
            focusedConnectionID.map(Selectable.edge) ??
            selectedID.map(Selectable.node) ??
            selectedEdgeID.map(Selectable.edge)
        let nextIndex: Int
        if let current, let index = items.firstIndex(of: current) {
            nextIndex = (index + (backwards ? -1 : 1) + items.count) % items.count
        } else {
            nextIndex = backwards ? items.count - 1 : 0
        }
        switch items[nextIndex] {
        case .node(let id):
            focusedNodeID = id
            focusedConnectionID = nil
            if !spaceSelectionMode {
                selectedID = id
                selectedNodeIDs = [id]
                selectedEdgeID = nil
            }
        case .edge(let id):
            focusedNodeID = nil
            focusedConnectionID = id
            if !spaceSelectionMode {
                selectedID = nil
                selectedNodeIDs.removeAll()
                selectedEdgeID = id
            }
        }
        refreshStyleInspector()
        needsDisplay = true
    }

    private func syncFromSession() {
        paper = session.root["paper"] as? [String: Any] ?? [:]
        let appearance = session.root["appearance"] as? [String: Any]
        fontRole = appearance?["font"] as? String ?? "sans"
        defaultAlign = appearance?["align"] as? String
        nodes = (session.root["nodes"] as? [[String: Any]] ?? []).map { raw in
            Node(id: raw["id"] as? String ?? "", type: raw["type"] as? String ?? "shape",
                 box: CGRect(x: number(raw["x"]), y: number(raw["y"]),
                             width: number(raw["width"]), height: number(raw["height"])),
                 data: raw["data"] as? [String: Any] ?? [:])
        }
        let validIDs = Set(nodes.map(\.id))
        selectedNodeIDs = selectedNodeIDs.intersection(validIDs)
        if let id = selectedID, !validIDs.contains(id) {
            selectedID = nodes.first(where: { selectedNodeIDs.contains($0.id) })?.id
        } else if let id = selectedID {
            selectedNodeIDs.insert(id)
        }
        if let fid = focusedNodeID, !validIDs.contains(fid) {
            focusedNodeID = selectedID
        }
        rebuildEdges()
        refreshStyleInspector()
        needsDisplay = true
    }

    public func reloadFromSession(clearingUndoHistory: Bool) {
        inlineTextState = nil
        thoughtScrollView.isHidden = true
        geometryGesture = nil
        lineEndpointGesture = nil
        drag = nil
        connectionDrag = nil
        creationDrag = nil
        activeCreationTool = .select
        hoveredNodeID = nil
        marqueeGesture = nil
        selectedID = nil
        selectedNodeIDs.removeAll()
        selectedEdgeID = nil
        focusedNodeID = nil
        focusedConnectionID = nil
        if clearingUndoHistory {
            history.removeAllActions()
        }
        syncFromSession()
        expandDrawingBounds()
        window?.makeFirstResponder(self)
    }

    public func restoreRecoverableTextDraft(_ draft: CanvasRecoverableTextDraft) {
        switch draft.kind {
        case .adjacentEditing:
            guard let sourceID = draft.targetID,
                  let dirRaw = draft.directionRawValue,
                  let direction = CanvasThoughtDirection(rawValue: dirRaw),
                  session.canInsertAdjacentThought(from: sourceID) else { return }
            let geo = draft.geometry
            thoughtInputView.font = font(fontRole, "m", scale: zoomScale)
            thoughtInputView.textColor = CanvasTheme.primaryText
            thoughtInputView.insertionPointColor = CanvasTheme.primaryText
            inlineTextState = .adjacentEditing(
                sourceID: sourceID,
                direction: direction,
                geometry: geo,
                text: draft.text,
                error: nil
            )
            thoughtInputView.string = draft.text
            thoughtInputView.alignment = alignment(defaultAlign ?? "center")
            thoughtInputView.resetUndo()
            thoughtScrollView.isHidden = false
            revealThoughtGeometry(geo)
            positionInlineTextEditor()
            window?.makeFirstResponder(thoughtInputView)
            needsDisplay = true
        case .newText:
            let pos = CanvasPosition(x: draft.x, y: draft.y)
            let geo = draft.geometry
            thoughtInputView.font = font(fontRole, "m", scale: zoomScale)
            thoughtInputView.textColor = CanvasTheme.primaryText
            thoughtInputView.insertionPointColor = CanvasTheme.primaryText
            inlineTextState = .newText(position: pos, geometry: geo, text: draft.text, error: nil)
            thoughtInputView.string = draft.text
            thoughtInputView.alignment = alignment(defaultAlign ?? "left")
            thoughtInputView.resetUndo()
            thoughtScrollView.isHidden = false
            revealThoughtGeometry(geo)
            positionInlineTextEditor()
            window?.makeFirstResponder(thoughtInputView)
            needsDisplay = true
        case .shapeCaption:
            guard let id = draft.targetID,
                  session.canEditText(id),
                  let beforeGeo = draft.beforeGeometry ?? session.geometry(of: id),
                  let index = nodes.firstIndex(where: { $0.id == id }) else { return }
            let previewGeo = draft.geometry
            let node = nodes[index]
            let nodeRole = node.data["font"] as? String ?? fontRole
            let nodeSize = node.data["size"] as? String ?? "m"
            let effectiveFill = node.data["fill"] as? String ?? (node.kind == "text" ? "none" : "blue")
            nodes[index].box = CGRect(x: previewGeo.x, y: previewGeo.y, width: previewGeo.width, height: previewGeo.height)
            nodes[index].data["text"] = draft.text
            thoughtInputView.font = font(nodeRole, nodeSize, scale: zoomScale)
            thoughtInputView.textColor = textColor(on: effectiveFill)
            thoughtInputView.insertionPointColor = textColor(on: effectiveFill)
            inlineTextState = .shapeCaption(
                id: id,
                beforeText: draft.beforeText,
                beforeGeometry: beforeGeo,
                previewGeometry: previewGeo,
                text: draft.text,
                error: nil
            )
            thoughtInputView.string = draft.text
            let effectiveAlign = Self.effectiveAlignment(data: node.data, kind: node.kind, defaultAlign: defaultAlign)
            thoughtInputView.alignment = alignment(effectiveAlign)
            thoughtInputView.resetUndo()
            thoughtScrollView.isHidden = false
            rebuildEdges()
            positionInlineTextEditor()
            window?.makeFirstResponder(thoughtInputView)
            needsDisplay = true
        }
    }

    public func activatePrimaryEditor() {
        if let edgeID = selectedEdgeID, session.hasConnection(edgeID) {
            beginConnection(focusLabel: true)
        } else if let id = selectedID, session.attachment(of: id) != nil {
            beginAttachmentPreview()
        } else if let id = selectedID, session.canEditText(id) {
            beginTextEditing()
        } else {
            NSSound.beep()
        }
    }

    public func beginAttachmentPreview() {
        guard let window, window.attachedSheet == nil, inlineTextState == nil,
              connectionEditor == nil, attachmentPreview == nil,
              !hasGeometryPreview, drag == nil,
              let id = selectedID, let attachment = session.attachment(of: id) else {
            NSSound.beep()
            return
        }
        attachmentPreview = AttachmentPreviewSheet(
            attachment: attachment, pasteboard: attachmentPasteboard,
            completion: { [weak self, weak window] in
                guard let self else { return }
                self.attachmentPreview = nil
                window?.makeFirstResponder(self)
            }
        )
        attachmentPreview?.present(on: window)
    }

    public func beginPNGExport(defaultFilename: String = "canvas.png") {
        guard let window, window.attachedSheet == nil,
              connectionEditor == nil, attachmentPreview == nil, pngExportSheet == nil,
              drag == nil else {
            NSSound.beep()
            return
        }
        do {
            try flushPendingEditsForExport()
        } catch {
            NSSound.beep()
            return
        }
        let bounds = contentWorldBounds()
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
            NSSound.beep()
            return
        }
        let chooseDest: (String) -> URL? = { [weak self] suggestedName in
            if let provider = self?.pngExportDestinationProvider {
                return provider(suggestedName)
            }
            let savePanel = NSSavePanel()
            savePanel.allowedContentTypes = [.png]
            savePanel.canCreateDirectories = true
            savePanel.nameFieldStringValue = suggestedName
            return savePanel.runModal() == .OK ? savePanel.url : nil
        }
        pngExportSheet = PNGExportSheet(
            contentWorldBounds: bounds,
            defaultFilename: defaultFilename,
            chooseDestination: chooseDest,
            performExport: { [weak self] sizing, url in
                guard let self else { return }
                try self.exportPNG(to: url, sizing: sizing)
            },
            completion: { [weak self, weak window] in
                guard let self else { return }
                self.pngExportSheet = nil
                window?.makeFirstResponder(self)
            }
        )
        pngExportSheet?.present(on: window)
    }

    public func flushPendingEditsForSave() throws {
        guard pngExportSheet == nil, shortcutsSheet == nil else {
            throw CanvasDocumentError("Close the active sheet before saving.")
        }
        try flushPendingEdits(actionVerb: "saving")
    }

    public func flushPendingEditsForExport() throws {
        try flushPendingEdits(actionVerb: "exporting")
        guard !nodes.isEmpty else {
            throw CanvasDocumentError("Cannot export an empty canvas.")
        }
    }

    private func flushPendingEdits(actionVerb: String) throws {
        guard drag == nil else {
            throw CanvasDocumentError("Finish the active drag gesture before \(actionVerb).")
        }
        guard connectionDrag == nil else {
            throw CanvasDocumentError("Finish the active connection drag before \(actionVerb).")
        }
        guard creationDrag == nil else {
            throw CanvasDocumentError("Finish the active creation drag before \(actionVerb).")
        }
        guard connectionEditor == nil, attachmentPreview == nil, shortcutsSheet == nil else {
            throw CanvasDocumentError("Close the active sheet before \(actionVerb).")
        }
        if activeCreationTool != .select {
            activeCreationTool = .select
        }
        if let state = inlineTextState {
            if thoughtInputView.hasMarkedText() {
                throw CanvasDocumentError("Finish active text input before \(actionVerb).")
            }
            switch state {
            case .adjacentChoosing:
                cancelInlineText()
            case .adjacentEditing, .newText, .shapeCaption:
                commitInlineText()
                if inlineTextState != nil {
                    throw CanvasDocumentError(inlineTextError ?? "Finish valid text editing before \(actionVerb).")
                }
            }
        }
        if geometryGesture != nil {
            commitGeometry()
            if geometryGesture != nil {
                throw CanvasDocumentError("Could not commit pending geometry preview.")
            }
        }
        if lineEndpointGesture != nil {
            commitLineEndpoints()
            if lineEndpointGesture != nil {
                throw CanvasDocumentError("Could not commit pending line endpoint preview.")
            }
        }
    }

    public func contentWorldBounds() -> CGRect {
        _ = CanvasTypography.ensureRegistered()
        return Self.contentWorldBounds(nodes: nodes, edges: edges, role: fontRole)
    }

    public func exportPNGPlan(
        sizing: CanvasPNGExportSizing = .longestSide(CanvasPNGExportSizing.defaultLongestSide),
        padding: Double = CanvasPNGExportSizing.defaultPadding
    ) throws -> CanvasPNGExportPlan {
        try flushPendingEditsForExport()
        _ = CanvasTypography.ensureRegistered()
        let bounds = Self.contentWorldBounds(nodes: nodes, edges: edges, role: fontRole)
        return try CanvasPNGExportPlan.resolve(contentWorldBounds: bounds, sizing: sizing, padding: padding)
    }

    public func exportPNGData(
        sizing: CanvasPNGExportSizing = .longestSide(CanvasPNGExportSizing.defaultLongestSide),
        padding: Double = CanvasPNGExportSizing.defaultPadding
    ) throws -> Data {
        try flushPendingEditsForExport()
        _ = CanvasTypography.ensureRegistered()
        let snapshotRoot = session.root
        let snapshotAppearance = snapshotRoot["appearance"] as? [String: Any]
        let snapshotRole = snapshotAppearance?["font"] as? String ?? "sans"
        let snapshotAlign = snapshotAppearance?["align"] as? String
        let snapshotNodes = (snapshotRoot["nodes"] as? [[String: Any]] ?? []).map { raw in
            Node(
                id: raw["id"] as? String ?? "",
                type: raw["type"] as? String ?? "shape",
                box: CGRect(
                    x: number(raw["x"]),
                    y: number(raw["y"]),
                    width: number(raw["width"]),
                    height: number(raw["height"])
                ),
                data: raw["data"] as? [String: Any] ?? [:]
            )
        }
        let index = Dictionary(uniqueKeysWithValues: snapshotNodes.map { ($0.id, $0) })
        let snapshotEdges = (snapshotRoot["edges"] as? [[String: Any]] ?? []).compactMap { raw -> EdgeDrawing? in
            guard let source = index[raw["source"] as? String ?? ""],
                  let target = index[raw["target"] as? String ?? ""] else { return nil }
            return Self.makeEdge(raw, source, target, role: snapshotRole)
        }
        let bounds = Self.contentWorldBounds(nodes: snapshotNodes, edges: snapshotEdges, role: snapshotRole)
        let plan = try CanvasPNGExportPlan.resolve(contentWorldBounds: bounds, sizing: sizing, padding: padding)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cgContext = CGContext(
                  data: nil,
                  width: plan.pixelWidth,
                  height: plan.pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw CanvasDocumentError("Could not allocate sRGB bitmap for PNG export.")
        }
        cgContext.clear(CGRect(x: 0, y: 0, width: plan.pixelWidth, height: plan.pixelHeight))
        cgContext.translateBy(x: 0, y: CGFloat(plan.pixelHeight))
        cgContext.scaleBy(x: 1, y: -1)
        let graphicsContext = NSGraphicsContext(cgContext: cgContext, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        cgContext.saveGState()
        cgContext.translateBy(x: plan.offsetX, y: plan.offsetY)
        cgContext.scaleBy(x: plan.scale, y: plan.scale)
        cgContext.translateBy(x: -plan.paddedWorldBounds.minX, y: -plan.paddedWorldBounds.minY)
        for edge in snapshotEdges {
            Self.drawEdge(edge, role: snapshotRole, isSelected: false)
        }
        for node in snapshotNodes {
            Self.drawNode(node, role: snapshotRole, defaultAlign: snapshotAlign, hideCaption: false)
        }
        cgContext.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = cgContext.makeImage() else {
            throw CanvasDocumentError("Could not finalize PNG image.")
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw CanvasDocumentError("Could not encode PNG data.")
        }
        return pngData
    }

    public func exportPNG(
        to url: URL,
        sizing: CanvasPNGExportSizing = .longestSide(CanvasPNGExportSizing.defaultLongestSide),
        padding: Double = CanvasPNGExportSizing.defaultPadding
    ) throws {
        let data = try exportPNGData(sizing: sizing, padding: padding)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw CanvasDocumentError("Cannot write PNG to \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    public func beginTextEditing() {
        guard inlineTextState == nil, connectionEditor == nil, attachmentPreview == nil,
              !hasGeometryPreview, let window, window.attachedSheet == nil,
              let id = selectedID, session.canEditText(id),
              let beforeGeometry = session.geometry(of: id),
              let node = nodes.first(where: { $0.id == id }) else { NSSound.beep(); return }
        drag = nil
        let beforeText = session.text(of: id)
        let initialText = beforeText ?? ""
        let effectiveRole = node.data["font"] as? String ?? fontRole
        let effectiveSize = node.data["size"] as? String ?? "m"
        let effectiveAlign = Self.effectiveAlignment(data: node.data, kind: node.kind, defaultAlign: defaultAlign)
        let effectiveFill = node.data["fill"] as? String ?? (node.kind == "text" ? "none" : "blue")
        thoughtInputView.font = font(effectiveRole, effectiveSize, scale: zoomScale)
        thoughtInputView.alignment = alignment(effectiveAlign)
        thoughtInputView.textColor = textColor(on: effectiveFill)
        thoughtInputView.insertionPointColor = textColor(on: effectiveFill)
        inlineTextState = .shapeCaption(
            id: id,
            beforeText: beforeText,
            beforeGeometry: beforeGeometry,
            previewGeometry: beforeGeometry,
            text: initialText,
            error: nil
        )
        thoughtInputView.string = initialText
        thoughtInputView.alignment = alignment(effectiveAlign)
        thoughtInputView.resetUndo()
        thoughtScrollView.isHidden = false
        revealThoughtGeometry(beforeGeometry)
        positionInlineTextEditor()
        window.makeFirstResponder(thoughtInputView)
        positionInlineTextEditor()
        needsDisplay = true
    }

    private func beginNewTextShape(at position: CanvasPosition) {
        guard let window else { return }
        let geo = CanvasGeometry(x: position.x, y: position.y, width: 160, height: 48, rotation: nil)
        let effectiveAlign = defaultAlign ?? "left"
        thoughtInputView.font = font(fontRole, "m", scale: zoomScale)
        thoughtInputView.alignment = alignment(effectiveAlign)
        thoughtInputView.textColor = CanvasTheme.primaryText
        thoughtInputView.insertionPointColor = CanvasTheme.primaryText
        inlineTextState = .newText(position: position, geometry: geo, text: "", error: nil)
        thoughtInputView.string = ""
        thoughtInputView.alignment = alignment(effectiveAlign)
        thoughtInputView.resetUndo()
        thoughtScrollView.isHidden = false
        revealThoughtGeometry(geo)
        positionInlineTextEditor()
        window.makeFirstResponder(thoughtInputView)
        needsDisplay = true
    }

    private func changeTextAndGeometry(_ id: String, to text: String?, geometry: CanvasGeometry?) throws {
        guard let change = try session.setTextAndGeometry(id, to: text, geometry: geometry) else { return }
        syncFromSession()
        registerUndoTextChange(change)
    }

    private func registerUndoTextChange(_ change: CanvasTextChange) {
        recordUndo("Edit Text") { target in
            do {
                let inverse = change.inverse
                try target.session.applyTextChange(inverse)
                target.syncFromSession()
                target.registerUndoTextChange(inverse)
            } catch { NSSound.beep() }
        }
    }

    public func beginAdjacentThought() {
        guard let window, window.attachedSheet == nil, inlineTextState == nil,
              connectionEditor == nil, attachmentPreview == nil,
              !hasGeometryPreview, drag == nil,
              let sourceID = adjacentThoughtSourceID else {
            NSSound.beep()
            return
        }
        inlineTextState = .adjacentChoosing(sourceID: sourceID)
        thoughtScrollView.isHidden = true
        window.makeFirstResponder(self)
        needsDisplay = true
    }

    private func inlineTextKeyDown(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "z" {
            if case .adjacentChoosing = inlineTextState {
                cancelInlineText()
                if event.modifierFlags.contains(.shift) { redoMove(nil) } else { undoMove(nil) }
                return
            }
        }
        switch inlineTextState {
        case .adjacentChoosing:
            if event.keyCode == 53 {
                cancelInlineText()
                return
            }
            guard flags.isEmpty else {
                NSSound.beep()
                return
            }
            switch event.keyCode {
            case 126: startAdjacentThoughtDraft(.up)
            case 124: startAdjacentThoughtDraft(.right)
            case 125: startAdjacentThoughtDraft(.down)
            case 123: startAdjacentThoughtDraft(.left)
            default: NSSound.beep()
            }
        case .adjacentEditing, .newText, .shapeCaption:
            thoughtInputView.keyDown(with: event)
        case .none:
            break
        }
    }

    private func startAdjacentThoughtDraft(_ direction: CanvasThoughtDirection) {
        guard case .adjacentChoosing(let sourceID) = inlineTextState else { return }
        do {
            let geo = try session.adjacentThoughtGeometry(from: sourceID, direction: direction, height: 96)
            let effectiveAlign = defaultAlign ?? "center"
            thoughtInputView.font = font(fontRole, "m", scale: zoomScale)
            thoughtInputView.alignment = alignment(effectiveAlign)
            thoughtInputView.textColor = CanvasTheme.primaryText
            thoughtInputView.insertionPointColor = CanvasTheme.primaryText
            inlineTextState = .adjacentEditing(sourceID: sourceID, direction: direction, geometry: geo, text: "", error: nil)
            thoughtInputView.string = ""
            thoughtInputView.alignment = alignment(effectiveAlign)
            thoughtInputView.resetUndo()
            thoughtScrollView.isHidden = false
            revealThoughtGeometry(geo)
            positionInlineTextEditor()
            window?.makeFirstResponder(thoughtInputView)
            positionInlineTextEditor()
            needsDisplay = true
        } catch {
            cancelInlineText()
            NSSound.beep()
        }
    }

    private func updateInlineText(_ text: String) {
        switch inlineTextState {
        case .adjacentEditing(let sourceID, let direction, _, _, _):
            guard session.canInsertAdjacentThought(from: sourceID) else {
                cancelInlineText()
                return
            }
            let prototype = Node(
                id: "", type: "shape",
                box: CGRect(x: 0, y: 0, width: 160, height: 96),
                data: ["kind": "rect", "fill": "none", "stroke": "ink", "radius": 0]
            )
            let measured = Double(Self.measuredBoxHeight(for: prototype, text: text, role: fontRole))
            let requiredHeight = max(96.0, measured)
            guard let geo = try? session.adjacentThoughtGeometry(from: sourceID, direction: direction, height: requiredHeight) else {
                cancelInlineText()
                return
            }
            inlineTextState = .adjacentEditing(sourceID: sourceID, direction: direction, geometry: geo, text: text, error: nil)
            revealThoughtGeometry(geo)
            positionInlineTextEditor()
            needsDisplay = true
        case .newText(let position, _, _, _):
            let prototype = Node(
                id: "", type: "shape",
                box: CGRect(x: position.x, y: position.y, width: 160, height: 48),
                data: ["kind": "text", "fill": "none", "stroke": "none", "radius": 0]
            )
            let measured = Double(Self.measuredBoxHeight(for: prototype, text: text, role: fontRole))
            let requiredHeight = max(48.0, measured)
            let geo = CanvasGeometry(x: position.x, y: position.y, width: 160, height: requiredHeight, rotation: nil)
            inlineTextState = .newText(position: position, geometry: geo, text: text, error: nil)
            revealThoughtGeometry(geo)
            positionInlineTextEditor()
            needsDisplay = true
        case .shapeCaption(let id, let beforeText, let beforeGeometry, _, _, _):
            guard let index = nodes.firstIndex(where: { $0.id == id }) else {
                cancelInlineText()
                return
            }
            let measured = Double(Self.measuredBoxHeight(for: nodes[index], text: text, role: fontRole))
            let requiredHeight = max(beforeGeometry.height, measured)
            let previewGeo = beforeGeometry.resized(
                handle: .bottom,
                localDelta: CanvasPosition(x: 0, y: requiredHeight - beforeGeometry.height)
            )
            nodes[index].box = CGRect(
                x: previewGeo.x, y: previewGeo.y, width: previewGeo.width, height: previewGeo.height
            )
            nodes[index].data["text"] = text
            inlineTextState = .shapeCaption(
                id: id,
                beforeText: beforeText,
                beforeGeometry: beforeGeometry,
                previewGeometry: previewGeo,
                text: text,
                error: nil
            )
            rebuildEdges()
            positionInlineTextEditor()
            needsDisplay = true
        case .adjacentChoosing, .none:
            break
        }
    }

    private func commitInlineText() {
        guard !thoughtInputView.hasMarkedText() else { return }
        let text = thoughtInputView.string
        switch inlineTextState {
        case .adjacentEditing(let sourceID, let direction, let geo, _, _):
            guard session.canInsertAdjacentThought(from: sourceID) else {
                cancelInlineText()
                return
            }
            if text.count > 2_000 {
                inlineTextState = .adjacentEditing(
                    sourceID: sourceID,
                    direction: direction,
                    geometry: geo,
                    text: text,
                    error: "Text must contain at most 2000 characters."
                )
                window?.makeFirstResponder(thoughtInputView)
                needsDisplay = true
                NSSound.beep()
                return
            }
            let prototype = Node(
                id: "", type: "shape",
                box: CGRect(x: 0, y: 0, width: 160, height: 96),
                data: ["kind": "rect", "fill": "none", "stroke": "ink", "radius": 0]
            )
            let measured = Double(Self.measuredBoxHeight(for: prototype, text: text, role: fontRole))
            let requiredHeight = max(96.0, measured)
            do {
                let insertion = try session.insertAdjacentThought(
                    from: sourceID,
                    direction: direction,
                    text: text,
                    height: requiredHeight
                )
                inlineTextState = nil
                thoughtScrollView.isHidden = true
                displayInsertion(insertion.id)
                window?.makeFirstResponder(self)
                registerUndoAdjacentThought(insertion, sourceID: sourceID, restoring: false)
            } catch {
                inlineTextState = .adjacentEditing(
                    sourceID: sourceID,
                    direction: direction,
                    geometry: geo,
                    text: text,
                    error: error.localizedDescription
                )
                window?.makeFirstResponder(thoughtInputView)
                needsDisplay = true
                NSSound.beep()
            }
        case .newText(let position, let geo, _, _):
            guard !text.isEmpty else {
                cancelInlineText()
                return
            }
            if text.count > 2_000 {
                inlineTextState = .newText(
                    position: position,
                    geometry: geo,
                    text: text,
                    error: "Text must contain at most 2000 characters."
                )
                window?.makeFirstResponder(thoughtInputView)
                needsDisplay = true
                NSSound.beep()
                return
            }
            let prototype = Node(
                id: "", type: "shape",
                box: CGRect(x: position.x, y: position.y, width: 160, height: 48),
                data: ["kind": "text", "fill": "none", "stroke": "none", "radius": 0]
            )
            let measured = Double(Self.measuredBoxHeight(for: prototype, text: text, role: fontRole))
            do {
                inlineTextState = nil
                thoughtScrollView.isHidden = true
                try createShape(.text, at: position, text: text, height: max(48, measured))
                window?.makeFirstResponder(self)
            } catch {
                inlineTextState = .newText(
                    position: position,
                    geometry: geo,
                    text: text,
                    error: error.localizedDescription
                )
                thoughtScrollView.isHidden = false
                window?.makeFirstResponder(thoughtInputView)
                needsDisplay = true
                NSSound.beep()
            }
        case .shapeCaption(let id, let beforeText, let beforeGeometry, let previewGeo, _, _):
            if text.count > 2_000 {
                inlineTextState = .shapeCaption(
                    id: id,
                    beforeText: beforeText,
                    beforeGeometry: beforeGeometry,
                    previewGeometry: previewGeo,
                    text: text,
                    error: "Text must contain at most 2000 characters."
                )
                window?.makeFirstResponder(thoughtInputView)
                needsDisplay = true
                NSSound.beep()
                return
            }
            // Finishing an unchanged empty caption must not materialize a default.
            guard text != (beforeText ?? "") else {
                inlineTextState = nil
                thoughtScrollView.isHidden = true
                syncFromSession()
                window?.makeFirstResponder(self)
                return
            }
            guard let index = nodes.firstIndex(where: { $0.id == id }) else {
                cancelInlineText()
                return
            }
            let measured = Double(Self.measuredBoxHeight(for: nodes[index], text: text, role: fontRole))
            let requiredHeight = max(beforeGeometry.height, measured)
            let targetGeo = beforeGeometry.resized(
                handle: .bottom,
                localDelta: CanvasPosition(x: 0, y: requiredHeight - beforeGeometry.height)
            )
            do {
                inlineTextState = nil
                thoughtScrollView.isHidden = true
                try changeTextAndGeometry(
                    id, to: text, geometry: targetGeo == beforeGeometry ? nil : targetGeo
                )
                window?.makeFirstResponder(self)
            } catch {
                inlineTextState = .shapeCaption(
                    id: id,
                    beforeText: beforeText,
                    beforeGeometry: beforeGeometry,
                    previewGeometry: previewGeo,
                    text: text,
                    error: error.localizedDescription
                )
                thoughtScrollView.isHidden = false
                window?.makeFirstResponder(thoughtInputView)
                needsDisplay = true
                NSSound.beep()
            }
        case .adjacentChoosing, .none:
            break
        }
    }

    @discardableResult
    private func finishInlineTextBeforeCanvasAction() -> Bool {
        guard let state = inlineTextState else { return true }
        if case .adjacentChoosing = state {
            cancelInlineText()
            return true
        }
        commitInlineText()
        return inlineTextState == nil
    }

    public func cancelAdjacentThought() {
        cancelInlineText()
    }

    public func cancelInlineText() {
        guard let state = inlineTextState else { return }
        inlineTextState = nil
        thoughtScrollView.isHidden = true
        if case .shapeCaption = state {
            syncFromSession()
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    private func registerUndoAdjacentThought(
        _ insertion: CanvasShapeInsertion, sourceID: String, restoring: Bool
    ) {
        recordUndo("Insert Adjacent Thought") { target in
            do {
                if restoring {
                    try target.session.restoreInsertion(insertion)
                    target.displayInsertion(insertion.id)
                } else {
                    try target.session.removeInsertion(insertion)
                    target.nodes.removeAll { $0.id == insertion.id }
                    if target.nodes.contains(where: { $0.id == sourceID }) {
                        target.selectSingleNode(sourceID)
                    } else {
                        target.clearSelection()
                    }
                    target.refreshStyleInspector()
                    target.needsDisplay = true
                }
                target.window?.makeFirstResponder(target)
                target.registerUndoAdjacentThought(insertion, sourceID: sourceID, restoring: !restoring)
            } catch { NSSound.beep() }
        }
    }

    private func positionInlineTextEditor() {
        let geo: CanvasGeometry
        let scaledFont: NSFont
        let editorAlign: String
        switch inlineTextState {
        case .adjacentEditing(_, _, let g, _, _):
            geo = g
            scaledFont = font(fontRole, "m", scale: zoomScale)
            editorAlign = defaultAlign ?? "center"
        case .newText(_, let g, _, _):
            geo = g
            scaledFont = font(fontRole, "m", scale: zoomScale)
            editorAlign = defaultAlign ?? "left"
        case .shapeCaption(let id, _, _, let g, _, _):
            geo = g
            if let node = nodes.first(where: { $0.id == id }) {
                let effectiveRole = node.data["font"] as? String ?? fontRole
                let effectiveSize = node.data["size"] as? String ?? "m"
                scaledFont = font(effectiveRole, effectiveSize, scale: zoomScale)
                editorAlign = Self.effectiveAlignment(data: node.data, kind: node.kind, defaultAlign: defaultAlign)
            } else {
                scaledFont = font(fontRole, "m", scale: zoomScale)
                editorAlign = defaultAlign ?? "center"
            }
        case .adjacentChoosing, .none:
            thoughtScrollView.frameRotation = 0
            thoughtScrollView.isHidden = true
            return
        }
        thoughtInputView.font = scaledFont
        thoughtInputView.typingAttributes[.font] = scaledFont
        thoughtInputView.alignment = alignment(editorAlign)
        let viewRect = CGRect(
            x: (geo.x - origin.x) * zoomScale,
            y: (geo.y - origin.y) * zoomScale,
            width: geo.width * zoomScale,
            height: geo.height * zoomScale
        )
        let area = visibleRect.width > 0 ? visibleRect : bounds
        let borderPad = 2 * zoomScale
        let horizontalInset = max(2, 8 * zoomScale)
        let minVisualHeight = max(20, 44 * zoomScale)
        let maxEditorHeight = max(72 * zoomScale, area.height - 96)
        let unclampedHeight = max(minVisualHeight, viewRect.height - borderPad * 2)
        let needsScroll = unclampedHeight > maxEditorHeight + 1
        thoughtScrollView.hasVerticalScroller = needsScroll
        let frameWidth = max(24, viewRect.width - borderPad * 2)
        let frameHeight = min(unclampedHeight, maxEditorHeight)
        thoughtInputView.minSize = .zero
        thoughtInputView.isVerticallyResizable = needsScroll
        thoughtScrollView.frameRotation = 0
        thoughtScrollView.setFrameSize(CGSize(width: frameWidth, height: frameHeight))
        thoughtInputView.setFrameSize(CGSize(width: frameWidth, height: frameHeight))
        let usedHeight: CGFloat
        if let layoutManager = thoughtInputView.layoutManager,
           let textContainer = thoughtInputView.textContainer {
            textContainer.containerSize = CGSize(
                width: max(1, frameWidth - horizontalInset * 2),
                height: .greatestFiniteMagnitude
            )
            layoutManager.ensureLayout(for: textContainer)
            usedHeight = max(scaledFont.pointSize, ceil(layoutManager.usedRect(for: textContainer).height))
        } else {
            usedHeight = ceil(scaledFont.pointSize * 1.4)
        }
        let minVerticalInset = max(2, 8 * zoomScale)
        let verticalInset = needsScroll
            ? minVerticalInset
            : max(0, floor((frameHeight - usedHeight - 4) / 2))
        thoughtInputView.textContainerInset = NSSize(width: horizontalInset, height: verticalInset)
        let viewCenter = CGPoint(x: viewRect.midX, y: viewRect.midY)
        let rotationDegrees = CGFloat(geo.rotation ?? 0)
        if abs(rotationDegrees) > 0.0001 {
            let angle = rotationDegrees * .pi / 180
            let dx = -frameWidth / 2
            let dy = -frameHeight / 2
            let rotatedOrigin = CGPoint(
                x: viewCenter.x + dx * cos(angle) - dy * sin(angle),
                y: viewCenter.y + dx * sin(angle) + dy * cos(angle)
            )
            thoughtScrollView.frameRotation = rotationDegrees
            thoughtScrollView.setFrameOrigin(rotatedOrigin)
        } else {
            thoughtScrollView.setFrameOrigin(CGPoint(
                x: viewCenter.x - frameWidth / 2,
                y: viewCenter.y - frameHeight / 2
            ))
        }
        thoughtInputView.setFrameOrigin(.zero)
        thoughtInputView.setFrameSize(CGSize(width: frameWidth, height: frameHeight))
        if needsScroll {
            thoughtInputView.sizeToFit()
        } else {
            thoughtScrollView.contentView.setBoundsOrigin(.zero)
            thoughtScrollView.reflectScrolledClipView(thoughtScrollView.contentView)
        }
    }
    private func revealThoughtGeometry(_ geo: CanvasGeometry) {
        expandDrawingBounds()
        let area = visibleRect.width > 0 ? visibleRect : bounds
        let availableWidth = max(64, area.width - 48)
        let availableHeight = max(64, area.height - 96)
        let minEditHeight: CGFloat = 96
        let neededScale = min(availableWidth / CGFloat(geo.width), availableHeight / minEditHeight)
        if neededScale < zoomScale {
            setZoom(max(0.1, neededScale))
        }
        let worldViewport = visibleWorldRect
        let targetWorld = CGRect(
            x: geo.x - 24,
            y: geo.y - 24,
            width: geo.width + 48,
            height: min(geo.height, 96) + 72
        )
        var newWorldOrigin = worldViewport.origin
        if targetWorld.minX < worldViewport.minX {
            newWorldOrigin.x = targetWorld.minX
        } else if targetWorld.maxX > worldViewport.maxX {
            newWorldOrigin.x = targetWorld.maxX - worldViewport.width
        }
        if targetWorld.minY < worldViewport.minY {
            newWorldOrigin.y = targetWorld.minY
        } else if targetWorld.maxY > worldViewport.maxY {
            newWorldOrigin.y = targetWorld.maxY - worldViewport.height
        }
        if newWorldOrigin != worldViewport.origin {
            setVisibleWorldOrigin(newWorldOrigin)
        }
    }

    @objc public func zoomIn(_ sender: Any? = nil) {
        setZoom(zoomScale * 1.25)
    }

    @objc public func zoomOut(_ sender: Any? = nil) {
        setZoom(zoomScale / 1.25)
    }

    @objc public func resetZoom(_ sender: Any? = nil) {
        setZoom(1.0)
    }

    @objc public func zoomToFit(_ sender: Any? = nil) {
        var content = CGRect.null
        for node in nodes {
            let b = node.geometry.rotatedAxisAlignedBounds
            content = content.union(CGRect(x: b.x, y: b.y, width: b.width, height: b.height))
        }
        for edge in edges {
            content = content.union(edge.path.bounds)
            if let labelRect = edge.labelRect {
                content = content.union(labelRect)
            }
        }
        guard !content.isNull, content.width > 0, content.height > 0 else {
            resetZoom(sender)
            return
        }
        let padded = content.insetBy(dx: -48, dy: -48)
        let viewport = enclosingScrollView?.contentView.bounds.size
            ?? (visibleRect.width > 0 ? visibleRect.size : bounds.size)
        let scaleX = max(1, viewport.width) / padded.width
        let scaleY = max(1, viewport.height) / padded.height
        let targetScale = max(0.1, min(4.0, min(scaleX, scaleY)))
        zoomScale = targetScale
        let worldViewportWidth = viewport.width / zoomScale
        let worldViewportHeight = viewport.height / zoomScale
        setVisibleWorldOrigin(CGPoint(
            x: padded.midX - worldViewportWidth / 2,
            y: padded.midY - worldViewportHeight / 2
        ))
    }

    public func setZoom(_ newScale: CGFloat, centeredAt viewAnchor: CGPoint? = nil) {
        let clamped = max(0.1, min(4.0, newScale))
        guard abs(clamped - zoomScale) > 0.0001 else { return }
        let area = visibleRect.width > 0 ? visibleRect : bounds
        let anchor = viewAnchor ?? CGPoint(x: area.midX, y: area.midY)
        let anchorOffset = CGPoint(x: anchor.x - area.minX, y: anchor.y - area.minY)
        let anchorWorld = CGPoint(x: anchor.x / zoomScale + origin.x, y: anchor.y / zoomScale + origin.y)
        zoomScale = clamped
        let targetWorldOrigin = CGPoint(
            x: anchorWorld.x - anchorOffset.x / zoomScale,
            y: anchorWorld.y - anchorOffset.y / zoomScale
        )
        setVisibleWorldOrigin(targetWorldOrigin)
    }

    public func setVisibleWorldOrigin(_ targetWorldOrigin: CGPoint) {
        let viewportSize = enclosingScrollView?.contentView.bounds.size
            ?? (visibleRect.width > 0 ? visibleRect.size : bounds.size)
        let targetWorldRect = CGRect(
            x: targetWorldOrigin.x,
            y: targetWorldOrigin.y,
            width: viewportSize.width / zoomScale,
            height: viewportSize.height / zoomScale
        )
        var requiredWorld = CGRect(
            x: origin.x,
            y: origin.y,
            width: frame.width / zoomScale,
            height: frame.height / zoomScale
        ).union(targetWorldRect)
        for node in nodes {
            let radius = hypot(node.box.width, node.box.height) / 2 + 40
            requiredWorld = requiredWorld.union(CGRect(
                x: node.center.x - radius, y: node.center.y - radius,
                width: radius * 2, height: radius * 2
            ))
        }
        if let clip = enclosingScrollView?.contentView {
            origin = requiredWorld.origin
            setFrameSize(CGSize(
                width: max(viewportSize.width, ceil(requiredWorld.width * zoomScale)),
                height: max(viewportSize.height, ceil(requiredWorld.height * zoomScale))
            ))
            let scrollPoint = CGPoint(
                x: (targetWorldOrigin.x - origin.x) * zoomScale,
                y: (targetWorldOrigin.y - origin.y) * zoomScale
            )
            clip.scroll(to: scrollPoint)
            enclosingScrollView?.reflectScrolledClipView(clip)
        } else {
            origin = targetWorldOrigin
        }
        positionInlineTextEditor()
        positionStyleInspector()
        positionToolDock()
        positionAlignBar()
        positionStatusBanner()
        needsDisplay = true
    }

    private func registerUndoMove(_ id: String, to position: CanvasPosition) {
        registerUndoMoves([id], to: [id: position])
    }

    private func registerUndoMoves(_ ids: [String], to positions: [String: CanvasPosition]) {
        recordUndo("Move") { target in
            target.performHistoryMoves(ids, to: positions)
        }
    }

    private func recordUndo(_ name: String, action: @escaping (CanvasView) -> Void) {
        let needsGroup = !history.isUndoing && !history.isRedoing
        if needsGroup { history.beginUndoGrouping() }
        history.registerUndo(withTarget: self, handler: action)
        history.setActionName(name)
        if needsGroup { history.endUndoGrouping() }
    }

    private func performHistoryMoves(_ ids: [String], to positions: [String: CanvasPosition]) {
        var inverse: [String: CanvasPosition] = [:]
        for id in ids {
            if let current = session.position(of: id) {
                inverse[id] = current
            }
        }
        var moved: [String] = []
        for id in ids {
            guard let pos = positions[id] else { continue }
            if (try? moveWithoutHistory(id, to: pos)) != nil {
                moved.append(id)
            }
        }
        if !moved.isEmpty {
            registerUndoMoves(moved, to: inverse)
        }
    }

    private func moveWithoutHistory(_ id: String, to position: CanvasPosition) throws {
        guard try session.move(id, to: position) != nil else { return }
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].box.origin = CGPoint(x: position.x, y: position.y)
        rebuildEdges()
        needsDisplay = true
    }

    private func rebuildEdges() {
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        edges = (session.root["edges"] as? [[String: Any]] ?? []).compactMap { raw in
            guard let source = index[raw["source"] as? String ?? ""],
                  let target = index[raw["target"] as? String ?? ""] else { return nil }
            return Self.makeEdge(raw, source, target, role: fontRole)
        }
        expandDrawingBounds()
    }

    /// Grow without shrinking on Undo; preserve the visible world position.
    private func expandDrawingBounds() {
        var required = CGRect(
            x: origin.x,
            y: origin.y,
            width: frame.width / zoomScale,
            height: frame.height / zoomScale
        )
        for node in nodes {
            let radius = hypot(node.box.width, node.box.height) / 2 + 40
            required = required.union(CGRect(x: node.center.x - radius, y: node.center.y - radius,
                                             width: radius * 2, height: radius * 2))
        }
        for edge in edges {
            required = required.union(edge.path.bounds.insetBy(dx: -40, dy: -40))
            if let labelRect = edge.labelRect {
                required = required.union(labelRect.insetBy(dx: -20, dy: -20))
            }
        }
        if case .adjacentEditing(_, _, let geo, _, _) = inlineTextState {
            required = required.union(CGRect(x: geo.x, y: geo.y, width: geo.width, height: geo.height).insetBy(dx: -48, dy: -64))
        } else if case .newText(_, let geo, _, _) = inlineTextState {
            required = required.union(CGRect(x: geo.x, y: geo.y, width: geo.width, height: geo.height).insetBy(dx: -48, dy: -64))
        }
        let targetSize = CGSize(width: ceil(required.width * zoomScale), height: ceil(required.height * zoomScale))
        guard required.origin != origin || targetSize != frame.size else { return }
        let shift = CGPoint(x: (origin.x - required.minX) * zoomScale, y: (origin.y - required.minY) * zoomScale)
        let clip = enclosingScrollView?.contentView
        let previous = clip?.bounds.origin
        origin = required.origin
        setFrameSize(targetSize)
        if let clip, let previous {
            clip.scroll(to: CGPoint(x: previous.x + shift.x, y: previous.y + shift.y))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    private func worldPoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x / zoomScale + origin.x, y: point.y / zoomScale + origin.y)
    }

    public func viewPoint(forWorldPoint point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) * zoomScale, y: (point.y - origin.y) * zoomScale)
    }
    private func contains(_ location: CGPoint, node: Node) -> Bool {
        let angle = -node.rotation * .pi / 180
        let dx = location.x - node.center.x
        let dy = location.y - node.center.y
        let local = CGPoint(
            x: node.center.x + dx * cos(angle) - dy * sin(angle),
            y: node.center.y + dx * sin(angle) + dy * cos(angle)
        )
        if node.type == "shape-line" {
            return distance(local, toSegmentFrom: point(node.data["from"], in: node.box),
                            to: point(node.data["to"], in: node.box)) <= 8
        }
        let kind = node.type == "code" ? "rect" : node.kind
        let defaultRadius: CGFloat = (node.type == "code" || kind == "text") ? 0 : 8
        return outline(kind, node.box, number(node.data["radius"], defaultRadius)).contains(local)
    }

    private func contains(_ location: CGPoint, edge: EdgeDrawing) -> Bool {
        if let labelRect = edge.labelRect, labelRect.contains(location) {
            return true
        }
        for (start, end) in zip(edge.samples, edge.samples.dropFirst()) {
            if distance(location, toSegmentFrom: start, to: end) <= 8 {
                return true
            }
        }
        return false
    }

    private func drawSelection(_ node: Node) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: node.center.x, y: node.center.y)
        context.rotate(by: node.rotation * .pi / 180)
        context.translateBy(x: -node.center.x, y: -node.center.y)
        let path = NSBezierPath(rect: node.box.insetBy(dx: -5, dy: -5))
        CanvasTheme.selectionCobalt.setStroke()
        path.lineWidth = 2
        path.setLineDash([5, 3], count: 2, phase: 0)
        path.stroke()
        context.restoreGState()
        if session.canEditLineEndpoints(node.id), let lineGeometry = node.lineGeometry {
            for endpoint in CanvasLineEndpoint.allCases {
                let point = lineGeometry.point(for: endpoint)
                let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                let path = NSBezierPath(ovalIn: rect)
                let active = lineEndpointGesture?.endpoint == endpoint
                (active ? CanvasTheme.selectionCobalt : CanvasTheme.elevatedSurface).setFill()
                path.fill()
                CanvasTheme.selectionCobalt.setStroke()
                path.lineWidth = active ? 2 : 1.5
                path.stroke()
            }
            return
        }
        if session.canTransform(node.id) {
            let geometry = node.geometry
            let top = geometry.point(for: .top), rotate = geometry.point(for: .rotation)
            let stalk = NSBezierPath()
            stalk.move(to: CGPoint(x: top.x, y: top.y))
            stalk.line(to: CGPoint(x: rotate.x, y: rotate.y))
            stalk.lineWidth = 1
            CanvasTheme.selectionCobalt.setStroke()
            stalk.stroke()
            for handle in CanvasGeometryHandle.allCases {
                let point = geometry.point(for: handle)
                let rect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                let path = handle == .rotation ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
                let active = geometryGesture?.handle == handle
                (active ? CanvasTheme.selectionCobalt : CanvasTheme.elevatedSurface).setFill()
                path.fill()
                CanvasTheme.selectionCobalt.setStroke()
                path.lineWidth = active ? 2 : 1.5
                path.stroke()
            }
        }
        if !isReadOnly, node.type != "shape-line", !hasGeometryPreview, inlineTextState == nil, drag == nil, connectionDrag == nil {
            drawConnectionPorts(for: node, activeSide: nil)
        }
    }

    public func connectionPortWorldPoint(of nodeID: String, side: CanvasConnectionSide) -> CGPoint? {
        guard let node = nodes.first(where: { $0.id == nodeID }), node.type != "shape-line" else { return nil }
        return connectionPortPoint(for: node, side: side)
    }

    private func connectionPortPoint(for node: Node, side: CanvasConnectionSide) -> CGPoint {
        let base = Self.handle(node, side.rawValue)
        let isSelectedTransformable = selectedNodeIDs.count <= 1 && selectedID == node.id && session.canTransform(node.id)
        guard isSelectedTransformable else { return base }
        let dir = Self.direction(node, side.rawValue)
        let offset: CGFloat = side == .top ? 38 : 16
        return CGPoint(x: base.x + dir.x * offset, y: base.y + dir.y * offset)
    }

    private func containsNearNode(_ location: CGPoint, node: Node, padding: CGFloat) -> Bool {
        let angle = -node.rotation * .pi / 180
        let dx = location.x - node.center.x
        let dy = location.y - node.center.y
        let local = CGPoint(
            x: node.center.x + dx * cos(angle) - dy * sin(angle),
            y: node.center.y + dx * sin(angle) + dy * cos(angle)
        )
        return node.box.insetBy(dx: -padding, dy: -padding).contains(local)
    }

    private func connectionPort(at point: CGPoint, node: Node) -> CanvasConnectionSide? {
        guard node.type != "shape-line" else { return nil }
        var closest: CanvasConnectionSide?
        var bestDistance: CGFloat = 11.0
        for side in CanvasConnectionSide.allCases {
            let portPt = connectionPortPoint(for: node, side: side)
            let d = hypot(point.x - portPt.x, point.y - portPt.y)
            if d < bestDistance {
                bestDistance = d
                closest = side
            }
        }
        return closest
    }

    private func resolveConnectionDropTarget(
        at point: CGPoint,
        for drag: ConnectionDragGesture
    ) -> ConnectionDropTarget? {
        let fixedNodeID: String
        let fixedSide: CanvasConnectionSide?
        switch drag.mode {
        case .create(let sourceID, let sourceSide):
            fixedNodeID = sourceID
            fixedSide = sourceSide
        case .reconnect(let edgeID, let draggingTarget):
            guard let state = session.connectionState(of: edgeID) else { return nil }
            if draggingTarget {
                fixedNodeID = state.source
                fixedSide = state.sourceSide
            } else {
                fixedNodeID = state.target
                fixedSide = state.targetSide
            }
        }
        let effectiveFixedSideForSelfLoop: CanvasConnectionSide? = fixedSide ?? {
            guard let fixedNode = nodes.first(where: { $0.id == fixedNodeID }) else { return nil }
            return CanvasConnectionSide(rawValue: Self.nearestSide(fixedNode, drag.startPoint))
        }()

        var bestPort: (nodeID: String, side: CanvasConnectionSide, distance: CGFloat)?
        for node in nodes.reversed() where node.type != "shape-line" {
            for side in CanvasConnectionSide.allCases {
                let handlePt = Self.handle(node, side.rawValue)
                let portPt = connectionPortPoint(for: node, side: side)
                let d = min(
                    hypot(point.x - handlePt.x, point.y - handlePt.y),
                    hypot(point.x - portPt.x, point.y - portPt.y)
                )
                if d <= 14.0 {
                    if node.id == fixedNodeID {
                        guard hypot(point.x - drag.startPoint.x, point.y - drag.startPoint.y) >= 12.0,
                              let fixed = effectiveFixedSideForSelfLoop,
                              fixed != side else { continue }
                    }
                    if bestPort == nil || d < bestPort!.distance {
                        bestPort = (node.id, side, d)
                    }
                }
            }
        }
        if let bestPort {
            return ConnectionDropTarget(nodeID: bestPort.nodeID, side: bestPort.side)
        }
        if let hitNode = nodes.reversed().first(where: { $0.type != "shape-line" && contains(point, node: $0) }) {
            if hitNode.id == fixedNodeID {
                guard hypot(point.x - drag.startPoint.x, point.y - drag.startPoint.y) >= 24.0,
                      let fixed = effectiveFixedSideForSelfLoop,
                      let candidateSide = CanvasConnectionSide(rawValue: Self.nearestSide(hitNode, point)),
                      candidateSide != fixed else {
                    return nil
                }
                return ConnectionDropTarget(nodeID: hitNode.id, side: candidateSide)
            } else {
                return ConnectionDropTarget(nodeID: hitNode.id, side: nil)
            }
        }
        return nil
    }

    private func commitConnectionDrag(_ drag: ConnectionDragGesture, at point: CGPoint) {
        guard drag.hasDragged,
              hypot(point.x - drag.startPoint.x, point.y - drag.startPoint.y) >= 4.0 else {
            switch drag.mode {
            case .create(let sourceID, _):
                selectSingleNode(sourceID)
                refreshStyleInspector()
            case .reconnect(let edgeID, _):
                selectSingleConnection(edgeID)
            }
            needsDisplay = true
            return
        }
        guard let target = resolveConnectionDropTarget(at: point, for: drag) else {
            needsDisplay = true
            return
        }
        do {
            switch drag.mode {
            case .create(let sourceID, let rawSourceSide):
                let effectiveSourceSide: CanvasConnectionSide?
                if target.nodeID == sourceID {
                    effectiveSourceSide = rawSourceSide ?? nodes.first(where: { $0.id == sourceID }).flatMap {
                        CanvasConnectionSide(rawValue: Self.nearestSide($0, drag.startPoint))
                    }
                } else {
                    effectiveSourceSide = rawSourceSide
                }
                let insertion = try session.insertConnection(
                    source: sourceID,
                    sourceSide: effectiveSourceSide,
                    target: target.nodeID,
                    targetSide: target.side,
                    label: nil
                )
                selectSingleConnection(insertion.id)
                rebuildEdges()
                refreshStyleInspector()
                needsDisplay = true
                registerUndoConnection(insertion, restoring: false, actionName: "Connect")
            case .reconnect(let edgeID, let draggingTarget):
                guard let existing = session.connectionState(of: edgeID) else {
                    needsDisplay = true
                    return
                }
                let newSource: String
                let newSourceSide: CanvasConnectionSide?
                let newTarget: String
                let newTargetSide: CanvasConnectionSide?
                if draggingTarget {
                    newSource = existing.source
                    newTarget = target.nodeID
                    newTargetSide = target.side
                    if newSource == newTarget {
                        newSourceSide = existing.sourceSide ?? nodes.first(where: { $0.id == newSource }).flatMap {
                            CanvasConnectionSide(rawValue: Self.nearestSide($0, drag.startPoint))
                        }
                    } else {
                        newSourceSide = existing.sourceSide
                    }
                } else {
                    newSource = target.nodeID
                    newSourceSide = target.side
                    newTarget = existing.target
                    if newSource == newTarget {
                        newTargetSide = existing.targetSide ?? nodes.first(where: { $0.id == newTarget }).flatMap {
                            CanvasConnectionSide(rawValue: Self.nearestSide($0, drag.startPoint))
                        }
                    } else {
                        newTargetSide = existing.targetSide
                    }
                }
                if let update = try session.updateConnection(
                    edgeID,
                    source: newSource,
                    sourceSide: newSourceSide,
                    target: newTarget,
                    targetSide: newTargetSide,
                    label: existing.label
                ) {
                    selectSingleConnection(edgeID)
                    rebuildEdges()
                    refreshStyleInspector()
                    needsDisplay = true
                    registerUndoConnectionUpdate(update)
                } else {
                    selectSingleConnection(edgeID)
                    needsDisplay = true
                }
            }
        } catch {
            NSSound.beep()
            needsDisplay = true
        }
    }

    private func drawConnectionPorts(for node: Node, activeSide: CanvasConnectionSide?) {
        let isSelectedTransformable = selectedNodeIDs.count <= 1 && selectedID == node.id && session.canTransform(node.id)
        for side in CanvasConnectionSide.allCases {
            let base = Self.handle(node, side.rawValue)
            let portPt = connectionPortPoint(for: node, side: side)
            if isSelectedTransformable && side != .top {
                let stem = NSBezierPath()
                stem.move(to: base)
                stem.line(to: portPt)
                stem.lineWidth = 1
                CanvasTheme.selectionCobalt.withAlphaComponent(0.6).setStroke()
                stem.stroke()
            }
            let isActive = activeSide == side
            let r: CGFloat = isActive ? 5.5 : 4.5
            let oval = NSBezierPath(ovalIn: CGRect(x: portPt.x - r, y: portPt.y - r, width: r * 2, height: r * 2))
            (isActive ? CanvasTheme.selectionCobalt : CanvasTheme.elevatedSurface).setFill()
            oval.fill()
            CanvasTheme.selectionCobalt.setStroke()
            oval.lineWidth = isActive ? 2 : 1.5
            oval.stroke()
        }
    }

    private func drawConnectionDragPreview(_ drag: ConnectionDragGesture) {
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        for node in nodes where node.type != "shape-line" {
            let activeSide: CanvasConnectionSide? = (drag.target?.nodeID == node.id) ? drag.target?.side : nil
            drawConnectionPorts(for: node, activeSide: activeSide)
        }
        if let target = drag.target, let targetNode = index[target.nodeID] {
            drawFocusedNodeOutline(targetNode)
            let sourceID: String
            let sourceSide: String?
            let targetID: String
            let targetSide: String?
            var rawEdge: [String: Any] = ["id": "__preview__", "path": "bezier", "marker": "arrow"]
            switch drag.mode {
            case .create(let sid, let sSide):
                sourceID = sid
                targetID = target.nodeID
                if sourceID == targetID {
                    sourceSide = sSide?.rawValue ?? index[sid].map { Self.nearestSide($0, drag.startPoint) }
                } else {
                    sourceSide = sSide?.rawValue
                }
                targetSide = target.side?.rawValue
            case .reconnect(let edgeID, let draggingTarget):
                if let existingRaw = (session.root["edges"] as? [[String: Any]])?.first(where: { $0["id"] as? String == edgeID }) {
                    rawEdge = existingRaw
                }
                guard let state = session.connectionState(of: edgeID) else { return }
                if draggingTarget {
                    sourceID = state.source
                    sourceSide = state.sourceSide?.rawValue
                    targetID = target.nodeID
                    targetSide = target.side?.rawValue
                } else {
                    sourceID = target.nodeID
                    sourceSide = target.side?.rawValue
                    targetID = state.target
                    targetSide = state.targetSide?.rawValue
                }
            }
            if let sNode = index[sourceID], let tNode = index[targetID] {
                rawEdge["source"] = sourceID
                rawEdge["target"] = targetID
                if let sourceSide { rawEdge["source_handle"] = sourceSide } else { rawEdge.removeValue(forKey: "source_handle") }
                if let targetSide { rawEdge["target_handle"] = targetSide } else { rawEdge.removeValue(forKey: "target_handle") }
                let previewEdge = Self.makeEdge(rawEdge, sNode, tNode, role: fontRole)
                Self.drawEdge(previewEdge, role: fontRole, isSelected: true)
                return
            }
        }
        let anchorPoint: CGPoint
        let arrowFrom: CGPoint
        let arrowAt: CGPoint
        switch drag.mode {
        case .create(let sourceID, let sourceSide):
            if let sourceNode = index[sourceID] {
                let side = sourceSide?.rawValue ?? Self.nearestSide(sourceNode, drag.currentPoint)
                anchorPoint = Self.handle(sourceNode, side)
            } else {
                anchorPoint = drag.startPoint
            }
            arrowFrom = anchorPoint
            arrowAt = drag.currentPoint
        case .reconnect(let edgeID, let draggingTarget):
            if let state = session.connectionState(of: edgeID) {
                if draggingTarget, let sourceNode = index[state.source] {
                    let side = state.sourceSide?.rawValue ?? Self.nearestSide(sourceNode, drag.currentPoint)
                    anchorPoint = Self.handle(sourceNode, side)
                    arrowFrom = anchorPoint
                    arrowAt = drag.currentPoint
                } else if !draggingTarget, let targetNode = index[state.target] {
                    let side = state.targetSide?.rawValue ?? Self.nearestSide(targetNode, drag.currentPoint)
                    anchorPoint = Self.handle(targetNode, side)
                    arrowFrom = drag.currentPoint
                    arrowAt = anchorPoint
                } else {
                    anchorPoint = drag.startPoint
                    arrowFrom = anchorPoint
                    arrowAt = drag.currentPoint
                }
            } else {
                anchorPoint = drag.startPoint
                arrowFrom = anchorPoint
                arrowAt = drag.currentPoint
            }
        }
        let wire = NSBezierPath()
        wire.move(to: anchorPoint)
        wire.line(to: drag.currentPoint)
        wire.lineWidth = 2
        wire.setLineDash([6, 4], count: 2, phase: 0)
        CanvasTheme.selectionCobalt.setStroke()
        wire.stroke()
        if hypot(arrowAt.x - arrowFrom.x, arrowAt.y - arrowFrom.y) > 4 {
            drawArrow(at: arrowAt, from: arrowFrom, color: CanvasTheme.selectionCobalt)
        }
    }

    private func drawMultiSelectionOutline(_ node: Node, isFocused: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: node.center.x, y: node.center.y)
        context.rotate(by: node.rotation * .pi / 180)
        context.translateBy(x: -node.center.x, y: -node.center.y)
        let path = NSBezierPath(rect: node.box.insetBy(dx: -5, dy: -5))
        CanvasTheme.selectionCobalt.setStroke()
        path.lineWidth = isFocused ? 2.5 : 2
        path.setLineDash([5, 3], count: 2, phase: 0)
        path.stroke()
        context.restoreGState()
    }

    private func drawFocusedNodeOutline(_ node: Node) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: node.center.x, y: node.center.y)
        context.rotate(by: node.rotation * .pi / 180)
        context.translateBy(x: -node.center.x, y: -node.center.y)
        let path = NSBezierPath(rect: node.box.insetBy(dx: -3, dy: -3))
        CanvasTheme.selectionCobalt.withAlphaComponent(0.75).setStroke()
        path.lineWidth = 1.5
        path.setLineDash([2, 2], count: 2, phase: 0)
        path.stroke()
        context.restoreGState()
    }

    private func drawInlineTextPreview(_ state: InlineTextState) {
        switch state {
        case .adjacentChoosing(let sourceID):
            guard let node = nodes.first(where: { $0.id == sourceID }) else { return }
            let b = node.geometry.rotatedAxisAlignedBounds
            let rect = CGRect(x: b.x, y: b.y, width: b.width, height: b.height).insetBy(dx: -8, dy: -8)
            let path = NSBezierPath(rect: rect)
            CanvasTheme.selectionCobalt.setStroke()
            path.lineWidth = 2
            path.setLineDash([4, 4], count: 2, phase: 0)
            path.stroke()
        case .adjacentEditing(_, _, let geo, _, _),
             .newText(_, let geo, _, _):
            let box = CGRect(x: geo.x, y: geo.y, width: geo.width, height: geo.height)
            CanvasTheme.canvasBackground.setFill()
            box.fill()
            let border = NSBezierPath(rect: box)
            CanvasTheme.selectionCobalt.setStroke()
            border.lineWidth = 2
            border.setLineDash([6, 4], count: 2, phase: 0)
            border.stroke()
        case .shapeCaption:
            break
        }
    }

    private func drawInlineTextHelp(_ state: InlineTextState) {
        switch state {
        case .adjacentChoosing:
            drawHelpBanner("Adjacent thought · Choose ↑ → ↓ ← · Escape: cancel · No automatic link")
        case .adjacentEditing(_, _, _, _, let error):
            if let error {
                drawHelpBanner("\(error)\nShorten text or press Escape to cancel; nothing was added.")
            } else {
                drawHelpBanner("Thought draft — not added · Return: add · Shift-Return: newline · Escape: cancel")
            }
        case .newText(_, _, _, let error):
            if let error {
                drawHelpBanner("\(error)\nShorten text or press Escape to cancel; nothing was added.")
            } else {
                drawHelpBanner("Text draft — not added · Return: add · Shift-Return: newline · Escape: cancel")
            }
        case .shapeCaption(_, _, _, _, _, let error):
            if let error {
                drawHelpBanner("\(error)\nShorten text or press Escape to cancel; nothing was changed.")
            } else {
                drawHelpBanner("Editing text · Return / ⌘Return: done · Shift-Return: newline · Escape: cancel")
            }
        }
    }

    private func geometryHandle(at point: CGPoint, node: Node) -> CanvasGeometryHandle? {
        var closest: CanvasGeometryHandle?
        var distance = 9.0
        let geometry = node.geometry
        for handle in CanvasGeometryHandle.allCases {
            let location = geometry.point(for: handle)
            let candidate = hypot(point.x - location.x, point.y - location.y)
            if candidate < distance { distance = candidate; closest = handle }
        }
        return closest
    }

    private func lineEndpointHandle(at point: CGPoint, lineGeometry: CanvasLineGeometry) -> CanvasLineEndpoint? {
        var closest: CanvasLineEndpoint?
        var distance = 9.0
        for endpoint in CanvasLineEndpoint.allCases {
            let location = lineGeometry.point(for: endpoint)
            let candidate = hypot(point.x - location.x, point.y - location.y)
            if candidate < distance { distance = candidate; closest = endpoint }
        }
        return closest
    }

    private func drawGeometryHelp(_ handle: CanvasGeometryHandle) {
        let name: String
        switch handle {
        case .topLeft: name = "Top left"
        case .top: name = "Top"
        case .topRight: name = "Top right"
        case .right: name = "Right"
        case .bottomRight: name = "Bottom right"
        case .bottom: name = "Bottom"
        case .bottomLeft: name = "Bottom left"
        case .left: name = "Left"
        case .rotation: name = "Rotation"
        }
        drawHelpBanner("\(name) · Tab / Shift-Tab: handles · Arrows: preview\nShift: larger steps · Return: commit · Escape: cancel")
    }

    private func drawLineEndpointHelp(_ endpoint: CanvasLineEndpoint) {
        let name = endpoint == .start ? "Start endpoint" : "End endpoint"
        drawHelpBanner("\(name) · Tab / Shift-Tab: endpoints · Arrows: preview\nShift: 10 units · Return: commit · Escape: cancel")
    }

    private func drawHelpBanner(_ text: String) {
        let width = max(1, min(560, visibleRect.width - 24))
        let rect = CGRect(x: visibleRect.minX + 12, y: visibleRect.minY + 12, width: width, height: 54)
        let pill = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        CanvasTheme.elevatedSurface.setFill()
        pill.fill()
        CanvasTheme.borderSubtle.setStroke()
        pill.lineWidth = 1
        pill.stroke()
        (text as NSString).draw(in: rect.insetBy(dx: 8, dy: 6),
                               withAttributes: [.font: NSFont.systemFont(ofSize: 12),
                                                .foregroundColor: CanvasTheme.primaryText])
    }

    private func drawPaper(_ dirty: CGRect) {
        let background = paper["background"] as? String ?? "dots"
        guard background != "none" else { return }
        let grid = max(4, number(paper["grid"], 20))
        let path = NSBezierPath()
        CanvasTheme.mutedText.withAlphaComponent(0.32).setStroke()
        CanvasTheme.mutedText.withAlphaComponent(0.4).setFill()
        var x = floor(dirty.minX / grid) * grid
        while x <= dirty.maxX {
            if background == "lines" {
                path.move(to: CGPoint(x: x, y: dirty.minY)); path.line(to: CGPoint(x: x, y: dirty.maxY))
            } else {
                var y = floor(dirty.minY / grid) * grid
                while y <= dirty.maxY {
                    if background == "cross" {
                        path.move(to: CGPoint(x: x - 2, y: y)); path.line(to: CGPoint(x: x + 2, y: y))
                        path.move(to: CGPoint(x: x, y: y - 2)); path.line(to: CGPoint(x: x, y: y + 2))
                    } else { NSBezierPath(ovalIn: CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)).fill() }
                    y += grid
                }
            }
            x += grid
        }
        if background == "lines" {
            var y = floor(dirty.minY / grid) * grid
            while y <= dirty.maxY {
                path.move(to: CGPoint(x: dirty.minX, y: y)); path.line(to: CGPoint(x: dirty.maxX, y: y)); y += grid
            }
        }
        path.lineWidth = 0.5; path.stroke()
    }

    private static func contentWorldBounds(nodes: [Node], edges: [EdgeDrawing], role: String) -> CGRect {
        guard !nodes.isEmpty else { return .null }
        var bounds = CGRect.null
        for node in nodes {
            let angle = node.rotation * .pi / 180
            let cosA = cos(angle)
            let sinA = sin(angle)
            func rotatePoint(_ p: CGPoint) -> CGPoint {
                let dx = p.x - node.center.x
                let dy = p.y - node.center.y
                return CGPoint(
                    x: node.center.x + dx * cosA - dy * sinA,
                    y: node.center.y + dx * sinA + dy * cosA
                )
            }
            if node.type == "shape-line" {
                let from = point(node.data["from"], in: node.box)
                let to = point(node.data["to"], in: node.box)
                let strokePad = max(1, number(node.data["width"], 2)) / 2
                var pts: [CGPoint] = [from, to]
                let arrow = node.data["arrow"] as? String ?? "end"
                if arrow == "end" || arrow == "both" {
                    let a = atan2(to.y - from.y, to.x - from.x)
                    pts.append(CGPoint(x: to.x - 10 * cos(a - 0.48), y: to.y - 10 * sin(a - 0.48)))
                    pts.append(CGPoint(x: to.x - 10 * cos(a + 0.48), y: to.y - 10 * sin(a + 0.48)))
                }
                if arrow == "both" {
                    let a = atan2(from.y - to.y, from.x - to.x)
                    pts.append(CGPoint(x: from.x - 10 * cos(a - 0.48), y: from.y - 10 * sin(a - 0.48)))
                    pts.append(CGPoint(x: from.x - 10 * cos(a + 0.48), y: from.y - 10 * sin(a + 0.48)))
                }
                for p in pts.map(rotatePoint) {
                    bounds = bounds.union(
                        CGRect(x: p.x - strokePad, y: p.y - strokePad, width: strokePad * 2, height: strokePad * 2)
                    )
                }
            } else {
                let kind = node.type == "code" ? "rect" : node.kind
                let defaultStroke = node.type == "code" ? "ink" : (kind == "text" ? "none" : "blue")
                let strokeName = node.data["stroke"] as? String ?? defaultStroke
                let strokeWidth: CGFloat = strokeName == "none" ? 0 : max(0, number(node.data["width"], 2))
                let strokePad = strokeWidth / 2
                let defaultRadius: CGFloat = (node.type == "code" || kind == "text") ? 0 : 8
                let shapePath = outline(kind, node.box, number(node.data["radius"], defaultRadius))
                var transform = CGAffineTransform(translationX: node.center.x, y: node.center.y)
                    .rotated(by: angle)
                    .translatedBy(x: -node.center.x, y: -node.center.y)
                if let rotatedPath = shapePath.cgPath.copy(using: &transform) {
                    let pathBox = rotatedPath.boundingBoxOfPath
                    if !pathBox.isNull {
                        bounds = bounds.union(pathBox.insetBy(dx: -strokePad, dy: -strokePad))
                    }
                    if strokeWidth > 0 {
                        let stroked = rotatedPath.copy(
                            strokingWithWidth: strokeWidth,
                            lineCap: .butt,
                            lineJoin: .miter,
                            miterLimit: shapePath.miterLimit
                        )
                        let strokedBox = stroked.boundingBoxOfPath
                        if !strokedBox.isNull && !strokedBox.isEmpty {
                            bounds = bounds.union(strokedBox)
                        }
                    }
                }
                var local = node.box.insetBy(dx: -strokePad, dy: -strokePad)
                if !nodeText(node).isEmpty {
                    local = local.union(textRect(node, role: role))
                }
                let corners = [
                    CGPoint(x: local.minX, y: local.minY),
                    CGPoint(x: local.maxX, y: local.minY),
                    CGPoint(x: local.maxX, y: local.maxY),
                    CGPoint(x: local.minX, y: local.maxY),
                ].map(rotatePoint)
                for c in corners {
                    bounds = bounds.union(CGRect(x: c.x, y: c.y, width: 0, height: 0))
                }
            }
        }
        for edge in edges {
            let width = edge.style["width"] as? NSNumber
            let validWidth = width != nil && CFGetTypeID(width!) != CFBooleanGetTypeID() &&
                !["f", "d"].contains(String(cString: width!.objCType)) && [1, 2, 4].contains(width!.intValue)
            let strokeWidth = validWidth ? CGFloat(width!.intValue) : 2.0
            let strokePad = strokeWidth / 2.0
            let cgPath = edge.path.cgPath
            let exactCurveBox = cgPath.boundingBoxOfPath
            if !exactCurveBox.isNull {
                bounds = bounds.union(exactCurveBox.insetBy(dx: -strokePad, dy: -strokePad))
            }
            let strokedEdge = cgPath.copy(
                strokingWithWidth: strokeWidth,
                lineCap: .butt,
                lineJoin: .miter,
                miterLimit: edge.path.miterLimit
            )
            let strokedEdgeBox = strokedEdge.boundingBoxOfPath
            if !strokedEdgeBox.isNull && !strokedEdgeBox.isEmpty {
                bounds = bounds.union(strokedEdgeBox)
            }
            for sample in edge.samples {
                bounds = bounds.union(
                    CGRect(x: sample.x - strokePad, y: sample.y - strokePad, width: strokePad * 2, height: strokePad * 2)
                )
            }
            if edge.marker == "arrow" {
                let a = atan2(edge.end.y - edge.previous.y, edge.end.x - edge.previous.x)
                let p1 = CGPoint(x: edge.end.x - 10 * cos(a - 0.48), y: edge.end.y - 10 * sin(a - 0.48))
                let p2 = CGPoint(x: edge.end.x - 10 * cos(a + 0.48), y: edge.end.y - 10 * sin(a + 0.48))
                for p in [edge.end, p1, p2] {
                    bounds = bounds.union(CGRect(x: p.x, y: p.y, width: 0, height: 0))
                }
            } else if edge.marker == "dot" {
                bounds = bounds.union(CGRect(x: edge.end.x - 4, y: edge.end.y - 4, width: 8, height: 8))
            }
            if let labelRect = edge.labelRect {
                bounds = bounds.union(labelRect.insetBy(dx: -1, dy: -1))
            }
        }
        return bounds
    }

    private static func effectiveAlignment(data: [String: Any], kind: String, defaultAlign: String?) -> String {
        if let nodeAlign = data["align"] as? String {
            return nodeAlign
        }
        if let defaultAlign {
            return defaultAlign
        }
        return kind == "text" ? "left" : "center"
    }

    private static func drawNode(_ node: Node, role fontRole: String, defaultAlign: String? = nil, hideCaption: Bool) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: node.center.x, y: node.center.y)
        context.rotate(by: node.rotation * .pi / 180)
        context.translateBy(x: -node.center.x, y: -node.center.y)
        let data = node.data
        if node.type == "shape-line" {
            let from = point(data["from"], in: node.box)
            let to = point(data["to"], in: node.box)
            let path = NSBezierPath(); path.move(to: from); path.line(to: to)
            let color = palette(data["stroke"] as? String ?? "ink")
            color.setStroke(); configure(path, data); path.stroke()
            let arrow = data["arrow"] as? String ?? "end"
            if arrow == "end" || arrow == "both" { drawArrow(at: to, from: from, color: color) }
            if arrow == "both" { drawArrow(at: from, from: to, color: color) }
        } else {
            let kind = node.type == "code" ? "rect" : node.kind
            let defaultRadius: CGFloat = (node.type == "code" || kind == "text") ? 0 : 8
            let path = outline(kind, node.box, number(node.data["radius"], defaultRadius))
            let defaultFill = (node.type == "code" || kind == "text") ? "none" : "blue"
            let fill = data["fill"] as? String ?? defaultFill
            palette(fill).setFill(); path.fill()
            let defaultStroke = node.type == "code" ? "ink" : (kind == "text" ? "none" : "blue")
            palette(data["stroke"] as? String ?? defaultStroke).setStroke()
            configure(path, data); path.stroke()
            if !hideCaption {
                let text = nodeText(node)
                let role = node.type == "code" ? "mono" : (data["font"] as? String ?? fontRole)
                let rect = textRect(node, role: fontRole)
                let style = NSMutableParagraphStyle()
                style.alignment = node.type == "code" ? .left : alignment(effectiveAlignment(data: data, kind: kind, defaultAlign: defaultAlign))
                style.lineBreakMode = .byWordWrapping
                let attrs: [NSAttributedString.Key: Any] = [.font: font(role, data["size"] as? String ?? "m"), .foregroundColor: textColor(on: fill), .paragraphStyle: style]
                (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
            }
        }
        context.restoreGState()
    }

    private static func drawEdge(_ edge: EdgeDrawing, role fontRole: String, isSelected: Bool) {
        let color = isSelected ? CanvasTheme.selectionCobalt : palette(edge.style["stroke"] as? String ?? "ink")
        let width = edge.style["width"] as? NSNumber
        let validWidth = width != nil && CFGetTypeID(width!) != CFBooleanGetTypeID() &&
            !["f", "d"].contains(String(cString: width!.objCType)) && [1, 2, 4].contains(width!.intValue)
        let pathCopy = edge.path.copy() as! NSBezierPath
        color.setStroke(); pathCopy.lineWidth = validWidth ? CGFloat(width!.intValue) : 2
        let dash = edge.style["dash"] as? NSNumber
        let dashed = dash != nil && CFGetTypeID(dash!) == CFBooleanGetTypeID() ? dash!.boolValue : edge.animated
        if dashed { pathCopy.setLineDash([6, 4], count: 2, phase: 0) }
        pathCopy.stroke()
        if edge.marker == "arrow" { drawArrow(at: edge.end, from: edge.previous, color: color) }
        if edge.marker == "dot" { color.setFill(); NSBezierPath(ovalIn: CGRect(x: edge.end.x - 4, y: edge.end.y - 4, width: 8, height: 8)).fill() }
        if !edge.label.isEmpty {
            let size = labelSize(edge.label, role: fontRole)
            let rect = CGRect(x: edge.labelPoint.x - size.width / 2, y: edge.labelPoint.y - size.height / 2, width: size.width, height: size.height)
            let pill = rect.insetBy(dx: -5, dy: -2)
            CanvasTheme.elevatedSurface.setFill()
            pill.fill()
            let pillBorder = NSBezierPath(rect: pill)
            pillBorder.lineWidth = isSelected ? 1.5 : 1
            (isSelected ? CanvasTheme.selectionCobalt : CanvasTheme.borderSubtle).setStroke()
            pillBorder.stroke()
            (edge.label as NSString).draw(in: rect, withAttributes: [.font: font(fontRole, "m"), .foregroundColor: CanvasTheme.primaryText])
        }
        if isSelected {
            for endpoint in [edge.samples.first ?? edge.end, edge.end] {
                let handleRect = CGRect(x: endpoint.x - 4, y: endpoint.y - 4, width: 8, height: 8)
                let handlePath = NSBezierPath(rect: handleRect)
                CanvasTheme.elevatedSurface.setFill()
                handlePath.fill()
                CanvasTheme.selectionCobalt.setStroke()
                handlePath.lineWidth = 1.5
                handlePath.stroke()
            }
        }
    }

    private static func nodeText(_ node: Node) -> String {
        if node.type == "code" { return node.data["content"] as? String ?? "" }
        let text = node.data["text"] as? String ?? ""
        guard let attachment = node.data["attachment"] as? [String: Any], let name = attachment["filename"] as? String else { return text }
        return text.isEmpty || text == name ? name : text + "\n" + name
    }

    private static func measuredBoxHeight(for node: Node, text: String, role: String) -> CGFloat {
        guard node.type == "shape" else { return node.box.height }
        let inset: CGFloat = 10
        let width = max(1, node.box.width - inset * 2)
        var display = text
        if let attachment = node.data["attachment"] as? [String: Any],
           let name = attachment["filename"] as? String {
            display = text.isEmpty || text == name ? name : text + "\n" + name
        }
        guard !display.isEmpty else { return node.box.height }
        let selectedRole = node.data["font"] as? String ?? role
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let measured = (display as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font(selectedRole, node.data["size"] as? String ?? "m"),
                .paragraphStyle: paragraph
            ]
        )
        return ceil(measured.height) + 2 + inset * 2
    }

    private static func textRect(_ node: Node, role: String) -> CGRect {
        if node.type == "shape-line" { return node.box }
        let inset: CGFloat = 10
        let width = max(1, node.box.width - inset * 2)
        let text = nodeText(node)
        let selectedRole = node.type == "code" ? "mono" : (node.data["font"] as? String ?? role)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
        let measured = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font(selectedRole, node.data["size"] as? String ?? "m"), .paragraphStyle: paragraph])
        let height = max(ceil(measured.height) + 2, 1)
        let y = node.type == "code" ? node.box.minY + inset : node.box.midY - min(height, node.box.height - inset * 2) / 2
        return CGRect(x: node.box.minX + inset, y: y, width: width, height: height)
    }

    private static func labelSize(_ text: String, role: String) -> CGSize {
        let rect = (text as NSString).boundingRect(with: CGSize(width: 400, height: CGFloat.greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font(role, "m")])
        return CGSize(width: ceil(rect.width) + 2, height: ceil(rect.height) + 2)
    }

    public func edgeSamples(of id: String) -> [CGPoint]? {
        edges.first(where: { $0.id == id })?.samples
    }

    public func edgeLabelPoint(of id: String) -> CGPoint? {
        edges.first(where: { $0.id == id })?.labelPoint
    }

    public func edgeTargetTangent(of id: String) -> CGPoint? {
        guard let edge = edges.first(where: { $0.id == id }) else { return nil }
        let dx = edge.end.x - edge.previous.x
        let dy = edge.end.y - edge.previous.y
        let len = hypot(dx, dy)
        guard len > 0.0001 else { return nil }
        return CGPoint(x: dx / len, y: dy / len)
    }

    private static func makeEdge(_ raw: [String: Any], _ source: Node, _ target: Node, role: String) -> EdgeDrawing {
        let fromSide = raw["source_handle"] as? String ?? nearestSide(source, target.center)
        let toSide = raw["target_handle"] as? String ?? nearestSide(target, source.center)
        let a = handle(source, fromSide), b = handle(target, toSide)
        let style = raw["path"] as? String ?? "bezier"
        let label = raw["label"] as? String ?? ""
        let path = NSBezierPath(); path.move(to: a)
        var samples: [CGPoint] = [a]
        var previous = a
        var labelPoint = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        if source.id == target.id {
            let rotated = source.geometry.rotatedAxisAlignedBounds
            let visualBox = source.box.union(
                CGRect(x: rotated.x, y: rotated.y, width: rotated.width, height: rotated.height)
            )
            let outer = visualBox.insetBy(dx: -48, dy: -48)
            func exit(_ p: CGPoint) -> (CGPoint, Int) {
                let dx = p.x - source.center.x, dy = p.y - source.center.y
                let tx = dx > 0 ? (outer.maxX - source.center.x) / dx : dx < 0 ? (outer.minX - source.center.x) / dx : CGFloat.infinity
                let ty = dy > 0 ? (outer.maxY - source.center.y) / dy : dy < 0 ? (outer.minY - source.center.y) / dy : CGFloat.infinity
                let scale = min(tx, ty)
                return (
                    CGPoint(x: source.center.x + dx * scale, y: source.center.y + dy * scale),
                    tx < ty ? (dx > 0 ? 1 : 3) : (dy > 0 ? 2 : 0)
                )
            }
            let (start, s) = exit(a), (finish, t) = exit(b)
            let corners = [
                CGPoint(x: outer.minX, y: outer.minY),
                CGPoint(x: outer.maxX, y: outer.minY),
                CGPoint(x: outer.maxX, y: outer.maxY),
                CGPoint(x: outer.minX, y: outer.maxY)
            ]
            func route(_ direction: Int) -> [CGPoint] {
                var rawPoints = [a, start]
                var side = s
                while side != t {
                    rawPoints.append(corners[(side + (direction == 1 ? 1 : 0)) % 4])
                    side = (side + direction + 4) % 4
                }
                rawPoints.append(finish)
                rawPoints.append(b)
                var filtered: [CGPoint] = []
                for pt in rawPoints {
                    if let last = filtered.last, hypot(pt.x - last.x, pt.y - last.y) <= 0.001 {
                        continue
                    }
                    filtered.append(pt)
                }
                return filtered
            }
            func length(_ points: [CGPoint]) -> CGFloat {
                zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            }
            let clockwise = route(1), counter = route(-1)
            let points = length(clockwise) <= length(counter) ? clockwise : counter
            let cornerRadius: CGFloat = (style == "step" || style == "straight") ? 0 : 16
            samples = appendRoundedPolyline(points, cornerRadius: cornerRadius, to: path)
            previous = points.count >= 2 ? points[points.count - 2] : a
            labelPoint = midpointAlongPolyline(points)
            if !label.isEmpty {
                let size = labelSize(label, role: role)
                let pillWidth = size.width + 10
                let pillHeight = size.height + 4
                if abs(labelPoint.x - source.center.x) > abs(labelPoint.y - source.center.y) {
                    labelPoint.x = labelPoint.x > source.center.x
                        ? max(labelPoint.x, visualBox.maxX + pillWidth / 2 + 12)
                        : min(labelPoint.x, visualBox.minX - pillWidth / 2 - 12)
                } else {
                    labelPoint.y = labelPoint.y > source.center.y
                        ? max(labelPoint.y, visualBox.maxY + pillHeight / 2 + 12)
                        : min(labelPoint.y, visualBox.minY - pillHeight / 2 - 12)
                }
            }
        } else {
            let v1 = direction(source, fromSide), v2 = direction(target, toSide)
            let distance = max(40, hypot(b.x - a.x, b.y - a.y) / 2)
            let c1 = CGPoint(x: a.x + v1.x * distance, y: a.y + v1.y * distance)
            let c2 = CGPoint(x: b.x + v2.x * distance, y: b.y + v2.y * distance)
            if style == "straight" {
                path.line(to: b)
                samples = [a, b]
            } else if style == "step" || style == "smooth" {
                let n1 = cardinalDirection(source, fromSide)
                let n2 = cardinalDirection(target, toSide)
                let sRot = source.geometry.rotatedAxisAlignedBounds
                let tRot = target.geometry.rotatedAxisAlignedBounds
                let sBox = source.box.union(CGRect(x: sRot.x, y: sRot.y, width: sRot.width, height: sRot.height))
                let tBox = target.box.union(CGRect(x: tRot.x, y: tRot.y, width: tRot.width, height: tRot.height))
                let points = orthogonalStepPoints(
                    from: a, startDir: n1, sourceBox: sBox,
                    to: b, endDir: n2, targetBox: tBox,
                    margin: 20
                )
                let cornerRadius: CGFloat = style == "smooth" ? 8 : 0
                samples = appendRoundedPolyline(points, cornerRadius: cornerRadius, to: path)
                previous = points.count >= 2 ? points[points.count - 2] : a
                labelPoint = midpointAlongPolyline(points)
            } else {
                path.curve(to: b, controlPoint1: c1, controlPoint2: c2); previous = c2
                samples = sampleCubic(from: a, c1: c1, c2: c2, to: b, steps: 24)
                labelPoint = CGPoint(x: (a.x + 3 * c1.x + 3 * c2.x + b.x) / 8, y: (a.y + 3 * c1.y + 3 * c2.y + b.y) / 8)
            }
        }
        let labelRect: CGRect?
        if label.isEmpty {
            labelRect = nil
        } else {
            let size = labelSize(label, role: role)
            let rect = CGRect(x: labelPoint.x - size.width / 2, y: edgeLabelY(labelPoint.y, height: size.height), width: size.width, height: size.height)
            labelRect = rect.insetBy(dx: -5, dy: -2)
        }
        let data = raw["data"] as? [String: Any] ?? [:]
        return EdgeDrawing(
            id: raw["id"] as? String ?? "",
            source: raw["source"] as? String ?? "",
            target: raw["target"] as? String ?? "",
            path: path, samples: samples, end: b, previous: previous,
            label: label, labelPoint: labelPoint, labelRect: labelRect,
            style: data["connector_style"] as? [String: Any] ?? [:],
            marker: raw["marker"] as? String ?? "arrow",
            animated: raw["animated"] as? Bool ?? false
        )
    }

    private static func orthogonalStepPoints(
        from a: CGPoint,
        startDir n: CGPoint,
        sourceBox: CGRect,
        to b: CGPoint,
        endDir o: CGPoint,
        targetBox: CGRect,
        margin: CGFloat
    ) -> [CGPoint] {
        let leadA = CGPoint(x: a.x + n.x * margin, y: a.y + n.y * margin)
        let leadB = CGPoint(x: b.x + o.x * margin, y: b.y + o.y * margin)
        var raw: [CGPoint] = [a, leadA]
        let startHorizontal = abs(n.x) > 0
        let endHorizontal = abs(o.x) > 0
        if startHorizontal && endHorizontal {
            if (leadB.x - leadA.x) * n.x >= 0 && n.x == -o.x {
                let midX = (leadA.x + leadB.x) / 2
                raw.append(CGPoint(x: midX, y: leadA.y))
                raw.append(CGPoint(x: midX, y: leadB.y))
            } else {
                let midY = (leadA.y + leadB.y) / 2
                let spanMinX = min(leadA.x, leadB.x), spanMaxX = max(leadA.x, leadB.x)
                func clearsHorizontally(_ y: CGFloat, _ box: CGRect) -> Bool {
                    spanMaxX <= box.minX || spanMinX >= box.maxX || y <= box.minY - margin || y >= box.maxY + margin
                }
                let detourY: CGFloat
                if abs(midY - leadA.y) >= margin && abs(midY - leadB.y) >= margin &&
                   clearsHorizontally(midY, sourceBox) && clearsHorizontally(midY, targetBox) {
                    detourY = midY
                } else {
                    detourY = min(sourceBox.minY, targetBox.minY) - margin
                }
                raw.append(CGPoint(x: leadA.x, y: detourY))
                raw.append(CGPoint(x: leadB.x, y: detourY))
            }
        } else if !startHorizontal && !endHorizontal {
            if (leadB.y - leadA.y) * n.y >= 0 && n.y == -o.y {
                let midY = (leadA.y + leadB.y) / 2
                raw.append(CGPoint(x: leadA.x, y: midY))
                raw.append(CGPoint(x: leadB.x, y: midY))
            } else {
                let midX = (leadA.x + leadB.x) / 2
                let spanMinY = min(leadA.y, leadB.y), spanMaxY = max(leadA.y, leadB.y)
                func clearsVertically(_ x: CGFloat, _ box: CGRect) -> Bool {
                    spanMaxY <= box.minY || spanMinY >= box.maxY || x <= box.minX - margin || x >= box.maxX + margin
                }
                let detourX: CGFloat
                if abs(midX - leadA.x) >= margin && abs(midX - leadB.x) >= margin &&
                   clearsVertically(midX, sourceBox) && clearsVertically(midX, targetBox) {
                    detourX = midX
                } else {
                    detourX = max(sourceBox.maxX, targetBox.maxX) + margin
                }
                raw.append(CGPoint(x: detourX, y: leadA.y))
                raw.append(CGPoint(x: detourX, y: leadB.y))
            }
        } else if startHorizontal {
            if (leadB.x - leadA.x) * n.x >= 0 && (leadA.y - leadB.y) * o.y >= 0 {
                raw.append(CGPoint(x: leadB.x, y: leadA.y))
            } else if abs(leadA.y - leadB.y) >= margin {
                raw.append(CGPoint(x: leadA.x, y: leadB.y))
            } else {
                let detourY = o.y < 0
                    ? min(sourceBox.minY, targetBox.minY) - margin
                    : max(sourceBox.maxY, targetBox.maxY) + margin
                raw.append(CGPoint(x: leadA.x, y: detourY))
                raw.append(CGPoint(x: leadB.x, y: detourY))
            }
        } else {
            if (leadB.y - leadA.y) * n.y >= 0 && (leadA.x - leadB.x) * o.x >= 0 {
                raw.append(CGPoint(x: leadA.x, y: leadB.y))
            } else if abs(leadA.x - leadB.x) >= margin {
                raw.append(CGPoint(x: leadB.x, y: leadA.y))
            } else {
                let detourX = o.x < 0
                    ? min(sourceBox.minX, targetBox.minX) - margin
                    : max(sourceBox.maxX, targetBox.maxX) + margin
                raw.append(CGPoint(x: detourX, y: leadA.y))
                raw.append(CGPoint(x: detourX, y: leadB.y))
            }
        }
        raw.append(leadB)
        raw.append(b)
        return simplifyOrthogonalPolyline(raw)
    }

    private static func simplifyOrthogonalPolyline(_ points: [CGPoint]) -> [CGPoint] {
        var result: [CGPoint] = []
        for pt in points {
            if let last = result.last,
               abs(last.x - pt.x) < 0.01 && abs(last.y - pt.y) < 0.01 {
                continue
            }
            if result.count >= 2 {
                let prev = result[result.count - 2]
                let mid = result[result.count - 1]
                let sameX = abs(prev.x - mid.x) < 0.01 && abs(mid.x - pt.x) < 0.01
                let sameY = abs(prev.y - mid.y) < 0.01 && abs(mid.y - pt.y) < 0.01
                let dx1 = mid.x - prev.x, dy1 = mid.y - prev.y
                let dx2 = pt.x - mid.x, dy2 = pt.y - mid.y
                let sameDirection = (dx1 * dx2 + dy1 * dy2) >= 0
                if (sameX || sameY) && sameDirection {
                    result.removeLast()
                }
            }
            result.append(pt)
        }
        return result
    }

    private static func appendRoundedPolyline(
        _ points: [CGPoint],
        cornerRadius: CGFloat,
        to path: NSBezierPath
    ) -> [CGPoint] {
        guard let first = points.first else { return [] }
        guard points.count > 1 else { return [first] }
        var samples: [CGPoint] = [first]
        for i in 1..<points.count {
            let current = points[i]
            if i == points.count - 1 || cornerRadius <= 0 {
                path.line(to: current)
                samples.append(current)
                continue
            }
            let prev = points[i - 1]
            let next = points[i + 1]
            let dPrev = hypot(current.x - prev.x, current.y - prev.y)
            let dNext = hypot(next.x - current.x, next.y - current.y)
            let radius = min(cornerRadius, dPrev / 2, dNext / 2)
            guard radius > 0.01 else {
                path.line(to: current)
                samples.append(current)
                continue
            }
            let entry = pointToward(from: current, to: prev, distance: radius)
            let exit = pointToward(from: current, to: next, distance: radius)
            path.line(to: entry)
            let c1 = CGPoint(
                x: entry.x + (2.0 / 3.0) * (current.x - entry.x),
                y: entry.y + (2.0 / 3.0) * (current.y - entry.y)
            )
            let c2 = CGPoint(
                x: exit.x + (2.0 / 3.0) * (current.x - exit.x),
                y: exit.y + (2.0 / 3.0) * (current.y - exit.y)
            )
            path.curve(to: exit, controlPoint1: c1, controlPoint2: c2)
            let arcSamples = sampleCubic(from: entry, c1: c1, c2: c2, to: exit, steps: 8)
            samples.append(contentsOf: arcSamples)
        }
        return samples
    }

    private static func pointToward(from a: CGPoint, to b: CGPoint, distance: CGFloat) -> CGPoint {
        let len = hypot(b.x - a.x, b.y - a.y)
        guard len > 0.0001 else { return a }
        return CGPoint(
            x: a.x + (b.x - a.x) / len * distance,
            y: a.y + (b.y - a.y) / len * distance
        )
    }

    private static func midpointAlongPolyline(_ points: [CGPoint]) -> CGPoint {
        guard let first = points.first else { return .zero }
        guard points.count > 1 else { return first }
        var total: CGFloat = 0
        for i in 1..<points.count {
            total += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
        }
        var remaining = total / 2
        for i in 1..<points.count {
            let seg = hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
            if seg >= remaining {
                return pointToward(from: points[i - 1], to: points[i], distance: remaining)
            }
            remaining -= seg
        }
        return points.last ?? first
    }

    private static func edgeLabelY(_ centerY: CGFloat, height: CGFloat) -> CGFloat {
        centerY - height / 2
    }

    private static func sampleCubic(from a: CGPoint, c1: CGPoint, c2: CGPoint, to b: CGPoint, steps: Int) -> [CGPoint] {
        (0...steps).map { step in
            let t = CGFloat(step) / CGFloat(steps)
            let u = 1 - t
            let x = u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x
            let y = u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y
            return CGPoint(x: x, y: y)
        }
    }

    private static func handle(_ node: Node, _ side: String) -> CGPoint {
        let box = node.box
        var p: CGPoint
        switch side {
        case "top": p = CGPoint(x: box.midX, y: box.minY)
        case "bottom": p = CGPoint(x: box.midX, y: box.maxY)
        case "left": p = CGPoint(x: box.minX, y: box.midY)
        default: p = CGPoint(x: box.maxX, y: box.midY)
        }
        if node.kind == "triangle" && (side == "left" || side == "right") {
            p = CGPoint(x: side == "left" ? box.minX + box.width / 4 : box.maxX - box.width / 4, y: box.minY + box.height / 2)
        }
        let angle = node.rotation * .pi / 180, dx = p.x - node.center.x, dy = p.y - node.center.y
        return CGPoint(x: node.center.x + dx * cos(angle) - dy * sin(angle), y: node.center.y + dx * sin(angle) + dy * cos(angle))
    }
    private static func nearestSide(_ node: Node, _ point: CGPoint) -> String {
        ["top", "right", "bottom", "left"].min { a, b in
            let p = handle(node, a), q = handle(node, b)
            return hypot(p.x - point.x, p.y - point.y) < hypot(q.x - point.x, q.y - point.y)
        } ?? "right"
    }
    private static func direction(_ node: Node, _ side: String) -> CGPoint {
        let p = handle(node, side), dx = p.x - node.center.x, dy = p.y - node.center.y
        let length = max(0.001, hypot(dx, dy)); return CGPoint(x: dx / length, y: dy / length)
    }
    private static func cardinalDirection(_ node: Node, _ side: String) -> CGPoint {
        let localNormal: CGPoint
        if node.kind == "triangle" && (side == "left" || side == "right") {
            let halfW = max(1, node.box.width / 2)
            let h = max(1, node.box.height)
            let len = hypot(halfW, h)
            localNormal = CGPoint(x: (side == "right" ? h : -h) / len, y: -halfW / len)
        } else {
            switch side {
            case "top": localNormal = CGPoint(x: 0, y: -1)
            case "bottom": localNormal = CGPoint(x: 0, y: 1)
            case "left": localNormal = CGPoint(x: -1, y: 0)
            default: localNormal = CGPoint(x: 1, y: 0)
            }
        }
        let angle = node.rotation * .pi / 180
        let nx = localNormal.x * cos(angle) - localNormal.y * sin(angle)
        let ny = localNormal.x * sin(angle) + localNormal.y * cos(angle)
        if abs(nx) >= abs(ny) {
            return CGPoint(x: nx >= 0 ? 1 : -1, y: 0)
        } else {
            return CGPoint(x: 0, y: ny >= 0 ? 1 : -1)
        }
    }

    // MARK: - Armed Creation Tools, Shortcuts Sheet & NSAccessibility

    public func armCreationTool(_ tool: CanvasCreationTool) {
        if tool != .select && isReadOnly {
            NSSound.beep()
            return
        }
        if inlineTextState != nil {
            guard finishInlineTextBeforeCanvasAction() else { return }
        }
        guard window?.attachedSheet == nil,
              connectionEditor == nil,
              attachmentPreview == nil,
              pngExportSheet == nil,
              shortcutsSheet == nil,
              drag == nil,
              connectionDrag == nil else {
            NSSound.beep()
            return
        }
        cancelGeometry()
        creationDrag = nil
        activeCreationTool = tool
        window?.makeFirstResponder(self)
    }

    public func activateToolFromDock(_ tool: CanvasCreationTool) {
        if tool == .select {
            armCreationTool(.select)
            return
        }
        if activeCreationTool == tool {
            activeCreationTool = .select
            switch tool {
            case .shape(let kind):
                insertShape(kind)
            case .line(let kind):
                insertLine(kind)
            case .select:
                break
            }
        } else {
            armCreationTool(tool)
        }
    }

    private func commitCreationDrag(_ gesture: CreationDragGesture, at endPoint: CGPoint) {
        let start = gesture.startPoint
        let end = endPoint
        let dragged = gesture.hasDragged || hypot(end.x - start.x, end.y - start.y) >= 8.0
        switch gesture.tool {
        case .select:
            break
        case .shape(.text):
            let pos: CanvasPosition
            if dragged {
                pos = CanvasPosition(x: Double(min(start.x, end.x)), y: Double(min(start.y, end.y)))
            } else {
                pos = CanvasPosition(x: Double(end.x) - 80, y: Double(end.y) - 24)
            }
            beginNewTextShape(at: pos)
        case .shape(let kind):
            if dragged {
                let minX = Double(min(start.x, end.x))
                let minY = Double(min(start.y, end.y))
                let width = max(32.0, Double(abs(end.x - start.x)))
                let height = max(32.0, Double(abs(end.y - start.y)))
                do {
                    try createShape(kind, at: CanvasPosition(x: minX, y: minY), width: width, height: height)
                } catch {
                    NSSound.beep()
                }
            } else {
                let pos = CanvasPosition(x: Double(end.x) - 80, y: Double(end.y) - 48)
                do {
                    try createShape(kind, at: pos)
                } catch {
                    NSSound.beep()
                }
            }
            window?.makeFirstResponder(self)
        case .line(let kind):
            if dragged {
                let fromPos = CanvasPosition(x: Double(start.x), y: Double(start.y))
                let toPos = CanvasPosition(x: Double(end.x), y: Double(end.y))
                do {
                    let insertion = try session.insertLine(kind, from: fromPos, to: toPos)
                    displayInsertion(insertion.id)
                    registerUndoInsertion(
                        insertion,
                        restoring: false,
                        actionName: kind == .arrow ? "Insert Arrow" : "Insert Line"
                    )
                } catch {
                    NSSound.beep()
                }
            } else {
                let center = CanvasPosition(x: Double(end.x), y: Double(end.y))
                do {
                    let insertion = try session.insertLine(kind, centeredAt: center)
                    displayInsertion(insertion.id)
                    registerUndoInsertion(
                        insertion,
                        restoring: false,
                        actionName: kind == .arrow ? "Insert Arrow" : "Insert Line"
                    )
                } catch {
                    NSSound.beep()
                }
            }
            window?.makeFirstResponder(self)
        }
    }

    private func drawCreationDragPreview(_ gesture: CreationDragGesture) {
        guard gesture.hasDragged else { return }
        let start = gesture.startPoint
        let end = gesture.currentPoint
        switch gesture.tool {
        case .select:
            break
        case .shape(let kind):
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: max(32, abs(end.x - start.x)),
                height: max(32, abs(end.y - start.y))
            )
            let path = outline(kind.rawValue, rect, 0)
            CanvasTheme.selectionCobalt.withAlphaComponent(0.08).setFill()
            path.fill()
            CanvasTheme.selectionCobalt.setStroke()
            path.lineWidth = 2 / zoomScale
            path.setLineDash([6 / zoomScale, 4 / zoomScale], count: 2, phase: 0)
            path.stroke()
        case .line(let kind):
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            CanvasTheme.selectionCobalt.setStroke()
            path.lineWidth = 2 / zoomScale
            path.setLineDash([6 / zoomScale, 4 / zoomScale], count: 2, phase: 0)
            path.stroke()
            if kind == .arrow {
                drawArrow(at: end, from: start, color: CanvasTheme.selectionCobalt)
            }
        }
    }

    @objc public func beginShortcutsHelp(_ sender: Any? = nil) {
        guard let window, window.attachedSheet == nil,
              connectionEditor == nil, attachmentPreview == nil,
              pngExportSheet == nil, shortcutsSheet == nil else {
            NSSound.beep()
            return
        }
        shortcutsSheet = CanvasShortcutsSheet { [weak self, weak window] in
            guard let self else { return }
            self.shortcutsSheet = nil
            window?.makeFirstResponder(self)
        }
        shortcutsSheet?.present(on: window)
    }

    public func viewRect(forWorldRect rect: CGRect) -> CGRect {
        CGRect(
            x: (rect.minX - origin.x) * zoomScale,
            y: (rect.minY - origin.y) * zoomScale,
            width: rect.width * zoomScale,
            height: rect.height * zoomScale
        )
    }

    public func accessibilityCanvasElements() -> [CanvasAccessibilityElement] {
        var elements: [CanvasAccessibilityElement] = []
        for node in nodes {
            let isLocked = session.isLocked(node.id)
            let attachment = session.attachment(of: node.id)
            let roleSummary: String
            if node.type == "code" {
                roleSummary = isLocked ? "locked code block" : "code block"
            } else if attachment != nil {
                roleSummary = isLocked ? "locked attachment card" : "attachment card"
            } else if node.type == "shape-line" {
                let arrow = node.data["arrow"] as? String ?? "none"
                let base = arrow == "none" ? "standalone line" : "standalone arrow"
                roleSummary = isLocked ? "locked \(base)" : base
            } else {
                let kindName = node.kind == "rect" ? "rectangle" : node.kind
                roleSummary = isLocked ? "locked \(kindName) shape" : "\(kindName) shape"
            }

            let rawText = Self.nodeText(node).trimmingCharacters(in: .whitespacesAndNewlines)
            let singleLine = rawText.replacingOccurrences(of: "\n", with: " ")
            let titleText: String
            if let attachment {
                if singleLine.isEmpty {
                    titleText = "\(attachment.filename) (\(roleSummary))"
                } else {
                    titleText = "\(singleLine) — \(attachment.filename)"
                }
            } else if !singleLine.isEmpty {
                titleText = String(singleLine.prefix(80))
            } else {
                titleText = "\(roleSummary.capitalized) \(node.id)"
            }

            let isSelected = selectedNodeIDs.contains(node.id) || selectedID == node.id
            let isFocused = focusedNodeID == node.id
            var stateParts: [String] = [isSelected ? "selected" : (isFocused ? "focused" : "unselected")]
            if isLocked {
                stateParts.append("locked")
            }
            let b = node.geometry.rotatedAxisAlignedBounds
            let worldBounds = CGRect(x: b.x, y: b.y, width: b.width, height: b.height)
            elements.append(
                CanvasAccessibilityElement(
                    elementID: node.id,
                    elementKind: .node(
                        id: node.id,
                        type: node.type,
                        shapeKind: node.kind,
                        isLocked: isLocked,
                        hasAttachment: attachment != nil
                    ),
                    titleText: titleText,
                    roleSummary: roleSummary,
                    valueSummary: stateParts.joined(separator: ", "),
                    worldBounds: worldBounds,
                    canvasView: self
                )
            )
        }
        for edge in edges {
            let roleSummary = "connection from \(edge.source) to \(edge.target)"
            let titleText = edge.label.isEmpty
                ? "Connection \(edge.source) → \(edge.target)"
                : "\(edge.label) (\(edge.source) → \(edge.target))"
            let isSelected = selectedEdgeID == edge.id
            let isFocused = focusedConnectionID == edge.id
            let valueSummary = isSelected ? "selected" : (isFocused ? "focused" : "unselected")
            let worldBounds = edge.path.bounds.insetBy(dx: -8, dy: -8)
            elements.append(
                CanvasAccessibilityElement(
                    elementID: edge.id,
                    elementKind: .connection(id: edge.id, sourceID: edge.source, targetID: edge.target),
                    titleText: titleText,
                    roleSummary: roleSummary,
                    valueSummary: valueSummary,
                    worldBounds: worldBounds,
                    canvasView: self
                )
            )
        }
        return elements
    }

    public override func isAccessibilityElement() -> Bool {
        true
    }

    public override func accessibilityRole() -> NSAccessibility.Role? {
        .group
    }

    public override func accessibilityRoleDescription() -> String? {
        "spatial canvas"
    }

    public override func accessibilityLabel() -> String? {
        "Canvas (\(nodes.count) objects, \(edges.count) connections)"
    }

    public override func accessibilityChildren() -> [Any]? {
        var children: [Any] = accessibilityCanvasElements()
        for subview in [thoughtScrollView, styleInspector, alignBar, toolDock, statusBanner] where !subview.isHidden {
            children.append(subview)
        }
        return children
    }

    public override func accessibilitySelectedChildren() -> [Any]? {
        accessibilityCanvasElements().filter { $0.isAccessibilitySelected() }
    }
}

private func number(_ value: Any?, _ fallback: CGFloat = 0) -> CGFloat { (value as? NSNumber).map { CGFloat($0.doubleValue) } ?? fallback }
private func point(_ value: Any?, in box: CGRect) -> CGPoint {
    let values = value as? [Any] ?? []
    return CGPoint(x: box.minX + (values.count > 0 ? number(values[0]) : 0), y: box.minY + (values.count > 1 ? number(values[1]) : 0))
}
private func distance(_ point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
    let dx = end.x - start.x
    let dy = end.y - start.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
    let ratio = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
    let nearest = CGPoint(x: start.x + ratio * dx, y: start.y + ratio * dy)
    return hypot(point.x - nearest.x, point.y - nearest.y)
}
private func font(_ role: String, _ size: String, scale: CGFloat = 1.0) -> NSFont {
    CanvasTypography.font(role, size, scale: scale)
}
private func alignment(_ value: String) -> NSTextAlignment { value == "right" ? .right : value == "center" ? .center : .left }
private func palette(_ name: String) -> NSColor {
    CanvasTheme.palette(name)
}
private func textColor(on fill: String) -> NSColor {
    CanvasTheme.textColor(onFill: fill)
}
private func configure(_ path: NSBezierPath, _ data: [String: Any]) {
    path.lineWidth = number(data["width"], 2)
    if data["dash"] as? Bool == true { path.setLineDash([6, 4], count: 2, phase: 0) }
}
private func outline(_ kind: String, _ box: CGRect, _ radius: CGFloat) -> NSBezierPath {
    if kind == "ellipse" { return NSBezierPath(ovalIn: box) }
    if kind == "rect" || kind == "text" { return NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius) }
    let path = NSBezierPath()
    if kind == "triangle" {
        path.move(to: CGPoint(x: box.midX, y: box.minY)); path.line(to: CGPoint(x: box.maxX, y: box.maxY)); path.line(to: CGPoint(x: box.minX, y: box.maxY))
    } else {
        path.move(to: CGPoint(x: box.midX, y: box.minY)); path.line(to: CGPoint(x: box.maxX, y: box.midY)); path.line(to: CGPoint(x: box.midX, y: box.maxY)); path.line(to: CGPoint(x: box.minX, y: box.midY))
    }
    path.close(); return path
}
private func drawArrow(at end: CGPoint, from previous: CGPoint, color: NSColor) {
    let angle = atan2(end.y - previous.y, end.x - previous.x)
    let length: CGFloat = 10, spread: CGFloat = 0.48
    let path = NSBezierPath(); path.move(to: end)
    path.line(to: CGPoint(x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread)))
    path.line(to: CGPoint(x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread)))
    path.close(); color.setFill(); path.fill()
}
