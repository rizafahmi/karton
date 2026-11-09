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

    private var nodes: [Node]
    private var edges: [EdgeDrawing]
    private let paper: [String: Any]
    private let fontRole: String
    private var origin: CGPoint
    private let session: CanvasSession
    private let history = UndoManager()
    public override var undoManager: UndoManager? { history }
    private var selectedID: String?
    private var selectedEdgeID: String?
    private var drag: (id: String, mouse: CGPoint, position: CanvasPosition)?
    private var textEditor: ShapeTextEditor?
    private var connectionEditor: ConnectionEditor?
    private var geometryGesture: GeometryGesture?
    private var lineEndpointGesture: LineEndpointGesture?
    public var selectedNodeID: String? { selectedID }
    public var selectedConnectionID: String? { selectedEdgeID }
    public var hasGeometryPreview: Bool { geometryGesture != nil || lineEndpointGesture != nil }
    public var canEditGeometry: Bool {
        selectedID.map { session.canTransform($0) || session.canEditLineEndpoints($0) } ?? false
    }
    public var canInsertConnection: Bool {
        nodes.contains { $0.type != "shape-line" }
    }
    public var canDeleteSelection: Bool {
        guard !hasGeometryPreview, drag == nil else { return false }
        if let id = selectedID { return session.canDeleteNode(id) }
        if let edgeID = selectedEdgeID { return session.hasConnection(edgeID) }
        return false
    }
    public var canDuplicateSelection: Bool {
        guard !hasGeometryPreview, drag == nil, let id = selectedID else { return false }
        return session.canDuplicateNode(id)
    }
    public var canBringToFront: Bool {
        guard !hasGeometryPreview, drag == nil, let id = selectedID else { return false }
        return session.canBringToFront(id)
    }
    public var canSendToBack: Bool {
        guard !hasGeometryPreview, drag == nil, let id = selectedID else { return false }
        return session.canSendToBack(id)
    }
    public var canToggleLock: Bool {
        !hasGeometryPreview && drag == nil && selectedID != nil
    }
    public var isSelectedNodeLocked: Bool {
        selectedID.map { session.isLocked($0) } ?? false
    }
    public override var isFlipped: Bool { true }

    public convenience init(document: CanvasDocument) {
        self.init(session: CanvasSession(document: document))
    }

    public init(session: CanvasSession) {
        let root = session.root
        let nodes = (root["nodes"] as? [[String: Any]] ?? []).map { raw in
            Node(id: raw["id"] as? String ?? "", type: raw["type"] as? String ?? "shape",
                 box: CGRect(x: number(raw["x"]), y: number(raw["y"]),
                             width: number(raw["width"]), height: number(raw["height"])),
                 data: raw["data"] as? [String: Any] ?? [:])
        }
        let index = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        let role = (root["appearance"] as? [String: Any])?["font"] as? String ?? "sans"
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
        self.session = session
        self.origin = bounds.origin
        let size = CGSize(width: max(800, bounds.width), height: max(600, bounds.height))
        super.init(frame: CGRect(origin: .zero, size: size))
        history.groupsByEvent = false
    }

    public required init?(coder: NSCoder) { fatalError("CanvasView requires a document") }

    public override var acceptsFirstResponder: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        CanvasTheme.canvasBackground.setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: -origin.x, y: -origin.y)
        drawPaper(dirtyRect.offsetBy(dx: origin.x, dy: origin.y))
        for edge in edges { drawEdge(edge) }
        for node in nodes { drawNode(node) }
        if let selectedID, let node = nodes.first(where: { $0.id == selectedID }) {
            drawSelection(node)
        }
        context.restoreGState()
        if let geometryGesture { drawGeometryHelp(geometryGesture.handle) }
        if let lineEndpointGesture { drawLineEndpointHelp(lineEndpointGesture.endpoint) }
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = worldPoint(for: event)
        if let id = selectedID, session.canTransform(id),
           let node = nodes.first(where: { $0.id == id }),
           let handle = geometryHandle(at: point, node: node) {
            var gesture = geometryGesture ?? GeometryGesture(id: id, geometry: node.geometry)
            gesture.startPointer(at: CanvasPosition(x: point.x, y: point.y), handle: handle)
            geometryGesture = gesture
            drag = nil
            needsDisplay = true
            return
        }
        if let id = selectedID, session.canEditLineEndpoints(id),
           let node = nodes.first(where: { $0.id == id }),
           let lineGeometry = node.lineGeometry,
           let endpoint = lineEndpointHandle(at: point, lineGeometry: lineGeometry) {
            var gesture = lineEndpointGesture ?? LineEndpointGesture(id: id, geometry: lineGeometry)
            gesture.startPointer(at: CanvasPosition(x: point.x, y: point.y), endpoint: endpoint)
            lineEndpointGesture = gesture
            drag = nil
            needsDisplay = true
            return
        }
        cancelGeometry()
        if let hitNode = nodes.reversed().first(where: { contains(point, node: $0) }) {
            selectedID = hitNode.id
            selectedEdgeID = nil
        } else if let hitEdge = edges.reversed().first(where: { contains(point, edge: $0) }) {
            selectedID = nil
            selectedEdgeID = hitEdge.id
        } else {
            selectedID = nil
            selectedEdgeID = nil
        }
        drag = nil
        if event.clickCount == 2 {
            beginTextEditing()
            needsDisplay = true
            return
        }
        if let id = selectedID, !session.isLocked(id), let position = session.position(of: id) {
            drag = (id: id, mouse: point, position: position)
        }
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
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
        guard let drag else { return }
        let point = worldPoint(for: event)
        let position = CanvasPosition(
            x: drag.position.x + Double(point.x - drag.mouse.x),
            y: drag.position.y + Double(point.y - drag.mouse.y)
        )
        try? moveWithoutHistory(drag.id, to: position)
    }

    public override func mouseUp(with event: NSEvent) {
        if geometryGesture?.pointerStart != nil {
            commitGeometry()
            return
        }
        if lineEndpointGesture?.pointerStart != nil {
            commitLineEndpoints()
            return
        }
        guard let drag, let current = session.position(of: drag.id) else {
            self.drag = nil
            return
        }
        self.drag = nil
        if current != drag.position {
            registerUndoMove(drag.id, to: drag.position)
        }
    }

    public override func keyDown(with event: NSEvent) {
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
            case "d" where !shifted:
                duplicateSelection(nil)
                return
            case "l" where !shifted:
                toggleLock(nil)
                return
            case "z":
                if shifted { redoMove(nil) } else { undoMove(nil) }
                return
            case "]" where shifted, "}" where shifted:
                bringToFront(nil)
                return
            case "[" where shifted, "{" where shifted:
                sendToBack(nil)
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
            }
        }
        if flags.isEmpty {
            if event.keyCode == 51 || event.keyCode == 117 {
                deleteSelection(nil)
                return
            }
            if event.keyCode == 48 {
                traverseSelection(backwards: event.modifierFlags.contains(.shift))
                return
            }
            if event.keyCode == 53 {
                if let drag {
                    try? moveWithoutHistory(drag.id, to: drag.position)
                    self.drag = nil
                    return
                }
                if selectedID != nil || selectedEdgeID != nil {
                    selectedID = nil
                    selectedEdgeID = nil
                    needsDisplay = true
                }
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
                insertLine(lineKind)
                return
            }
            if event.keyCode == 36 {
                beginTextEditing()
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
        guard let id = selectedID, !session.isLocked(id), let current = session.position(of: id) else {
            NSSound.beep()
            return
        }
        let next = CanvasPosition(x: current.x + delta.0, y: current.y + delta.1)
        do {
            try moveWithoutHistory(id, to: next)
            registerUndoMove(id, to: current)
        } catch {
            NSSound.beep()
        }
    }

    @objc public func undoMove(_ sender: Any?) {
        guard window?.attachedSheet == nil, textEditor == nil, connectionEditor == nil, drag == nil else {
            NSSound.beep()
            return
        }
        if hasGeometryPreview { cancelGeometry(); return }
        history.undo()
    }

    @objc public func redoMove(_ sender: Any?) {
        guard window?.attachedSheet == nil, textEditor == nil, connectionEditor == nil, drag == nil else {
            NSSound.beep()
            return
        }
        if hasGeometryPreview { cancelGeometry(); return }
        history.redo()
    }

    public func beginGeometryEditing() {
        guard !hasGeometryPreview, drag == nil, let window, window.attachedSheet == nil,
              let id = selectedID else { NSSound.beep(); return }
        if session.canTransform(id), let geometry = session.geometry(of: id) {
            geometryGesture = GeometryGesture(id: id, geometry: geometry)
            window.makeFirstResponder(self)
            needsDisplay = true
        } else if session.canEditLineEndpoints(id), let lineGeometry = session.lineGeometry(of: id) {
            lineEndpointGesture = LineEndpointGesture(id: id, geometry: lineGeometry)
            window.makeFirstResponder(self)
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

    public func beginConnection() {
        guard let window, window.attachedSheet == nil, textEditor == nil,
              connectionEditor == nil, !hasGeometryPreview, drag == nil, canInsertConnection else { NSSound.beep(); return }
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
        connectionEditor = ConnectionEditor(objects: options, selectedID: selectedID, commit: {
            [weak self] source, sourceSide, target, targetSide in
            guard let self else { return }
            let insertion = try self.session.insertConnection(
                source: source, sourceSide: sourceSide, target: target, targetSide: targetSide
            )
            self.selectedID = nil
            self.selectedEdgeID = insertion.id
            self.rebuildEdges()
            self.needsDisplay = true
            self.registerUndoConnection(insertion, restoring: false, actionName: "Connect")
        }, completion: { [weak self, weak window] in
            guard let self else { return }
            self.connectionEditor = nil
            window?.makeFirstResponder(self)
        })
        connectionEditor?.present(on: window)
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
                target.needsDisplay = true
                target.registerUndoConnection(insertion, restoring: !restoring, actionName: actionName)
            } catch { NSSound.beep() }
        }
    }

    /// Inserts at the currently visible center, never at the source file's origin.
    public func insertShape(_ kind: CanvasShapeKind) {
        guard let window, window.attachedSheet == nil, textEditor == nil,
              !hasGeometryPreview, drag == nil else { return }
        let center = CGPoint(x: visibleRect.midX + origin.x, y: visibleRect.midY + origin.y)
        let position = CanvasPosition(x: center.x - 80, y: center.y - (kind == .text ? 24 : 48))
        if kind == .text {
            textEditor = ShapeTextEditor(text: "", commit: { [weak self] text in
                guard !text.isEmpty else { return }
                try self?.createShape(kind, at: position, text: text)
            }, completion: { [weak self, weak window] in
                guard let self else { return }
                self.textEditor = nil
                window?.makeFirstResponder(self)
            })
            textEditor?.present(on: window)
        } else {
            do { try createShape(kind, at: position) }
            catch { NSSound.beep() }
            window.makeFirstResponder(self)
        }
    }

    public func insertLine(_ kind: CanvasLineKind) {
        guard let window, window.attachedSheet == nil, textEditor == nil,
              !hasGeometryPreview, drag == nil else { return }
        let center = CanvasPosition(x: visibleRect.midX + origin.x, y: visibleRect.midY + origin.y)
        do {
            let insertion = try session.insertLine(kind, centeredAt: center)
            displayInsertion(insertion.id)
            registerUndoInsertion(insertion, restoring: false, actionName: kind == .arrow ? "Insert Arrow" : "Insert Line")
        } catch {
            NSSound.beep()
        }
        window.makeFirstResponder(self)
    }

    private func createShape(_ kind: CanvasShapeKind, at position: CanvasPosition, text: String? = nil) throws {
        let insertion = try session.insertShape(kind, at: position, text: text)
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
        selectedID = id
        selectedEdgeID = nil
        expandDrawingBounds()
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
                    if target.selectedID == insertion.id { target.selectedID = nil }
                    target.needsDisplay = true
                }
                target.registerUndoInsertion(insertion, restoring: !restoring, actionName: actionName)
            } catch { NSSound.beep() }
        }
    }

    @objc public func duplicateSelection(_ sender: Any? = nil) {
        guard !hasGeometryPreview, drag == nil, window?.attachedSheet == nil,
              textEditor == nil, connectionEditor == nil,
              let id = selectedID, session.canDuplicateNode(id) else {
            NSSound.beep()
            return
        }
        do {
            let insertion = try session.duplicateNode(id)
            displayInsertion(insertion.id)
            registerUndoInsertion(insertion, restoring: false, actionName: "Duplicate")
        } catch {
            NSSound.beep()
        }
    }

    @objc public func deleteSelection(_ sender: Any? = nil) {
        guard !hasGeometryPreview, drag == nil, window?.attachedSheet == nil,
              textEditor == nil, connectionEditor == nil else {
            NSSound.beep()
            return
        }
        if let id = selectedID {
            guard session.canDeleteNode(id) else { NSSound.beep(); return }
            do {
                let deletion = try session.deleteNode(id)
                selectedID = nil
                selectedEdgeID = nil
                syncFromSession()
                registerUndoNodeDeletion(deletion, restoring: true)
            } catch {
                NSSound.beep()
            }
        } else if let edgeID = selectedEdgeID {
            do {
                let deletion = try session.deleteConnection(edgeID)
                selectedEdgeID = nil
                rebuildEdges()
                needsDisplay = true
                registerUndoConnection(deletion, restoring: true, actionName: "Delete Connection")
            } catch {
                NSSound.beep()
            }
        } else {
            NSSound.beep()
        }
    }

    private func registerUndoNodeDeletion(_ deletion: CanvasNodeDeletion, restoring: Bool) {
        recordUndo("Delete") { target in
            do {
                if restoring {
                    try target.session.restoreNodeDeletion(deletion)
                    target.selectedID = deletion.id
                    target.selectedEdgeID = nil
                } else {
                    _ = try target.session.deleteNode(deletion.id)
                    if target.selectedID == deletion.id { target.selectedID = nil }
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
        guard !hasGeometryPreview, drag == nil, window?.attachedSheet == nil,
              textEditor == nil, connectionEditor == nil,
              let id = selectedID else {
            NSSound.beep()
            return
        }
        do {
            guard let move = try session.bringToFront(id) else { return }
            syncFromSession()
            registerUndoStackMove(move, actionName: "Bring to Front")
        } catch {
            NSSound.beep()
        }
    }

    @objc public func sendToBack(_ sender: Any? = nil) {
        guard !hasGeometryPreview, drag == nil, window?.attachedSheet == nil,
              textEditor == nil, connectionEditor == nil,
              let id = selectedID else {
            NSSound.beep()
            return
        }
        do {
            guard let move = try session.sendToBack(id) else { return }
            syncFromSession()
            registerUndoStackMove(move, actionName: "Send to Back")
        } catch {
            NSSound.beep()
        }
    }

    private func registerUndoStackMove(_ move: CanvasStackMove, actionName: String) {
        recordUndo(actionName) { target in
            do {
                guard let inverse = try target.session.moveNode(move.id, toIndex: move.fromIndex) else { return }
                target.selectedID = move.id
                target.selectedEdgeID = nil
                target.syncFromSession()
                target.registerUndoStackMove(inverse, actionName: actionName)
            } catch {
                NSSound.beep()
            }
        }
    }

    @objc public func toggleLock(_ sender: Any? = nil) {
        guard !hasGeometryPreview, drag == nil, window?.attachedSheet == nil,
              textEditor == nil, connectionEditor == nil,
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
        needsDisplay = true
        recordUndo(locked == true ? "Lock" : "Unlock") { target in
            do { try target.changeLocked(id, to: before) }
            catch { NSSound.beep() }
        }
    }

    private func traverseSelection(backwards: Bool) {
        enum Selectable: Equatable {
            case node(String)
            case edge(String)
        }
        let items = nodes.map { Selectable.node($0.id) } + edges.map { Selectable.edge($0.id) }
        guard !items.isEmpty else {
            NSSound.beep()
            return
        }
        let current: Selectable? = selectedID.map(Selectable.node) ?? selectedEdgeID.map(Selectable.edge)
        let nextIndex: Int
        if let current, let index = items.firstIndex(of: current) {
            nextIndex = (index + (backwards ? -1 : 1) + items.count) % items.count
        } else {
            nextIndex = backwards ? items.count - 1 : 0
        }
        switch items[nextIndex] {
        case .node(let id):
            selectedID = id
            selectedEdgeID = nil
        case .edge(let id):
            selectedID = nil
            selectedEdgeID = id
        }
        needsDisplay = true
    }

    private func syncFromSession() {
        nodes = (session.root["nodes"] as? [[String: Any]] ?? []).map { raw in
            Node(id: raw["id"] as? String ?? "", type: raw["type"] as? String ?? "shape",
                 box: CGRect(x: number(raw["x"]), y: number(raw["y"]),
                             width: number(raw["width"]), height: number(raw["height"])),
                 data: raw["data"] as? [String: Any] ?? [:])
        }
        rebuildEdges()
        needsDisplay = true
    }

    private func beginTextEditing() {
        guard textEditor == nil, let window, let id = selectedID,
              session.canEditText(id) else { NSSound.beep(); return }
        drag = nil
        textEditor = ShapeTextEditor(text: session.text(of: id) ?? "", commit: { [weak self] text in
            guard let self else { return }
            // Finishing an unchanged empty caption must not materialize a default.
            guard text != (self.session.text(of: id) ?? "") else { return }
            try self.changeText(id, to: text)
        }, completion: { [weak self, weak window] in
            guard let self else { return }
            self.textEditor = nil
            window?.makeFirstResponder(self)
        })
        textEditor?.present(on: window)
    }

    private func changeText(_ id: String, to text: String?) throws {
        let before = session.text(of: id)
        guard try session.setText(id, to: text) else { return }
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            nodes[index].data["text"] = text
        }
        recordUndo("Edit Text") { target in
            do { try target.changeText(id, to: before) }
            catch { NSSound.beep() }
        }
        needsDisplay = true
    }

    private func registerUndoMove(_ id: String, to position: CanvasPosition) {
        recordUndo("Move") { target in
            target.performHistoryMove(id, to: position)
        }
    }

    private func recordUndo(_ name: String, action: @escaping (CanvasView) -> Void) {
        let needsGroup = !history.isUndoing && !history.isRedoing
        if needsGroup { history.beginUndoGrouping() }
        history.registerUndo(withTarget: self, handler: action)
        history.setActionName(name)
        if needsGroup { history.endUndoGrouping() }
    }

    private func performHistoryMove(_ id: String, to position: CanvasPosition) {
        guard let inverse = session.position(of: id) else { return }
        do {
            try moveWithoutHistory(id, to: position)
            registerUndoMove(id, to: inverse)
        } catch {
            NSSound.beep()
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
        var required = CGRect(origin: origin, size: frame.size)
        for node in nodes {
            let radius = hypot(node.box.width, node.box.height) / 2 + 40
            required = required.union(CGRect(x: node.center.x - radius, y: node.center.y - radius,
                                             width: radius * 2, height: radius * 2))
        }
        for edge in edges { required = required.union(edge.path.bounds.insetBy(dx: -40, dy: -40)) }
        guard required.origin != origin || required.size != frame.size else { return }
        let shift = CGPoint(x: origin.x - required.minX, y: origin.y - required.minY)
        let clip = enclosingScrollView?.contentView
        let previous = clip?.bounds.origin
        origin = required.origin
        setFrameSize(required.size)
        if let clip, let previous {
            clip.scroll(to: CGPoint(x: previous.x + shift.x, y: previous.y + shift.y))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }

    private func worldPoint(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x + origin.x, y: point.y + origin.y)
    }

    public func viewPoint(forWorldPoint point: CGPoint) -> CGPoint {
        CGPoint(x: point.x - origin.x, y: point.y - origin.y)
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
        guard session.canTransform(node.id) else { return }
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

    private func drawNode(_ node: Node) {
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
            let text = Self.nodeText(node)
            let role = node.type == "code" ? "mono" : (data["font"] as? String ?? fontRole)
            let rect = Self.textRect(node, role: fontRole)
            let style = NSMutableParagraphStyle()
            style.alignment = node.type == "code" ? .left : alignment(data["align"] as? String ?? (kind == "text" ? "left" : "center"))
            style.lineBreakMode = .byWordWrapping
            let attrs: [NSAttributedString.Key: Any] = [.font: font(role, data["size"] as? String ?? "m"), .foregroundColor: textColor(on: fill), .paragraphStyle: style]
            (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
        }
        context.restoreGState()
    }

    private func drawEdge(_ edge: EdgeDrawing) {
        let isSelected = edge.id == selectedEdgeID
        let color = isSelected ? CanvasTheme.selectionCobalt : palette(edge.style["stroke"] as? String ?? "ink")
        let width = edge.style["width"] as? NSNumber
        let validWidth = width != nil && CFGetTypeID(width!) != CFBooleanGetTypeID() &&
            !["f", "d"].contains(String(cString: width!.objCType)) && [1, 2, 4].contains(width!.intValue)
        color.setStroke(); edge.path.lineWidth = validWidth ? CGFloat(width!.intValue) : 2
        let dash = edge.style["dash"] as? NSNumber
        let dashed = dash != nil && CFGetTypeID(dash!) == CFBooleanGetTypeID() ? dash!.boolValue : edge.animated
        if dashed { edge.path.setLineDash([6, 4], count: 2, phase: 0) }
        edge.path.stroke()
        if edge.marker == "arrow" { drawArrow(at: edge.end, from: edge.previous, color: color) }
        if edge.marker == "dot" { color.setFill(); NSBezierPath(ovalIn: CGRect(x: edge.end.x - 4, y: edge.end.y - 4, width: 8, height: 8)).fill() }
        if !edge.label.isEmpty {
            let size = Self.labelSize(edge.label, role: fontRole)
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
                let handleRect = CGRect(x: endpoint.x - 3, y: endpoint.y - 3, width: 6, height: 6)
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

    private static func makeEdge(_ raw: [String: Any], _ source: Node, _ target: Node, role: String) -> EdgeDrawing {
        let fromSide = raw["source_handle"] as? String ?? nearestSide(source, target.center)
        let toSide = raw["target_handle"] as? String ?? nearestSide(target, source.center)
        let a = handle(source, fromSide), b = handle(target, toSide)
        let path = NSBezierPath(); path.move(to: a)
        var samples: [CGPoint] = [a]
        var previous = a
        var labelPoint = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        if source.id == target.id {
            let radius = hypot(source.box.width, source.box.height) / 2 + 48
            let outer = CGRect(x: source.center.x - radius, y: source.center.y - radius, width: radius * 2, height: radius * 2)
            func exit(_ p: CGPoint) -> (CGPoint, Int) {
                let dx = p.x - source.center.x, dy = p.y - source.center.y
                let tx = dx == 0 ? CGFloat.infinity : radius / abs(dx)
                let ty = dy == 0 ? CGFloat.infinity : radius / abs(dy)
                let scale = min(tx, ty)
                return (CGPoint(x: source.center.x + dx * scale, y: source.center.y + dy * scale), tx < ty ? (dx > 0 ? 1 : 3) : (dy > 0 ? 2 : 0))
            }
            let (start, s) = exit(a), (finish, t) = exit(b)
            let corners = [CGPoint(x: outer.minX, y: outer.minY), CGPoint(x: outer.maxX, y: outer.minY), CGPoint(x: outer.maxX, y: outer.maxY), CGPoint(x: outer.minX, y: outer.maxY)]
            func route(_ direction: Int) -> [CGPoint] {
                var points = [a, start], side = s
                while side != t { points.append(corners[(side + (direction == 1 ? 1 : 0)) % 4]); side = (side + direction + 4) % 4 }
                points.append(finish); points.append(b); return points
            }
            func length(_ points: [CGPoint]) -> CGFloat { zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } }
            let clockwise = route(1), counter = route(-1)
            let points = length(clockwise) <= length(counter) ? clockwise : counter
            for p in points.dropFirst() { path.line(to: p) }
            samples = points
            previous = points[points.count - 2]
            labelPoint = points[points.count / 2]
        } else {
            let style = raw["path"] as? String ?? "bezier"
            let v1 = direction(source, fromSide), v2 = direction(target, toSide)
            let distance = max(40, hypot(b.x - a.x, b.y - a.y) / 2)
            let c1 = CGPoint(x: a.x + v1.x * distance, y: a.y + v1.y * distance)
            let c2 = CGPoint(x: b.x + v2.x * distance, y: b.y + v2.y * distance)
            if style == "straight" {
                path.line(to: b)
                samples = [a, b]
            } else if style == "step" || style == "smooth" {
                let horizontal = abs(v1.x) >= abs(v1.y)
                let p1 = horizontal ? CGPoint(x: (a.x + b.x) / 2, y: a.y) : CGPoint(x: a.x, y: (a.y + b.y) / 2)
                let p2 = horizontal ? CGPoint(x: (a.x + b.x) / 2, y: b.y) : CGPoint(x: b.x, y: (a.y + b.y) / 2)
                if style == "smooth" {
                    path.curve(to: p2, controlPoint1: p1, controlPoint2: p1)
                    samples = sampleCubic(from: a, c1: p1, c2: p1, to: p2, steps: 16) + [b]
                } else {
                    path.line(to: p1); path.line(to: p2)
                    samples = [a, p1, p2, b]
                }
                path.line(to: b); previous = p2
                labelPoint = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
            } else {
                path.curve(to: b, controlPoint1: c1, controlPoint2: c2); previous = c2
                samples = sampleCubic(from: a, c1: c1, c2: c2, to: b, steps: 24)
                labelPoint = CGPoint(x: (a.x + 3 * c1.x + 3 * c2.x + b.x) / 8, y: (a.y + 3 * c1.y + 3 * c2.y + b.y) / 8)
            }
        }
        let label = raw["label"] as? String ?? ""
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
private func font(_ role: String, _ size: String) -> NSFont {
    let points: CGFloat = size == "s" ? 12 : size == "l" ? 24 : 16
    switch role {
    case "mono": return .monospacedSystemFont(ofSize: points, weight: .regular)
    case "heading": return .systemFont(ofSize: points, weight: .heavy)
    case "handwritten": return NSFont(name: "Bradley Hand", size: points) ?? .systemFont(ofSize: points)
    default: return .systemFont(ofSize: points)
    }
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
