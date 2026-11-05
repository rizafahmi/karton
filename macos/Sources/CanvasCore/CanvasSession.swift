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

/// Retained insertion identity and stacking position for exact Undo/Redo.
public struct CanvasShapeInsertion {
    public let id: String
    fileprivate let node: [String: Any]
    fileprivate let index: Int
}

/// Mutable in-memory document state. Persistence remains deliberately unavailable.
public final class CanvasSession {
    public let document: CanvasDocument
    public private(set) var root: [String: Any]

    public init(document: CanvasDocument) {
        self.document = document
        self.root = document.root
    }

    public func position(of id: String) -> CanvasPosition? {
        guard let node = node(id),
              let x = number(node["x"]),
              let y = number(node["y"]) else { return nil }
        return CanvasPosition(x: x, y: y)
    }

    public func isLocked(_ id: String) -> Bool {
        node(id)?["locked"] as? Bool == true
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
        root["nodes"] = nodes
    }
    private func node(_ id: String) -> [String: Any]? {
        (root["nodes"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }

    private func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        return number.doubleValue
    }
}
