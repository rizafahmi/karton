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
    }

    private struct EdgeDrawing {
        let path: NSBezierPath
        let end: CGPoint
        let previous: CGPoint
        let label: String
        let labelPoint: CGPoint
        let style: [String: Any]
        let marker: String
        let animated: Bool
    }

    private var nodes: [Node]
    private var edges: [EdgeDrawing]
    private let paper: [String: Any]
    private let fontRole: String
    private let origin: CGPoint
    private let session: CanvasSession
    private var selectedID: String?
    private var drag: (id: String, mouse: CGPoint, position: CanvasPosition)?
    private var textEditor: ShapeTextEditor?
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
        let edges = (root["edges"] as? [[String: Any]] ?? []).compactMap { raw -> EdgeDrawing? in
            guard let source = index[raw["source"] as? String ?? ""],
                  let target = index[raw["target"] as? String ?? ""] else { return nil }
            return Self.makeEdge(raw, source, target)
        }
        let role = (root["appearance"] as? [String: Any])?["font"] as? String ?? "sans"
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
    }

    public required init?(coder: NSCoder) { fatalError("CanvasView requires a document") }

    public override var acceptsFirstResponder: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
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
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = worldPoint(for: event)
        selectedID = nodes.reversed().first(where: { contains(point, node: $0) })?.id
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
        guard let drag else { return }
        let point = worldPoint(for: event)
        let position = CanvasPosition(
            x: drag.position.x + Double(point.x - drag.mouse.x),
            y: drag.position.y + Double(point.y - drag.mouse.y)
        )
        try? moveWithoutHistory(drag.id, to: position)
    }

    public override func mouseUp(with event: NSEvent) {
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
        if event.keyCode == 36 {
            beginTextEditing()
            return
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
        window?.undoManager?.undo()
    }

    @objc public func redoMove(_ sender: Any?) {
        window?.undoManager?.redo()
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
        window?.undoManager?.registerUndo(withTarget: self) { target in
            do { try target.changeText(id, to: before) }
            catch { NSSound.beep() }
        }
        window?.undoManager?.setActionName("Edit Text")
        needsDisplay = true
    }

    private func registerUndoMove(_ id: String, to position: CanvasPosition) {
        window?.undoManager?.registerUndo(withTarget: self) { target in
            target.performHistoryMove(id, to: position)
        }
        window?.undoManager?.setActionName("Move")
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
            return Self.makeEdge(raw, source, target)
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
        return outline(kind, node.box, number(node.data["radius"], kind == "text" ? 0 : 8)).contains(local)
    }

    private func drawSelection(_ node: Node) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: node.center.x, y: node.center.y)
        context.rotate(by: node.rotation * .pi / 180)
        context.translateBy(x: -node.center.x, y: -node.center.y)
        let path = NSBezierPath(rect: node.box.insetBy(dx: -5, dy: -5))
        NSColor.controlAccentColor.setStroke()
        path.lineWidth = 2
        path.setLineDash([5, 3], count: 2, phase: 0)
        path.stroke()
        context.restoreGState()
    }

    private func drawPaper(_ dirty: CGRect) {
        let background = paper["background"] as? String ?? "dots"
        guard background != "none" else { return }
        let grid = max(4, number(paper["grid"], 20))
        let path = NSBezierPath()
        NSColor.separatorColor.withAlphaComponent(0.35).setStroke()
        NSColor.separatorColor.withAlphaComponent(0.4).setFill()
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
            let path = outline(kind, node.box, number(data["radius"], kind == "text" ? 0 : 8))
            let fill = data["fill"] as? String ?? (kind == "text" ? "none" : "blue")
            palette(fill).setFill(); path.fill()
            palette(data["stroke"] as? String ?? (kind == "text" ? "none" : "blue")).setStroke()
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
        let color = palette(edge.style["stroke"] as? String ?? "ink")
        let width = edge.style["width"] as? NSNumber
        let validWidth = width != nil && CFGetTypeID(width!) != CFBooleanGetTypeID() && [1.0, 2.0, 4.0].contains(width!.doubleValue)
        color.setStroke(); edge.path.lineWidth = validWidth ? CGFloat(width!.doubleValue) : 2
        let dash = edge.style["dash"] as? NSNumber
        let dashed = dash != nil && CFGetTypeID(dash!) == CFBooleanGetTypeID() ? dash!.boolValue : edge.animated
        if dashed { edge.path.setLineDash([6, 4], count: 2, phase: 0) }
        edge.path.stroke()
        if edge.marker == "arrow" { drawArrow(at: edge.end, from: edge.previous, color: color) }
        if edge.marker == "dot" { color.setFill(); NSBezierPath(ovalIn: CGRect(x: edge.end.x - 4, y: edge.end.y - 4, width: 8, height: 8)).fill() }
        if !edge.label.isEmpty {
            let size = Self.labelSize(edge.label, role: fontRole)
            let rect = CGRect(x: edge.labelPoint.x - size.width / 2, y: edge.labelPoint.y - size.height / 2, width: size.width, height: size.height)
            NSColor.textBackgroundColor.setFill(); NSBezierPath(roundedRect: rect.insetBy(dx: -4, dy: -2), xRadius: 3, yRadius: 3).fill()
            (edge.label as NSString).draw(in: rect, withAttributes: [.font: font(fontRole, "m"), .foregroundColor: NSColor.labelColor])
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

    private static func makeEdge(_ raw: [String: Any], _ source: Node, _ target: Node) -> EdgeDrawing {
        let fromSide = raw["source_handle"] as? String ?? nearestSide(source, target.center)
        let toSide = raw["target_handle"] as? String ?? nearestSide(target, source.center)
        let a = handle(source, fromSide), b = handle(target, toSide)
        let path = NSBezierPath(); path.move(to: a)
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
            previous = points[points.count - 2]
            labelPoint = points[points.count / 2]
        } else {
            let style = raw["path"] as? String ?? "bezier"
            let v1 = direction(source, fromSide), v2 = direction(target, toSide)
            let distance = max(40, hypot(b.x - a.x, b.y - a.y) / 2)
            let c1 = CGPoint(x: a.x + v1.x * distance, y: a.y + v1.y * distance)
            let c2 = CGPoint(x: b.x + v2.x * distance, y: b.y + v2.y * distance)
            if style == "straight" { path.line(to: b) }
            else if style == "step" || style == "smooth" {
                let horizontal = abs(v1.x) >= abs(v1.y)
                let p1 = horizontal ? CGPoint(x: (a.x + b.x) / 2, y: a.y) : CGPoint(x: a.x, y: (a.y + b.y) / 2)
                let p2 = horizontal ? CGPoint(x: (a.x + b.x) / 2, y: b.y) : CGPoint(x: b.x, y: (a.y + b.y) / 2)
                if style == "smooth" {
                    path.curve(to: p2, controlPoint1: p1, controlPoint2: p1)
                } else { path.line(to: p1); path.line(to: p2) }
                path.line(to: b); previous = p2
                labelPoint = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
            } else {
                path.curve(to: b, controlPoint1: c1, controlPoint2: c2); previous = c2
                labelPoint = CGPoint(x: (a.x + 3 * c1.x + 3 * c2.x + b.x) / 8, y: (a.y + 3 * c1.y + 3 * c2.y + b.y) / 8)
            }
        }
        let data = raw["data"] as? [String: Any] ?? [:]
        return EdgeDrawing(path: path, end: b, previous: previous, label: raw["label"] as? String ?? "", labelPoint: labelPoint, style: data["connector_style"] as? [String: Any] ?? [:], marker: raw["marker"] as? String ?? "arrow", animated: raw["animated"] as? Bool ?? false)
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
    switch name {
    case "none": return .clear
    case "surface": return .controlBackgroundColor
    case "accent": return .controlAccentColor
    case "gray": return .systemGray
    case "blue": return .systemBlue
    case "green": return .systemGreen
    case "yellow": return .systemYellow
    case "red": return .systemRed
    case "violet": return .systemPurple
    default: return .labelColor
    }
}
private func textColor(on fill: String) -> NSColor {
    guard fill != "none", let color = palette(fill).usingColorSpace(.deviceRGB) else { return .labelColor }
    func linear(_ component: CGFloat) -> CGFloat {
        component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
    }
    let luminance = 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent) + 0.0722 * linear(color.blueComponent)
    return luminance > 0.179 ? .black : .white
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
