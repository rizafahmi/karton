import Foundation

public struct CanvasPosition: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct CanvasMove: Equatable, Sendable {
    public let id: String
    public let before: CanvasPosition
    public let after: CanvasPosition
}

public enum CanvasShapeKind: String, CaseIterable, Sendable {
    case rectangle = "rect"
    case ellipse, diamond, triangle, text
}

public enum CanvasLineKind: String, CaseIterable, Sendable {
    case line, arrow
}

/// Retained insertion identity and stacking position for exact Undo/Redo.
public struct CanvasShapeInsertion {
    public let id: String
    fileprivate let node: [String: Any]
    fileprivate let index: Int
}

public enum CanvasConnectionSide: String, CaseIterable, Sendable {
    case top, right, bottom, left
}

public struct CanvasConnectionInsertion {
    public let id: String
    fileprivate let edge: [String: Any]
    fileprivate let index: Int
}

/// Retained node and incident connections for atomic Delete Undo/Redo.
public struct CanvasNodeDeletion {
    public let id: String
    fileprivate let node: [String: Any]
    fileprivate let index: Int
    fileprivate let edges: [(index: Int, edge: [String: Any])]
}

public struct CanvasStackMove: Equatable, Sendable {
    public let id: String
    public let fromIndex: Int
    public let toIndex: Int
}

/// Mutable in-memory document state. Persistence remains deliberately unavailable.
public final class CanvasSession {
    public let document: CanvasDocument
    public private(set) var root: [String: Any]

    public init(document: CanvasDocument) {
        self.document = document
        self.root = document.root
    }

    /// Captures a validated UTF-8 JSON snapshot of the current session state
    /// without mutating the opened document's original bytes or writing a file.
    public func encodedData() throws -> Data {
        try CanvasDocument.encode(root)
    }

    /// Reopens the current session state as an independent validated document.
    public func encodedDocument() throws -> CanvasDocument {
        try CanvasDocument(data: encodedData())
    }

    public func position(of id: String) -> CanvasPosition? {
        guard let node = node(id),
              let x = number(node["x"]),
              let y = number(node["y"]) else { return nil }
        return CanvasPosition(x: x, y: y)
    }

    public func lockedValue(of id: String) -> Bool? {
        node(id)?["locked"] as? Bool
    }

    public func isLocked(_ id: String) -> Bool {
        lockedValue(of: id) == true
    }

    @discardableResult
    public func setLocked(_ id: String, to locked: Bool?) throws -> Bool {
        guard var nodes = root["nodes"] as? [[String: Any]],
              let index = nodes.firstIndex(where: { $0["id"] as? String == id }) else {
            throw CanvasDocumentError("Unknown node ID: \(id).")
        }
        let previous = nodes[index]["locked"] as? Bool
        guard previous != locked else { return false }
        nodes[index]["locked"] = locked
        root["nodes"] = nodes
        return true
    }

    @discardableResult
    public func move(_ id: String, to position: CanvasPosition) throws -> CanvasMove? {
        guard position.x.isFinite, position.y.isFinite,
              abs(position.x) <= 1_000_000, abs(position.y) <= 1_000_000 else {
            throw CanvasDocumentError("Node \(id) needs finite coordinates within 1000000.")
        }
        guard var nodes = root["nodes"] as? [[String: Any]],
              let index = nodes.firstIndex(where: { $0["id"] as? String == id }),
              let before = self.position(of: id) else {
            throw CanvasDocumentError("Unknown node ID: \(id).")
        }
        guard !isLocked(id) else {
            throw CanvasDocumentError("Node \(id) is locked.")
        }
        guard before != position else { return nil }
        var node = nodes[index]
        node["x"] = position.x
        node["y"] = position.y
        nodes[index] = node
        root["nodes"] = nodes
        return CanvasMove(id: id, before: before, after: position)
    }
    public func geometry(of id: String) -> CanvasGeometry? {
        guard let raw = node(id), let data = raw["data"] as? [String: Any],
              let x = number(raw["x"]), let y = number(raw["y"]),
              let width = number(raw["width"]), let height = number(raw["height"]) else { return nil }
        return CanvasGeometry(x: x, y: y, width: width, height: height, rotation: number(data["rotation"]))
    }

    public func canTransform(_ id: String) -> Bool {
        guard let type = node(id)?["type"] as? String else { return false }
        return (type == "shape" || type == "code") && !isLocked(id)
    }

    @discardableResult
    public func setGeometry(_ id: String, to geometry: CanvasGeometry) throws -> Bool {
        try geometry.validate()
        guard canTransform(id),
              var nodes = root["nodes"] as? [[String: Any]],
              let index = nodes.firstIndex(where: { $0["id"] as? String == id }),
              var data = nodes[index]["data"] as? [String: Any] else {
            throw CanvasDocumentError("Select an unlocked shape or code block to resize/rotate.")
        }
        guard self.geometry(of: id) != geometry else { return false }
        nodes[index]["x"] = geometry.x
        nodes[index]["y"] = geometry.y
        nodes[index]["width"] = geometry.width
        nodes[index]["height"] = geometry.height
        data["rotation"] = geometry.rotation
        nodes[index]["data"] = data
        root["nodes"] = nodes
        return true
    }

    public func lineGeometry(of id: String) -> CanvasLineGeometry? {
        guard let raw = node(id), raw["type"] as? String == "shape-line",
              let data = raw["data"] as? [String: Any],
              let x = number(raw["x"]), let y = number(raw["y"]),
              let width = number(raw["width"]), let height = number(raw["height"]),
              let from = data["from"] as? [Any], from.count == 2,
              let fx = number(from[0]), let fy = number(from[1]),
              let to = data["to"] as? [Any], to.count == 2,
              let tx = number(to[0]), let ty = number(to[1]) else { return nil }
        return CanvasLineGeometry(
            x: x, y: y, width: width, height: height,
            from: CanvasPosition(x: fx, y: fy),
            to: CanvasPosition(x: tx, y: ty),
            rotation: number(data["rotation"])
        )
    }

    public func canEditLineEndpoints(_ id: String) -> Bool {
        node(id)?["type"] as? String == "shape-line" && !isLocked(id)
    }

    @discardableResult
    public func setLineGeometry(_ id: String, to geometry: CanvasLineGeometry) throws -> Bool {
        try geometry.validate()
        guard canEditLineEndpoints(id),
              var nodes = root["nodes"] as? [[String: Any]],
              let index = nodes.firstIndex(where: { $0["id"] as? String == id }),
              var data = nodes[index]["data"] as? [String: Any] else {
            throw CanvasDocumentError("Select an unlocked line or arrow to edit its endpoints.")
        }
        guard self.lineGeometry(of: id) != geometry else { return false }
        nodes[index]["x"] = geometry.x
        nodes[index]["y"] = geometry.y
        nodes[index]["width"] = geometry.width
        nodes[index]["height"] = geometry.height
        data["from"] = [geometry.from.x, geometry.from.y]
        data["to"] = [geometry.to.x, geometry.to.y]
        data["rotation"] = geometry.rotation
        nodes[index]["data"] = data
        root["nodes"] = nodes
        return true
    }

    public func text(of id: String) -> String? {
        (node(id)?["data"] as? [String: Any])?["text"] as? String
    }

    public func canEditText(_ id: String) -> Bool {
        node(id)?["type"] as? String == "shape" && !isLocked(id)
    }

    /// Changes only the caption; nil restores an originally absent text field.
    @discardableResult
    public func setText(_ id: String, to text: String?) throws -> Bool {
        guard canEditText(id),
              var nodes = root["nodes"] as? [[String: Any]],
              let index = nodes.firstIndex(where: { $0["id"] as? String == id }),
              var data = nodes[index]["data"] as? [String: Any] else {
            throw CanvasDocumentError("Select an unlocked shape to edit its text.")
        }
        if let text, text.count > 2_000 {
            throw CanvasDocumentError("Text must contain at most 2000 characters.")
        }
        guard self.text(of: id) != text else { return false }
        data["text"] = text
        nodes[index]["data"] = data
        root["nodes"] = nodes
        return true
    }

    public func insertShape(
        _ kind: CanvasShapeKind, at position: CanvasPosition, text: String? = nil
    ) throws -> CanvasShapeInsertion {
        guard position.x.isFinite, position.y.isFinite,
              abs(position.x) <= 1_000_000, abs(position.y) <= 1_000_000 else {
            throw CanvasDocumentError("A shape needs finite coordinates within 1000000.")
        }
        if let text, text.count > 2_000 {
            throw CanvasDocumentError("Text must contain at most 2000 characters.")
        }
        let id = UUID().uuidString
        var data: [String: Any] = [
            "kind": kind.rawValue, "fill": "none",
            "stroke": kind == .text ? "none" : "ink", "radius": 0
        ]
        data["text"] = text
        let raw: [String: Any] = [
            "id": id, "type": "shape", "x": position.x, "y": position.y,
            "width": 160, "height": kind == .text ? 48 : 96,
            "data": data
        ]
        let insertion = CanvasShapeInsertion(
            id: id, node: raw, index: (root["nodes"] as? [[String: Any]])?.count ?? 0
        )
        try restoreInsertion(insertion)
        return insertion
    }

    public func insertLine(
        _ kind: CanvasLineKind, centeredAt center: CanvasPosition
    ) throws -> CanvasShapeInsertion {
        guard center.x.isFinite, center.y.isFinite,
              abs(center.x) <= 1_000_000, abs(center.y) <= 1_000_000 else {
            throw CanvasDocumentError("A line needs finite coordinates within 1000000.")
        }
        return try insertLine(
            kind,
            from: CanvasPosition(x: center.x - 80, y: center.y),
            to: CanvasPosition(x: center.x + 80, y: center.y)
        )
    }

    public func insertLine(
        _ kind: CanvasLineKind, from start: CanvasPosition, to end: CanvasPosition
    ) throws -> CanvasShapeInsertion {
        let geometry = CanvasLineGeometry(start: start, end: end)
        try geometry.validate()
        let id = UUID().uuidString
        let data: [String: Any] = [
            "from": [geometry.from.x, geometry.from.y],
            "to": [geometry.to.x, geometry.to.y],
            "stroke": "ink",
            "width": 2,
            "arrow": kind == .arrow ? "end" : "none"
        ]
        let raw: [String: Any] = [
            "id": id, "type": "shape-line",
            "x": geometry.x, "y": geometry.y,
            "width": geometry.width, "height": geometry.height,
            "data": data
        ]
        let insertion = CanvasShapeInsertion(
            id: id, node: raw, index: (root["nodes"] as? [[String: Any]])?.count ?? 0
        )
        try restoreInsertion(insertion)
        return insertion
    }

    public func removeInsertion(_ insertion: CanvasShapeInsertion) throws {
        guard var nodes = root["nodes"] as? [[String: Any]],
              let index = nodes.firstIndex(where: { $0["id"] as? String == insertion.id }),
              !isLocked(insertion.id) else {
            throw CanvasDocumentError("The inserted shape is missing or locked.")
        }
        let edges = root["edges"] as? [[String: Any]] ?? []
        guard !edges.contains(where: {
            $0["source"] as? String == insertion.id || $0["target"] as? String == insertion.id
        }) else {
            throw CanvasDocumentError("Undo connections before undoing shape insertion.")
        }
        nodes.remove(at: index)
        root["nodes"] = nodes
    }

    public func restoreInsertion(_ insertion: CanvasShapeInsertion) throws {
        guard var nodes = root["nodes"] as? [[String: Any]],
              insertion.index <= nodes.count, node(insertion.id) == nil else {
            throw CanvasDocumentError("Cannot restore the inserted shape at its original position.")
        }
        nodes.insert(insertion.node, at: insertion.index)
        var candidate = root
        candidate["nodes"] = nodes
        try CanvasDocument.validate(candidate)
        root = candidate
    }

    public func canDuplicateNode(_ id: String) -> Bool {
        node(id) != nil && !isLocked(id)
    }

    @discardableResult
    public func duplicateNode(
        _ id: String, offset: CanvasPosition = CanvasPosition(x: 24, y: 24)
    ) throws -> CanvasShapeInsertion {
        guard let sourceNode = node(id) else {
            throw CanvasDocumentError("Unknown node ID: \(id).")
        }
        guard !isLocked(id) else {
            throw CanvasDocumentError("Node \(id) is locked.")
        }
        guard let x = number(sourceNode["x"]), let y = number(sourceNode["y"]) else {
            throw CanvasDocumentError("Node \(id) needs finite coordinates.")
        }
        let newID = UUID().uuidString
        var copy: [String: Any] = [
            "id": newID,
            "type": sourceNode["type"] as Any,
            "x": x + offset.x,
            "y": y + offset.y,
            "width": sourceNode["width"] as Any,
            "height": sourceNode["height"] as Any,
            "data": sourceNode["data"] as Any
        ]
        if let parent = sourceNode["parent"] {
            copy["parent"] = parent
        }
        let insertion = CanvasShapeInsertion(
            id: newID, node: copy, index: (root["nodes"] as? [[String: Any]])?.count ?? 0
        )
        try restoreInsertion(insertion)
        return insertion
    }

    public func canDeleteNode(_ id: String) -> Bool {
        node(id) != nil && !isLocked(id)
    }

    @discardableResult
    public func deleteNode(_ id: String) throws -> CanvasNodeDeletion {
        guard var nodes = root["nodes"] as? [[String: Any]],
              let index = nodes.firstIndex(where: { $0["id"] as? String == id }) else {
            throw CanvasDocumentError("Unknown node ID: \(id).")
        }
        guard !isLocked(id) else {
            throw CanvasDocumentError("Node \(id) is locked.")
        }
        let removedNode = nodes.remove(at: index)
        let currentEdges = root["edges"] as? [[String: Any]] ?? []
        var removedEdges: [(index: Int, edge: [String: Any])] = []
        var remainingEdges: [[String: Any]] = []
        for (edgeIndex, edge) in currentEdges.enumerated() {
            if edge["source"] as? String == id || edge["target"] as? String == id {
                removedEdges.append((index: edgeIndex, edge: edge))
            } else {
                remainingEdges.append(edge)
            }
        }
        root["nodes"] = nodes
        root["edges"] = remainingEdges
        return CanvasNodeDeletion(id: id, node: removedNode, index: index, edges: removedEdges)
    }

    public func restoreNodeDeletion(_ deletion: CanvasNodeDeletion) throws {
        guard var nodes = root["nodes"] as? [[String: Any]],
              deletion.index <= nodes.count, node(deletion.id) == nil else {
            throw CanvasDocumentError("Cannot restore the deleted object at its original position.")
        }
        nodes.insert(deletion.node, at: deletion.index)
        var edges = root["edges"] as? [[String: Any]] ?? []
        for item in deletion.edges {
            guard item.index <= edges.count,
                  let edgeID = item.edge["id"] as? String,
                  !edges.contains(where: { $0["id"] as? String == edgeID }) else {
                throw CanvasDocumentError("Cannot restore a deleted connection at its original position.")
            }
            edges.insert(item.edge, at: item.index)
        }
        var candidate = root
        candidate["nodes"] = nodes
        candidate["edges"] = edges
        try CanvasDocument.validate(candidate)
        root = candidate
    }

    public func nodeIndex(of id: String) -> Int? {
        (root["nodes"] as? [[String: Any]])?.firstIndex { $0["id"] as? String == id }
    }

    public func canBringToFront(_ id: String) -> Bool {
        guard let nodes = root["nodes"] as? [[String: Any]],
              let index = nodeIndex(of: id), !isLocked(id) else { return false }
        return index < nodes.count - 1
    }

    public func canSendToBack(_ id: String) -> Bool {
        guard let index = nodeIndex(of: id), !isLocked(id) else { return false }
        return index > 0
    }

    @discardableResult
    public func bringToFront(_ id: String) throws -> CanvasStackMove? {
        guard let nodes = root["nodes"] as? [[String: Any]], node(id) != nil else {
            throw CanvasDocumentError("Unknown node ID: \(id).")
        }
        guard !isLocked(id) else {
            throw CanvasDocumentError("Node \(id) is locked.")
        }
        return try moveNode(id, toIndex: nodes.count - 1)
    }

    @discardableResult
    public func sendToBack(_ id: String) throws -> CanvasStackMove? {
        guard node(id) != nil else {
            throw CanvasDocumentError("Unknown node ID: \(id).")
        }
        guard !isLocked(id) else {
            throw CanvasDocumentError("Node \(id) is locked.")
        }
        return try moveNode(id, toIndex: 0)
    }

    @discardableResult
    public func moveNode(_ id: String, toIndex targetIndex: Int) throws -> CanvasStackMove? {
        guard var nodes = root["nodes"] as? [[String: Any]],
              let fromIndex = nodes.firstIndex(where: { $0["id"] as? String == id }) else {
            throw CanvasDocumentError("Unknown node ID: \(id).")
        }
        guard !isLocked(id) else {
            throw CanvasDocumentError("Node \(id) is locked.")
        }
        guard (0..<nodes.count).contains(targetIndex) else {
            throw CanvasDocumentError("Target stacking index is out of bounds.")
        }
        guard fromIndex != targetIndex else { return nil }
        let item = nodes.remove(at: fromIndex)
        nodes.insert(item, at: targetIndex)
        root["nodes"] = nodes
        return CanvasStackMove(id: id, fromIndex: fromIndex, toIndex: targetIndex)
    }
    public func insertConnection(
        source: String, sourceSide: CanvasConnectionSide? = nil,
        target: String, targetSide: CanvasConnectionSide? = nil
    ) throws -> CanvasConnectionInsertion {
        try validateConnection(source: source, sourceSide: sourceSide, target: target, targetSide: targetSide)
        let id = UUID().uuidString
        var edge: [String: Any] = [
            "id": id, "source": source, "target": target, "path": "bezier", "marker": "arrow"
        ]
        edge["source_handle"] = sourceSide?.rawValue
        edge["target_handle"] = targetSide?.rawValue
        var edges = root["edges"] as? [[String: Any]] ?? []
        let insertion = CanvasConnectionInsertion(
            id: id, edge: edge, index: edges.count
        )
        edges.append(edge)
        root["edges"] = edges
        return insertion
    }

    public func removeInsertion(_ insertion: CanvasConnectionInsertion) throws {
        guard var edges = root["edges"] as? [[String: Any]],
              let index = edges.firstIndex(where: { $0["id"] as? String == insertion.id }) else {
            throw CanvasDocumentError("The inserted connection is missing.")
        }
        edges.remove(at: index)
        root["edges"] = edges
    }

    public func hasConnection(_ id: String) -> Bool {
        (root["edges"] as? [[String: Any]])?.contains { $0["id"] as? String == id } == true
    }

    @discardableResult
    public func deleteConnection(_ id: String) throws -> CanvasConnectionInsertion {
        guard var edges = root["edges"] as? [[String: Any]],
              let index = edges.firstIndex(where: { $0["id"] as? String == id }) else {
            throw CanvasDocumentError("Unknown connection ID: \(id).")
        }
        let removed = edges.remove(at: index)
        root["edges"] = edges
        return CanvasConnectionInsertion(id: id, edge: removed, index: index)
    }

    public func restoreInsertion(_ insertion: CanvasConnectionInsertion) throws {
        let edge = insertion.edge
        try validateConnection(
            source: edge["source"] as? String ?? "",
            sourceSide: (edge["source_handle"] as? String).flatMap(CanvasConnectionSide.init(rawValue:)),
            target: edge["target"] as? String ?? "",
            targetSide: (edge["target_handle"] as? String).flatMap(CanvasConnectionSide.init(rawValue:))
        )
        guard var edges = root["edges"] as? [[String: Any]],
              insertion.index <= edges.count,
              !edges.contains(where: { $0["id"] as? String == insertion.id }) else {
            throw CanvasDocumentError("Cannot restore the connection at its original position.")
        }
        edges.insert(edge, at: insertion.index)
        root["edges"] = edges
    }

    private func validateConnection(
        source: String, sourceSide: CanvasConnectionSide?,
        target: String, targetSide: CanvasConnectionSide?
    ) throws {
        guard let sourceNode = node(source), let targetNode = node(target),
              sourceNode["type"] as? String != "shape-line",
              targetNode["type"] as? String != "shape-line" else {
            throw CanvasDocumentError("Choose existing source and target objects.")
        }
        if source == target && (sourceSide == nil || targetSide == nil || sourceSide == targetSide) {
            throw CanvasDocumentError("A self-loop needs two different named sides, not Automatic.")
        }
    }

    private func node(_ id: String) -> [String: Any]? {
        (root["nodes"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }

    private func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }
}
