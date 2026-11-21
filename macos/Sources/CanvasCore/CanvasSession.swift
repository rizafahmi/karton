import CoreFoundation
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

    public init(id: String, before: CanvasPosition, after: CanvasPosition) {
        self.id = id
        self.before = before
        self.after = after
    }
}

public struct CanvasBatchMove: Equatable, Sendable {
    public let moves: [CanvasMove]

    public init(moves: [CanvasMove]) {
        self.moves = moves
    }

    public var inverse: CanvasBatchMove {
        CanvasBatchMove(moves: moves.map { CanvasMove(id: $0.id, before: $0.after, after: $0.before) })
    }
}

public enum CanvasAlignment: String, CaseIterable, Sendable {
    case left
    case centerHorizontal
    case right
    case top
    case centerVertical
    case bottom
    case distributeHorizontally
    case distributeVertically

    public var actionName: String {
        switch self {
        case .left: return "Align Left"
        case .centerHorizontal: return "Align Horizontal Centers"
        case .right: return "Align Right"
        case .top: return "Align Top"
        case .centerVertical: return "Align Vertical Centers"
        case .bottom: return "Align Bottom"
        case .distributeHorizontally: return "Distribute Horizontally"
        case .distributeVertically: return "Distribute Vertically"
        }
    }

    public var minimumSelectionCount: Int {
        switch self {
        case .distributeHorizontally, .distributeVertically: return 3
        default: return 2
        }
    }
}

public enum CanvasShapeKind: String, CaseIterable, Sendable {
    case rectangle = "rect"
    case ellipse, diamond, triangle, text
}

public enum CanvasLineKind: String, CaseIterable, Sendable {
    case line, arrow
}

public enum CanvasStyleProperty: String, CaseIterable, Sendable {
    case paperBackground = "background"
    case paperGrid = "grid"
    case fill, stroke, width, dash, radius, arrow, path, marker, font, size, align
}

public enum CanvasStyleValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case omitted
}

public struct CanvasStyleChange {
    fileprivate enum Target {
        case node(id: String, beforeData: [String: Any], afterData: [String: Any])
        case connection(id: String, beforeEdge: [String: Any], afterEdge: [String: Any])
        case document(key: String, beforeValue: Any?, afterValue: Any?)
    }
    fileprivate let target: Target

    public var inverse: CanvasStyleChange {
        switch target {
        case .node(let id, let before, let after):
            return CanvasStyleChange(target: .node(id: id, beforeData: after, afterData: before))
        case .connection(let id, let before, let after):
            return CanvasStyleChange(target: .connection(id: id, beforeEdge: after, afterEdge: before))
        case .document(let key, let before, let after):
            return CanvasStyleChange(target: .document(key: key, beforeValue: after, afterValue: before))
        }
    }
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

public struct CanvasConnectionState: Equatable, Sendable {
    public let id: String
    public let source: String
    public let sourceSide: CanvasConnectionSide?
    public let target: String
    public let targetSide: CanvasConnectionSide?
    public let label: String?

    public init(
        id: String,
        source: String,
        sourceSide: CanvasConnectionSide?,
        target: String,
        targetSide: CanvasConnectionSide?,
        label: String?
    ) {
        self.id = id
        self.source = source
        self.sourceSide = sourceSide
        self.target = target
        self.targetSide = targetSide
        self.label = label
    }
}

public struct CanvasConnectionUpdate {
    public let id: String
    fileprivate let beforeEdge: [String: Any]
    fileprivate let afterEdge: [String: Any]

    public var inverse: CanvasConnectionUpdate {
        CanvasConnectionUpdate(id: id, beforeEdge: afterEdge, afterEdge: beforeEdge)
    }
}

public struct CanvasAttachment: Equatable, Sendable {
    public let filename: String
    public let mediaType: String
    public let encoding: String
    public let content: String

    public var utf8ByteCount: Int { content.utf8.count }
}

public struct CanvasTextChange {
    public let id: String
    fileprivate let beforeNode: [String: Any]
    fileprivate let afterNode: [String: Any]

    public var inverse: CanvasTextChange {
        CanvasTextChange(id: id, beforeNode: afterNode, afterNode: beforeNode)
    }
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

public struct CanvasClipboardPayload: @unchecked Sendable {
    public let nodes: [[String: Any]]
    public let edges: [[String: Any]]

    public init(nodes: [[String: Any]], edges: [[String: Any]] = []) {
        self.nodes = nodes
        self.edges = edges
    }

    public func encodedData() throws -> Data {
        try CanvasJSON.encode([
            "nodes": nodes,
            "edges": edges
        ])
    }

    public static func decode(from data: Data) throws -> CanvasClipboardPayload {
        guard let root = try JSONDecoder().decode(CanvasJSON.self, from: data).value as? [String: Any],
              let nodes = root["nodes"] as? [[String: Any]],
              !nodes.isEmpty else {
            throw CanvasDocumentError("Clipboard does not contain valid canvas objects.")
        }
        let edges = root["edges"] as? [[String: Any]] ?? []
        return CanvasClipboardPayload(nodes: nodes, edges: edges)
    }
}

public struct CanvasBatchInsertion: @unchecked Sendable {
    public let nodeIDs: [String]
    public let edgeIDs: [String]
    fileprivate let nodes: [(index: Int, node: [String: Any])]
    fileprivate let edges: [(index: Int, edge: [String: Any])]
}

public struct CanvasBatchDeletion: @unchecked Sendable {
    public let ids: [String]
    fileprivate let nodes: [(index: Int, node: [String: Any])]
    fileprivate let edges: [(index: Int, edge: [String: Any])]
}

public struct CanvasBatchStackMove: @unchecked Sendable {
    public let ids: [String]
    fileprivate let beforeNodes: [[String: Any]]
    fileprivate let afterNodes: [[String: Any]]

    public var inverse: CanvasBatchStackMove {
        CanvasBatchStackMove(ids: ids, beforeNodes: afterNodes, afterNodes: beforeNodes)
    }
}

/// Mutable in-memory document state with monotonically increasing committed revision tracking.
public final class CanvasSession {
    public let document: CanvasDocument
    public private(set) var revision: UInt64 = 0
    public var isReadOnly: Bool = false
    public var onDidMutate: ((UInt64) -> Void)?
    public private(set) var root: [String: Any] {
        didSet {
            guard !suppressRevisionIncrement else { return }
            revision &+= 1
            onDidMutate?(revision)
        }
    }
    private var suppressRevisionIncrement = false

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

    /// Produces a validated version-2 JSON snapshot copy with only the root version changed
    /// if the session is currently version 1, leaving this session's root and revision untouched.
    public func encodedVersion2CopyData() throws -> Data {
        var copy = root
        copy["version"] = 2
        return try CanvasDocument.encode(copy)
    }

    /// Replaces the in-memory root with a validated document (for Reload from Disk or Recovery restoration).
    public func replaceRoot(_ newRoot: [String: Any], revision newRevision: UInt64 = 0) throws {
        try CanvasDocument.validate(newRoot)
        suppressRevisionIncrement = true
        root = newRoot
        suppressRevisionIncrement = false
        revision = newRevision
        onDidMutate?(revision)
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
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        guard var nodes = root["nodes"] as? [[String: Any]],
              let index = nodes.firstIndex(where: { $0["id"] as? String == id }) else {
            throw CanvasDocumentError("Unknown node ID: \(id).")
        }
        let previous = nodes[index]["locked"] as? Bool
        guard previous != locked else { return false }
        var updated = nodes[index]
        updated["locked"] = locked
        nodes[index] = updated
        var candidate = root
        candidate["nodes"] = nodes
        root = candidate
        return true
    }

    @discardableResult
    public func move(_ id: String, to position: CanvasPosition) throws -> CanvasMove? {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
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
        var candidate = root
        candidate["nodes"] = nodes
        root = candidate
        return CanvasMove(id: id, before: before, after: position)
    }

    /// Visual axis-aligned bounds used for aligning and distributing an item.
    /// Uses endpoint bounds for standalone lines/arrows and rotated bounds for shapes/code.
    public func alignmentBounds(of id: String) -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        if let line = lineGeometry(of: id) {
            let start = line.point(for: .start)
            let end = line.point(for: .end)
            return (
                minX: min(start.x, end.x),
                minY: min(start.y, end.y),
                maxX: max(start.x, end.x),
                maxY: max(start.y, end.y)
            )
        }
        guard let geo = geometry(of: id) else { return nil }
        let b = geo.rotatedAxisAlignedBounds
        return (minX: b.x, minY: b.y, maxX: b.x + b.width, maxY: b.y + b.height)
    }

    public func canAlignNodes(_ ids: [String], alignment: CanvasAlignment) -> Bool {
        guard !isReadOnly else { return false }
        let idSet = Set(ids)
        let rawNodes = root["nodes"] as? [[String: Any]] ?? []
        var matched = 0
        var unlocked = 0
        for raw in rawNodes {
            guard let id = raw["id"] as? String, idSet.contains(id) else { continue }
            matched += 1
            if !isLocked(id) { unlocked += 1 }
        }
        return matched >= alignment.minimumSelectionCount && unlocked > 0
    }

    @discardableResult
    public func alignNodes(_ ids: [String], alignment: CanvasAlignment) throws -> CanvasBatchMove? {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        guard var nodes = root["nodes"] as? [[String: Any]] else { return nil }
        let idSet = Set(ids)
        struct AlignItem {
            let id: String
            let nodeIndex: Int
            let position: CanvasPosition
            let minX: Double
            let minY: Double
            let maxX: Double
            let maxY: Double
            let locked: Bool
            var width: Double { maxX - minX }
            var height: Double { maxY - minY }
            var midX: Double { (minX + maxX) / 2.0 }
            var midY: Double { (minY + maxY) / 2.0 }
        }
        var items: [AlignItem] = []
        for (index, raw) in nodes.enumerated() {
            guard let id = raw["id"] as? String, idSet.contains(id),
                  let pos = position(of: id),
                  let bounds = alignmentBounds(of: id) else { continue }
            items.append(AlignItem(
                id: id,
                nodeIndex: index,
                position: pos,
                minX: bounds.minX,
                minY: bounds.minY,
                maxX: bounds.maxX,
                maxY: bounds.maxY,
                locked: isLocked(id)
            ))
        }
        guard items.count >= alignment.minimumSelectionCount,
              items.contains(where: { !$0.locked }) else { return nil }

        let selectionMinX = items.map(\.minX).min()!
        let selectionMaxX = items.map(\.maxX).max()!
        let selectionMidX = (selectionMinX + selectionMaxX) / 2.0
        let selectionMinY = items.map(\.minY).min()!
        let selectionMaxY = items.map(\.maxY).max()!
        let selectionMidY = (selectionMinY + selectionMaxY) / 2.0

        var deltas: [String: (dx: Double, dy: Double)] = [:]
        switch alignment {
        case .left:
            for item in items { deltas[item.id] = (selectionMinX - item.minX, 0) }
        case .centerHorizontal:
            for item in items { deltas[item.id] = (selectionMidX - item.midX, 0) }
        case .right:
            for item in items { deltas[item.id] = (selectionMaxX - item.maxX, 0) }
        case .top:
            for item in items { deltas[item.id] = (0, selectionMinY - item.minY) }
        case .centerVertical:
            for item in items { deltas[item.id] = (0, selectionMidY - item.midY) }
        case .bottom:
            for item in items { deltas[item.id] = (0, selectionMaxY - item.maxY) }
        case .distributeHorizontally:
            let sorted = items.sorted { lhs, rhs in
                if lhs.minX != rhs.minX { return lhs.minX < rhs.minX }
                if lhs.midX != rhs.midX { return lhs.midX < rhs.midX }
                return lhs.nodeIndex < rhs.nodeIndex
            }
            let totalSpan = sorted.last!.maxX - sorted.first!.minX
            let totalWidth = sorted.reduce(0.0) { $0 + $1.width }
            let gap = (totalSpan - totalWidth) / Double(sorted.count - 1)
            var cursor = sorted.first!.maxX + gap
            for idx in 1..<(sorted.count - 1) {
                let item = sorted[idx]
                deltas[item.id] = (cursor - item.minX, 0)
                cursor += item.width + gap
            }
        case .distributeVertically:
            let sorted = items.sorted { lhs, rhs in
                if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
                if lhs.midY != rhs.midY { return lhs.midY < rhs.midY }
                return lhs.nodeIndex < rhs.nodeIndex
            }
            let totalSpan = sorted.last!.maxY - sorted.first!.minY
            let totalHeight = sorted.reduce(0.0) { $0 + $1.height }
            let gap = (totalSpan - totalHeight) / Double(sorted.count - 1)
            var cursor = sorted.first!.maxY + gap
            for idx in 1..<(sorted.count - 1) {
                let item = sorted[idx]
                deltas[item.id] = (0, cursor - item.minY)
                cursor += item.height + gap
            }
        }

        let epsilon = 1e-9
        var moves: [CanvasMove] = []
        for item in items where !item.locked {
            guard let delta = deltas[item.id],
                  abs(delta.dx) >= epsilon || abs(delta.dy) >= epsilon else { continue }
            let after = CanvasPosition(x: item.position.x + delta.dx, y: item.position.y + delta.dy)
            guard after.x.isFinite, after.y.isFinite,
                  abs(after.x) <= 1_000_000, abs(after.y) <= 1_000_000 else {
                throw CanvasDocumentError("Node \(item.id) needs finite coordinates within 1000000.")
            }
            guard after != item.position else { continue }
            var node = nodes[item.nodeIndex]
            node["x"] = after.x
            node["y"] = after.y
            nodes[item.nodeIndex] = node
            moves.append(CanvasMove(id: item.id, before: item.position, after: after))
        }
        guard !moves.isEmpty else { return nil }
        var candidate = root
        candidate["nodes"] = nodes
        try CanvasDocument.validate(candidate)
        root = candidate
        return CanvasBatchMove(moves: moves)
    }

    public func applyBatchMove(_ batch: CanvasBatchMove) throws {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        guard !batch.moves.isEmpty else { return }
        guard var nodes = root["nodes"] as? [[String: Any]] else {
            throw CanvasDocumentError("Invalid canvas nodes array.")
        }
        var changed = false
        for move in batch.moves {
            guard move.after.x.isFinite, move.after.y.isFinite,
                  abs(move.after.x) <= 1_000_000, abs(move.after.y) <= 1_000_000 else {
                throw CanvasDocumentError("Node \(move.id) needs finite coordinates within 1000000.")
            }
            guard let index = nodes.firstIndex(where: { $0["id"] as? String == move.id }) else {
                throw CanvasDocumentError("Unknown node ID: \(move.id).")
            }
            guard !isLocked(move.id) else {
                throw CanvasDocumentError("Node \(move.id) is locked.")
            }
            if position(of: move.id) != move.after {
                var node = nodes[index]
                node["x"] = move.after.x
                node["y"] = move.after.y
                nodes[index] = node
                changed = true
            }
        }
        guard changed else { return }
        var candidate = root
        candidate["nodes"] = nodes
        try CanvasDocument.validate(candidate)
        root = candidate
    }
    public func geometry(of id: String) -> CanvasGeometry? {
        guard let raw = node(id), let data = raw["data"] as? [String: Any],
              let x = number(raw["x"]), let y = number(raw["y"]),
              let width = number(raw["width"]), let height = number(raw["height"]) else { return nil }
        return CanvasGeometry(x: x, y: y, width: width, height: height, rotation: number(data["rotation"]))
    }

    public func canTransform(_ id: String) -> Bool {
        guard !isReadOnly, let type = node(id)?["type"] as? String else { return false }
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
        var candidate = root
        candidate["nodes"] = nodes
        root = candidate
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
        !isReadOnly && node(id)?["type"] as? String == "shape-line" && !isLocked(id)
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
        var candidate = root
        candidate["nodes"] = nodes
        root = candidate
        return true
    }

    public func text(of id: String) -> String? {
        (node(id)?["data"] as? [String: Any])?["text"] as? String
    }

    public func attachment(of id: String) -> CanvasAttachment? {
        guard let raw = node(id),
              raw["type"] as? String == "shape",
              let data = raw["data"] as? [String: Any],
              let att = data["attachment"] as? [String: Any],
              let filename = att["filename"] as? String,
              let mediaType = att["media_type"] as? String,
              let encoding = att["encoding"] as? String,
              let content = att["content"] as? String else { return nil }
        return CanvasAttachment(
            filename: filename,
            mediaType: mediaType,
            encoding: encoding,
            content: content
        )
    }

    public func canEditText(_ id: String) -> Bool {
        !isReadOnly && node(id)?["type"] as? String == "shape" && !isLocked(id)
    }

    public var version: Int {
        intValue(root["version"]) ?? 1
    }

    public var supportsCodeNodes: Bool {
        version == 2
    }

    public func isCodeNode(_ id: String) -> Bool {
        node(id)?["type"] as? String == "code"
    }

    public func canEditCode(_ id: String) -> Bool {
        !isReadOnly && isCodeNode(id) && !isLocked(id)
    }

    public func codeContent(of id: String) -> String? {
        guard isCodeNode(id) else { return nil }
        return (node(id)?["data"] as? [String: Any])?["content"] as? String
    }

    /// Returns the raw stored `data.language` string, or `nil` when omitted (Auto).
    /// Never materializes `"auto"` on observation.
    public func codeLanguage(of id: String) -> String? {
        guard isCodeNode(id) else { return nil }
        return (node(id)?["data"] as? [String: Any])?["language"] as? String
    }

    /// Atomically updates code source, optional language (only when `updateLanguage` is true),
    /// and optional geometry (e.g. Fit to content) in one validated transaction.
    /// Preserves omitted/explicit language on source-only edits and retains all unknown metadata.
    @discardableResult
    public func setCodeSourceAndGeometry(
        _ id: String,
        content: String,
        language: String? = nil,
        updateLanguage: Bool = false,
        geometry: CanvasGeometry? = nil
    ) throws -> CanvasTextChange? {
        guard canEditCode(id),
              var nodes = root["nodes"] as? [[String: Any]],
              let index = nodes.firstIndex(where: { $0["id"] as? String == id }),
              var data = nodes[index]["data"] as? [String: Any] else {
            throw CanvasDocumentError("Select an unlocked code block to edit its source.")
        }
        try CanvasCodeSnippet.validateSource(content)
        if updateLanguage {
            guard let language, !language.isEmpty else {
                throw CanvasDocumentError("Code language must be a nonempty string.")
            }
        }
        if let geometry {
            try geometry.validate()
        }
        let existingContent = data["content"] as? String
        let existingLanguage = data["language"] as? String
        let contentChanged = existingContent != content
        let languageChanged = updateLanguage && existingLanguage != language
        let geometryChanged = geometry != nil && self.geometry(of: id) != geometry
        guard contentChanged || languageChanged || geometryChanged else { return nil }

        let beforeNode = nodes[index]
        var afterNode = beforeNode
        data["content"] = content
        if updateLanguage, let language {
            data["language"] = language
        }
        if let geometry {
            afterNode["x"] = geometry.x
            afterNode["y"] = geometry.y
            afterNode["width"] = geometry.width
            afterNode["height"] = geometry.height
            data["rotation"] = geometry.rotation
        }
        afterNode["data"] = data
        nodes[index] = afterNode
        var candidate = root
        candidate["nodes"] = nodes
        try CanvasDocument.validate(candidate)
        root = candidate
        return CanvasTextChange(id: id, beforeNode: beforeNode, afterNode: afterNode)
    }

    /// Convenience helper for language-only edits on an unlocked code block.
    @discardableResult
    public func setCodeLanguage(_ id: String, to language: String) throws -> CanvasTextChange? {
        guard let currentContent = codeContent(of: id) else {
            throw CanvasDocumentError("Select an unlocked code block to change its language.")
        }
        return try setCodeSourceAndGeometry(
            id,
            content: currentContent,
            language: language,
            updateLanguage: true,
            geometry: nil
        )
    }

    /// Inserts a new v2 `type: "code"` node at `position`.
    /// Refuses read-only documents and version-1 canvases without silently upgrading.
    public func insertCodeBlock(
        at position: CanvasPosition,
        content: String = "",
        language: String = "auto",
        width: Double = CanvasCodeSnippet.defaultWidth,
        height: Double = CanvasCodeSnippet.defaultHeight
    ) throws -> CanvasShapeInsertion {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        guard supportsCodeNodes else {
            throw CanvasDocumentError("Code blocks require a version-2 canvas. Use File → Save Version 2 Copy… or New Canvas.")
        }
        guard position.x.isFinite, position.y.isFinite,
              abs(position.x) <= 1_000_000, abs(position.y) <= 1_000_000 else {
            throw CanvasDocumentError("A code block needs finite coordinates within 1000000.")
        }
        guard width.isFinite, width > 0, width <= 1_000_000,
              height.isFinite, height > 0, height <= 1_000_000 else {
            throw CanvasDocumentError("A code block needs positive dimensions within 1000000.")
        }
        guard !language.isEmpty else {
            throw CanvasDocumentError("Code language must be a nonempty string.")
        }
        try CanvasCodeSnippet.validateSource(content)
        let id = UUID().uuidString
        let data: [String: Any] = [
            "content": content,
            "language": language,
            "fill": "none",
            "stroke": "ink",
            "width": 2,
            "radius": 0,
            "size": "m",
        ]
        let raw: [String: Any] = [
            "id": id,
            "type": "code",
            "x": position.x,
            "y": position.y,
            "width": width,
            "height": height,
            "data": data,
        ]
        let insertion = CanvasShapeInsertion(
            id: id, node: raw, index: (root["nodes"] as? [[String: Any]])?.count ?? 0
        )
        try restoreInsertion(insertion)
        return insertion
    }

    /// Changes only the caption; nil restores an originally absent text field.
    @discardableResult
    public func setText(_ id: String, to text: String?) throws -> Bool {
        try setTextAndGeometry(id, to: text, geometry: nil) != nil
    }

    /// Atomically updates caption text and optional grown geometry in one transaction.
    @discardableResult
    public func setTextAndGeometry(
        _ id: String, to text: String?, geometry: CanvasGeometry? = nil
    ) throws -> CanvasTextChange? {
        guard canEditText(id),
              var nodes = root["nodes"] as? [[String: Any]],
              let index = nodes.firstIndex(where: { $0["id"] as? String == id }),
              var data = nodes[index]["data"] as? [String: Any] else {
            throw CanvasDocumentError("Select an unlocked shape to edit its text.")
        }
        if let text, text.count > 2_000 {
            throw CanvasDocumentError("Text must contain at most 2000 characters.")
        }
        if let geometry {
            try geometry.validate()
        }
        let textChanged = self.text(of: id) != text
        let geometryChanged = geometry != nil && self.geometry(of: id) != geometry
        guard textChanged || geometryChanged else { return nil }
        let beforeNode = nodes[index]
        var afterNode = beforeNode
        data["text"] = text
        if let geometry {
            afterNode["x"] = geometry.x
            afterNode["y"] = geometry.y
            afterNode["width"] = geometry.width
            afterNode["height"] = geometry.height
            data["rotation"] = geometry.rotation
        }
        afterNode["data"] = data
        nodes[index] = afterNode
        var candidate = root
        candidate["nodes"] = nodes
        try CanvasDocument.validate(candidate)
        root = candidate
        return CanvasTextChange(id: id, beforeNode: beforeNode, afterNode: afterNode)
    }

    public func applyTextChange(_ change: CanvasTextChange) throws {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        guard var nodes = root["nodes"] as? [[String: Any]],
              let index = nodes.firstIndex(where: { $0["id"] as? String == change.id }),
              !isLocked(change.id) else {
            throw CanvasDocumentError("Cannot apply text change to missing or locked shape.")
        }
        nodes[index] = change.afterNode
        var candidate = root
        candidate["nodes"] = nodes
        try CanvasDocument.validate(candidate)
        root = candidate
    }

    public func insertShape(
        _ kind: CanvasShapeKind,
        at position: CanvasPosition,
        text: String? = nil,
        width: Double = 160,
        height: Double? = nil
    ) throws -> CanvasShapeInsertion {
        guard position.x.isFinite, position.y.isFinite,
              abs(position.x) <= 1_000_000, abs(position.y) <= 1_000_000 else {
            throw CanvasDocumentError("A shape needs finite coordinates within 1000000.")
        }
        if let text, text.count > 2_000 {
            throw CanvasDocumentError("Text must contain at most 2000 characters.")
        }
        let defaultHeight: Double = kind == .text ? 48 : 96
        let resolvedHeight = height ?? defaultHeight
        guard width.isFinite, width > 0, width <= 1_000_000,
              resolvedHeight.isFinite, resolvedHeight > 0, resolvedHeight <= 1_000_000 else {
            throw CanvasDocumentError("A shape needs positive dimensions within 1000000.")
        }
        let id = UUID().uuidString
        var data: [String: Any] = [
            "kind": kind.rawValue, "fill": "none",
            "stroke": kind == .text ? "none" : "ink", "radius": 0
        ]
        data["text"] = text
        let raw: [String: Any] = [
            "id": id, "type": "shape", "x": position.x, "y": position.y,
            "width": width, "height": resolvedHeight,
            "data": data
        ]
        let insertion = CanvasShapeInsertion(
            id: id, node: raw, index: (root["nodes"] as? [[String: Any]])?.count ?? 0
        )
        try restoreInsertion(insertion)
        return insertion
    }

    public func canInsertAdjacentThought(from id: String) -> Bool {
        !isReadOnly && node(id)?["type"] as? String == "shape" && !isLocked(id)
    }

    public func adjacentThoughtGeometry(
        from sourceID: String, direction: CanvasThoughtDirection, height: Double = 96
    ) throws -> CanvasGeometry {
        guard canInsertAdjacentThought(from: sourceID),
              let sourceGeometry = geometry(of: sourceID) else {
            throw CanvasDocumentError("Select an unlocked shape to grow an adjacent thought.")
        }
        let rawNodes = root["nodes"] as? [[String: Any]] ?? []
        let obstacles: [CanvasGeometry] = rawNodes.compactMap { raw in
            guard let id = raw["id"] as? String, id != sourceID else { return nil }
            return geometry(of: id)
        }
        let box = CanvasGeometry.adjacentThoughtBox(
            source: sourceGeometry,
            obstacles: obstacles,
            direction: direction,
            height: max(96, height)
        )
        try box.validate()
        return box
    }

    public func insertAdjacentThought(
        from sourceID: String,
        direction: CanvasThoughtDirection,
        text: String,
        height: Double = 96
    ) throws -> CanvasShapeInsertion {
        if text.count > 2_000 {
            throw CanvasDocumentError("Text must contain at most 2000 characters.")
        }
        let box = try adjacentThoughtGeometry(from: sourceID, direction: direction, height: max(96, height))
        return try insertShape(
            .rectangle,
            at: CanvasPosition(x: box.x, y: box.y),
            text: text,
            height: box.height
        )
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
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
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
        var candidate = root
        candidate["nodes"] = nodes
        root = candidate
    }

    public func restoreInsertion(_ insertion: CanvasShapeInsertion) throws {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
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
        !isReadOnly && node(id) != nil && !isLocked(id)
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
        !isReadOnly && node(id) != nil && !isLocked(id)
    }

    @discardableResult
    public func deleteNode(_ id: String) throws -> CanvasNodeDeletion {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
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
        var candidate = root
        candidate["nodes"] = nodes
        candidate["edges"] = remainingEdges
        root = candidate
        return CanvasNodeDeletion(id: id, node: removedNode, index: index, edges: removedEdges)
    }

    public func restoreNodeDeletion(_ deletion: CanvasNodeDeletion) throws {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
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

    public func copyNodes(_ ids: [String]) throws -> CanvasClipboardPayload {
        let idSet = Set(ids)
        let allNodes = root["nodes"] as? [[String: Any]] ?? []
        let selectedNodes = allNodes.filter { raw in
            guard let id = raw["id"] as? String else { return false }
            return idSet.contains(id)
        }
        guard !selectedNodes.isEmpty else {
            throw CanvasDocumentError("Select at least one canvas object to copy.")
        }
        var copiedIDSet = Set<String>()
        var copiedNodes: [[String: Any]] = []
        for sourceNode in selectedNodes {
            guard let id = sourceNode["id"] as? String else { continue }
            copiedIDSet.insert(id)
            var copy: [String: Any] = [
                "id": id,
                "type": sourceNode["type"] as Any,
                "x": sourceNode["x"] as Any,
                "y": sourceNode["y"] as Any,
                "width": sourceNode["width"] as Any,
                "height": sourceNode["height"] as Any,
                "data": sourceNode["data"] as Any
            ]
            if let parent = sourceNode["parent"] {
                copy["parent"] = parent
            }
            copiedNodes.append(copy)
        }
        let allEdges = root["edges"] as? [[String: Any]] ?? []
        var copiedEdges: [[String: Any]] = []
        for edge in allEdges {
            guard let source = edge["source"] as? String,
                  let target = edge["target"] as? String,
                  copiedIDSet.contains(source),
                  copiedIDSet.contains(target) else { continue }
            var copiedEdge: [String: Any] = [
                "id": edge["id"] as Any,
                "source": source,
                "target": target,
                "path": edge["path"] as? String ?? "bezier",
                "marker": edge["marker"] as? String ?? "arrow"
            ]
            if let sh = edge["source_handle"] { copiedEdge["source_handle"] = sh }
            if let th = edge["target_handle"] { copiedEdge["target_handle"] = th }
            if let label = edge["label"] { copiedEdge["label"] = label }
            if let animated = edge["animated"] { copiedEdge["animated"] = animated }
            if let data = edge["data"] { copiedEdge["data"] = data }
            copiedEdges.append(copiedEdge)
        }
        return CanvasClipboardPayload(nodes: copiedNodes, edges: copiedEdges)
    }

    @discardableResult
    public func paste(
        _ payload: CanvasClipboardPayload,
        offset: CanvasPosition? = nil
    ) throws -> CanvasBatchInsertion {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        guard !payload.nodes.isEmpty else {
            throw CanvasDocumentError("Clipboard does not contain valid canvas objects.")
        }
        let existingNodes = root["nodes"] as? [[String: Any]] ?? []
        let existingEdges = root["edges"] as? [[String: Any]] ?? []
        let resolvedOffset: CanvasPosition
        if let offset {
            resolvedOffset = offset
        } else if let firstX = number(payload.nodes[0]["x"]),
                  let firstY = number(payload.nodes[0]["y"]) {
            var step = 1
            while step < 64 {
                let candidateX = firstX + Double(step) * 24.0
                let candidateY = firstY + Double(step) * 24.0
                let collides = existingNodes.contains { raw in
                    guard let nx = number(raw["x"]), let ny = number(raw["y"]) else { return false }
                    return abs(nx - candidateX) < 0.001 && abs(ny - candidateY) < 0.001
                }
                if !collides { break }
                step += 1
            }
            resolvedOffset = CanvasPosition(x: Double(step) * 24.0, y: Double(step) * 24.0)
        } else {
            resolvedOffset = CanvasPosition(x: 24, y: 24)
        }
        let existingNodeIDSet = Set(existingNodes.compactMap { $0["id"] as? String })
        var idMap: [String: String] = [:]
        var newNodeIDs: [String] = []
        var indexedNodes: [(index: Int, node: [String: Any])] = []
        for (offsetIndex, sourceNode) in payload.nodes.enumerated() {
            guard let oldID = sourceNode["id"] as? String,
                  let x = number(sourceNode["x"]),
                  let y = number(sourceNode["y"]) else {
                throw CanvasDocumentError("Copied object has invalid coordinates.")
            }
            let newID = UUID().uuidString
            idMap[oldID] = newID
            newNodeIDs.append(newID)
            var copy: [String: Any] = [
                "id": newID,
                "type": sourceNode["type"] as Any,
                "x": x + resolvedOffset.x,
                "y": y + resolvedOffset.y,
                "width": sourceNode["width"] as Any,
                "height": sourceNode["height"] as Any,
                "data": sourceNode["data"] as Any
            ]
            if let oldParent = sourceNode["parent"] as? String {
                if let mappedParent = idMap[oldParent] {
                    copy["parent"] = mappedParent
                } else if existingNodeIDSet.contains(oldParent) {
                    copy["parent"] = oldParent
                }
            }
            indexedNodes.append((index: existingNodes.count + offsetIndex, node: copy))
        }
        var newEdgeIDs: [String] = []
        var indexedEdges: [(index: Int, edge: [String: Any])] = []
        for (offsetIndex, sourceEdge) in payload.edges.enumerated() {
            guard let oldSource = sourceEdge["source"] as? String,
                  let oldTarget = sourceEdge["target"] as? String,
                  let mappedSource = idMap[oldSource],
                  let mappedTarget = idMap[oldTarget] else { continue }
            let newEdgeID = UUID().uuidString
            newEdgeIDs.append(newEdgeID)
            var copyEdge: [String: Any] = [
                "id": newEdgeID,
                "source": mappedSource,
                "target": mappedTarget,
                "path": sourceEdge["path"] as? String ?? "bezier",
                "marker": sourceEdge["marker"] as? String ?? "arrow"
            ]
            if let sh = sourceEdge["source_handle"] { copyEdge["source_handle"] = sh }
            if let th = sourceEdge["target_handle"] { copyEdge["target_handle"] = th }
            if let label = sourceEdge["label"] { copyEdge["label"] = label }
            if let animated = sourceEdge["animated"] { copyEdge["animated"] = animated }
            if let data = sourceEdge["data"] { copyEdge["data"] = data }
            indexedEdges.append((index: existingEdges.count + offsetIndex, edge: copyEdge))
        }
        let insertion = CanvasBatchInsertion(
            nodeIDs: newNodeIDs,
            edgeIDs: newEdgeIDs,
            nodes: indexedNodes,
            edges: indexedEdges
        )
        try restoreBatchInsertion(insertion)
        return insertion
    }

    @discardableResult
    public func duplicateNodes(
        _ ids: [String],
        offset: CanvasPosition = CanvasPosition(x: 24, y: 24)
    ) throws -> CanvasBatchInsertion {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        let unlocked = ids.filter { canDuplicateNode($0) }
        guard !unlocked.isEmpty else {
            throw CanvasDocumentError("Select at least one unlocked object to duplicate.")
        }
        let payload = try copyNodes(unlocked)
        return try paste(payload, offset: offset)
    }

    public func restoreBatchInsertion(_ insertion: CanvasBatchInsertion) throws {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        guard var nodes = root["nodes"] as? [[String: Any]] else {
            throw CanvasDocumentError("Invalid canvas nodes array.")
        }
        for item in insertion.nodes {
            guard item.index <= nodes.count,
                  let id = item.node["id"] as? String,
                  !nodes.contains(where: { $0["id"] as? String == id }) else {
                throw CanvasDocumentError("Cannot restore pasted object at its original position.")
            }
            nodes.insert(item.node, at: item.index)
        }
        var edges = root["edges"] as? [[String: Any]] ?? []
        for item in insertion.edges {
            guard item.index <= edges.count,
                  let id = item.edge["id"] as? String,
                  !edges.contains(where: { $0["id"] as? String == id }) else {
                throw CanvasDocumentError("Cannot restore pasted connection at its original position.")
            }
            edges.insert(item.edge, at: item.index)
        }
        var candidate = root
        candidate["nodes"] = nodes
        if !edges.isEmpty || root["edges"] != nil {
            candidate["edges"] = edges
        }
        try CanvasDocument.validate(candidate)
        root = candidate
    }

    public func removeBatchInsertion(_ insertion: CanvasBatchInsertion) throws {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        guard var nodes = root["nodes"] as? [[String: Any]] else {
            throw CanvasDocumentError("Invalid canvas nodes array.")
        }
        let removeNodeIDs = Set(insertion.nodeIDs)
        let removeEdgeIDs = Set(insertion.edgeIDs)
        nodes.removeAll { raw in
            guard let id = raw["id"] as? String else { return false }
            return removeNodeIDs.contains(id)
        }
        var edges = root["edges"] as? [[String: Any]] ?? []
        edges.removeAll { raw in
            let id = raw["id"] as? String ?? ""
            let src = raw["source"] as? String ?? ""
            let dst = raw["target"] as? String ?? ""
            return removeEdgeIDs.contains(id) || removeNodeIDs.contains(src) || removeNodeIDs.contains(dst)
        }
        var candidate = root
        candidate["nodes"] = nodes
        if root["edges"] != nil || !edges.isEmpty {
            candidate["edges"] = edges
        }
        root = candidate
    }

    @discardableResult
    public func deleteNodes(_ ids: [String]) throws -> CanvasBatchDeletion {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        guard let currentNodes = root["nodes"] as? [[String: Any]] else {
            throw CanvasDocumentError("Invalid canvas nodes array.")
        }
        let requestedSet = Set(ids)
        var removedIDSet = Set<String>()
        var removedNodes: [(index: Int, node: [String: Any])] = []
        var remainingNodes: [[String: Any]] = []
        for (index, node) in currentNodes.enumerated() {
            if let id = node["id"] as? String, requestedSet.contains(id), !isLocked(id) {
                removedIDSet.insert(id)
                removedNodes.append((index: index, node: node))
            } else {
                remainingNodes.append(node)
            }
        }
        guard !removedNodes.isEmpty else {
            throw CanvasDocumentError("Select at least one unlocked object to delete.")
        }
        let currentEdges = root["edges"] as? [[String: Any]] ?? []
        var removedEdges: [(index: Int, edge: [String: Any])] = []
        var remainingEdges: [[String: Any]] = []
        for (edgeIndex, edge) in currentEdges.enumerated() {
            let source = edge["source"] as? String ?? ""
            let target = edge["target"] as? String ?? ""
            if removedIDSet.contains(source) || removedIDSet.contains(target) {
                removedEdges.append((index: edgeIndex, edge: edge))
            } else {
                remainingEdges.append(edge)
            }
        }
        var candidate = root
        candidate["nodes"] = remainingNodes
        if root["edges"] != nil || !remainingEdges.isEmpty {
            candidate["edges"] = remainingEdges
        }
        root = candidate
        return CanvasBatchDeletion(
            ids: removedNodes.compactMap { $0.node["id"] as? String },
            nodes: removedNodes,
            edges: removedEdges
        )
    }

    public func restoreBatchDeletion(_ deletion: CanvasBatchDeletion) throws {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        guard var nodes = root["nodes"] as? [[String: Any]] else {
            throw CanvasDocumentError("Invalid canvas nodes array.")
        }
        for item in deletion.nodes {
            guard item.index <= nodes.count,
                  let id = item.node["id"] as? String,
                  !nodes.contains(where: { $0["id"] as? String == id }) else {
                throw CanvasDocumentError("Cannot restore the deleted object at its original position.")
            }
            nodes.insert(item.node, at: item.index)
        }
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
        if root["edges"] != nil || !edges.isEmpty {
            candidate["edges"] = edges
        }
        try CanvasDocument.validate(candidate)
        root = candidate
    }

    @discardableResult
    public func bringToFront(_ ids: [String]) throws -> CanvasBatchStackMove? {
        try reorderNodes(ids, toFront: true)
    }

    @discardableResult
    public func sendToBack(_ ids: [String]) throws -> CanvasBatchStackMove? {
        try reorderNodes(ids, toFront: false)
    }

    private func reorderNodes(_ ids: [String], toFront: Bool) throws -> CanvasBatchStackMove? {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        guard let currentNodes = root["nodes"] as? [[String: Any]] else { return nil }
        let idSet = Set(ids)
        var chosen: [[String: Any]] = []
        var chosenIDs: [String] = []
        var other: [[String: Any]] = []
        for node in currentNodes {
            if let id = node["id"] as? String, idSet.contains(id), !isLocked(id) {
                chosen.append(node)
                chosenIDs.append(id)
            } else {
                other.append(node)
            }
        }
        guard !chosen.isEmpty else { return nil }
        let reordered = toFront ? (other + chosen) : (chosen + other)
        let beforeOrder = currentNodes.compactMap { $0["id"] as? String }
        let afterOrder = reordered.compactMap { $0["id"] as? String }
        guard beforeOrder != afterOrder else { return nil }
        var candidate = root
        candidate["nodes"] = reordered
        root = candidate
        return CanvasBatchStackMove(ids: chosenIDs, beforeNodes: currentNodes, afterNodes: reordered)
    }

    public func applyBatchStackMove(_ move: CanvasBatchStackMove) throws {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        var candidate = root
        candidate["nodes"] = move.afterNodes
        try CanvasDocument.validate(candidate)
        root = candidate
    }

    public func nodeIndex(of id: String) -> Int? {
        (root["nodes"] as? [[String: Any]])?.firstIndex { $0["id"] as? String == id }
    }

    public func canBringToFront(_ id: String) -> Bool {
        guard !isReadOnly,
              let nodes = root["nodes"] as? [[String: Any]],
              let index = nodeIndex(of: id), !isLocked(id) else { return false }
        return index < nodes.count - 1
    }

    public func canSendToBack(_ id: String) -> Bool {
        guard !isReadOnly,
              let index = nodeIndex(of: id), !isLocked(id) else { return false }
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
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
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
        var candidate = root
        candidate["nodes"] = nodes
        root = candidate
        return CanvasStackMove(id: id, fromIndex: fromIndex, toIndex: targetIndex)
    }
    public func insertConnection(
        source: String, sourceSide: CanvasConnectionSide? = nil,
        target: String, targetSide: CanvasConnectionSide? = nil,
        label: String? = nil
    ) throws -> CanvasConnectionInsertion {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        try validateConnection(source: source, sourceSide: sourceSide, target: target, targetSide: targetSide)
        let normalizedLabel = (label?.isEmpty == false) ? label : nil
        let id = UUID().uuidString
        var edge: [String: Any] = [
            "id": id, "source": source, "target": target, "path": "bezier", "marker": "arrow"
        ]
        edge["source_handle"] = sourceSide?.rawValue
        edge["target_handle"] = targetSide?.rawValue
        edge["label"] = normalizedLabel
        var edges = root["edges"] as? [[String: Any]] ?? []
        let insertion = CanvasConnectionInsertion(
            id: id, edge: edge, index: edges.count
        )
        edges.append(edge)
        var candidate = root
        candidate["edges"] = edges
        root = candidate
        return insertion
    }

    public func connectionState(of id: String) -> CanvasConnectionState? {
        guard let raw = edge(id),
              let source = raw["source"] as? String,
              let target = raw["target"] as? String else { return nil }
        let sourceSide = (raw["source_handle"] as? String).flatMap(CanvasConnectionSide.init(rawValue:))
        let targetSide = (raw["target_handle"] as? String).flatMap(CanvasConnectionSide.init(rawValue:))
        let label = raw["label"] as? String
        return CanvasConnectionState(
            id: id,
            source: source,
            sourceSide: sourceSide,
            target: target,
            targetSide: targetSide,
            label: label
        )
    }

    @discardableResult
    public func updateConnection(
        _ id: String,
        source: String,
        sourceSide: CanvasConnectionSide? = nil,
        target: String,
        targetSide: CanvasConnectionSide? = nil,
        label: String? = nil
    ) throws -> CanvasConnectionUpdate? {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        guard var edges = root["edges"] as? [[String: Any]],
              let index = edges.firstIndex(where: { $0["id"] as? String == id }),
              let current = connectionState(of: id) else {
            throw CanvasDocumentError("Unknown connection ID: \(id).")
        }
        try validateConnection(source: source, sourceSide: sourceSide, target: target, targetSide: targetSide)
        let normalizedLabel = (label?.isEmpty == false) ? label : nil
        let currentEffectiveLabel = (current.label?.isEmpty == false) ? current.label : nil
        guard current.source != source ||
              current.sourceSide != sourceSide ||
              current.target != target ||
              current.targetSide != targetSide ||
              currentEffectiveLabel != normalizedLabel else {
            return nil
        }
        let beforeEdge = edges[index]
        var afterEdge = beforeEdge
        afterEdge["source"] = source
        if current.sourceSide != sourceSide {
            if let sourceSide {
                afterEdge["source_handle"] = sourceSide.rawValue
            } else {
                afterEdge.removeValue(forKey: "source_handle")
            }
        }
        afterEdge["target"] = target
        if current.targetSide != targetSide {
            if let targetSide {
                afterEdge["target_handle"] = targetSide.rawValue
            } else {
                afterEdge.removeValue(forKey: "target_handle")
            }
        }
        if currentEffectiveLabel != normalizedLabel {
            if let normalizedLabel {
                afterEdge["label"] = normalizedLabel
            } else {
                afterEdge.removeValue(forKey: "label")
            }
        }
        edges[index] = afterEdge
        var candidate = root
        candidate["edges"] = edges
        try CanvasDocument.validate(candidate)
        root = candidate
        return CanvasConnectionUpdate(id: id, beforeEdge: beforeEdge, afterEdge: afterEdge)
    }

    public func applyConnectionUpdate(_ update: CanvasConnectionUpdate) throws {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        guard var edges = root["edges"] as? [[String: Any]],
              let index = edges.firstIndex(where: { $0["id"] as? String == update.id }) else {
            throw CanvasDocumentError("Cannot apply connection update to missing connection.")
        }
        edges[index] = update.afterEdge
        var candidate = root
        candidate["edges"] = edges
        try CanvasDocument.validate(candidate)
        root = candidate
    }

    public func removeInsertion(_ insertion: CanvasConnectionInsertion) throws {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        guard var edges = root["edges"] as? [[String: Any]],
              let index = edges.firstIndex(where: { $0["id"] as? String == insertion.id }) else {
            throw CanvasDocumentError("The inserted connection is missing.")
        }
        edges.remove(at: index)
        var candidate = root
        candidate["edges"] = edges
        root = candidate
    }

    public func hasConnection(_ id: String) -> Bool {
        (root["edges"] as? [[String: Any]])?.contains { $0["id"] as? String == id } == true
    }

    @discardableResult
    public func deleteConnection(_ id: String) throws -> CanvasConnectionInsertion {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        guard var edges = root["edges"] as? [[String: Any]],
              let index = edges.firstIndex(where: { $0["id"] as? String == id }) else {
            throw CanvasDocumentError("Unknown connection ID: \(id).")
        }
        let removed = edges.remove(at: index)
        var candidate = root
        candidate["edges"] = edges
        root = candidate
        return CanvasConnectionInsertion(id: id, edge: removed, index: index)
    }

    public func restoreInsertion(_ insertion: CanvasConnectionInsertion) throws {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
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
        var candidate = root
        candidate["edges"] = edges
        root = candidate
    }

    public static let supportedPaperBackgrounds = ["dots", "lines", "cross", "none"]
    public static let defaultPaperGridPresets = [10, 16, 20, 24, 32, 40]
    public static let supportedColors = ["none", "ink", "gray", "blue", "green", "yellow", "red", "violet", "accent", "surface"]
    public static let supportedFonts = ["sans", "heading", "mono", "handwritten"]
    public static let supportedWidths = [1, 2, 4]
    public static let supportedRadii = [0, 8]
    public static let supportedArrows = ["end", "both", "none"]
    public static let supportedPaths = ["bezier", "smooth", "step", "straight"]
    public static let supportedMarkers = ["arrow", "dot", "none"]
    public static let supportedSizes = ["s", "m", "l"]
    public static let supportedAlignments = ["left", "center", "right"]

    public func availableDocumentStyleProperties() -> [CanvasStyleProperty] {
        [.paperBackground, .paperGrid, .font, .align]
    }

    public func effectiveDocumentStyle() -> [CanvasStyleProperty: CanvasStyleValue] {
        let paper = root["paper"] as? [String: Any]
        let appearance = root["appearance"] as? [String: Any]
        let background = paper?["background"] as? String ?? "dots"
        let grid = intValue(paper?["grid"]) ?? 20
        let font = appearance?["font"] as? String ?? "sans"
        let align = appearance?["align"] as? String ?? "center"
        return [
            .paperBackground: .string(background),
            .paperGrid: .int(grid),
            .font: .string(font),
            .align: .string(align)
        ]
    }

    @discardableResult
    public func setDocumentStyle(
        property: CanvasStyleProperty, to value: CanvasStyleValue
    ) throws -> CanvasStyleChange? {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        guard availableDocumentStyleProperties().contains(property) else {
            throw CanvasDocumentError("This style is not supported for the canvas; nothing was changed.")
        }
        let rawValue = try validatedStyleJSONValue(property: property, value: value)
        guard effectiveDocumentStyle()[property] != value else { return nil }
        var candidate = root
        let topKey: String
        let beforeValue: Any?
        let afterValue: Any?
        switch property {
        case .paperBackground, .paperGrid:
            topKey = "paper"
            beforeValue = root[topKey]
            if let existing = candidate[topKey], !(existing is NSNull), !(existing is [String: Any]) {
                throw CanvasDocumentError("Paper must be an object.")
            }
            var paper = (candidate[topKey] as? [String: Any]) ?? [:]
            paper[property.rawValue] = rawValue
            candidate[topKey] = paper
            afterValue = paper
        case .font, .align:
            topKey = "appearance"
            beforeValue = root[topKey]
            if let existing = candidate[topKey], !(existing is [String: Any]) {
                throw CanvasDocumentError("Appearance must be an object.")
            }
            var appearance = (candidate[topKey] as? [String: Any]) ?? [:]
            appearance[property.rawValue] = rawValue
            candidate[topKey] = appearance
            afterValue = appearance
        default:
            throw CanvasDocumentError("Invalid document style property.")
        }
        try CanvasDocument.validate(candidate)
        root = candidate
        return CanvasStyleChange(target: .document(key: topKey, beforeValue: beforeValue, afterValue: afterValue))
    }
    public func availableStyleProperties(forNode id: String) -> [CanvasStyleProperty] {
        guard let raw = node(id), let type = raw["type"] as? String,
              let data = raw["data"] as? [String: Any] else { return [] }
        switch type {
        case "shape":
            let kind = data["kind"] as? String ?? "rect"
            if kind == "text" { return [.fill, .font, .size, .align] }
            if kind == "rect" { return [.fill, .stroke, .width, .dash, .radius, .font, .size, .align] }
            return [.fill, .stroke, .width, .dash, .font, .size, .align]
        case "shape-line":
            return [.stroke, .width, .dash, .arrow]
        case "code":
            return [.fill, .stroke, .width, .dash, .radius, .size]
        default:
            return []
        }
    }

    public func availableStyleProperties(forConnection id: String) -> [CanvasStyleProperty] {
        hasConnection(id) ? [.stroke, .width, .dash, .path, .marker] : []
    }

    public func effectiveNodeStyle(of id: String) -> [CanvasStyleProperty: CanvasStyleValue]? {
        guard let raw = node(id), let type = raw["type"] as? String,
              let data = raw["data"] as? [String: Any] else { return nil }
        let appearance = root["appearance"] as? [String: Any]
        let docFont = appearance?["font"] as? String ?? "sans"
        let docAlign = appearance?["align"] as? String
        switch type {
        case "shape":
            let kind = data["kind"] as? String ?? "rect"
            if kind == "text" {
                return [
                    .fill: .string(data["fill"] as? String ?? "none"),
                    .font: .string(data["font"] as? String ?? docFont),
                    .size: .string(data["size"] as? String ?? "m"),
                    .align: .string(data["align"] as? String ?? docAlign ?? "left")
                ]
            }
            var values: [CanvasStyleProperty: CanvasStyleValue] = [
                .fill: .string(data["fill"] as? String ?? "blue"),
                .stroke: .string(data["stroke"] as? String ?? "blue"),
                .width: .int(intValue(data["width"]) ?? 2),
                .dash: .bool(boolValue(data["dash"]) ?? false),
                .font: .string(data["font"] as? String ?? docFont),
                .size: .string(data["size"] as? String ?? "m"),
                .align: .string(data["align"] as? String ?? docAlign ?? "center")
            ]
            if kind == "rect" {
                values[.radius] = .int(intValue(data["radius"]) ?? 8)
            }
            return values
        case "shape-line":
            return [
                .stroke: .string(data["stroke"] as? String ?? "ink"),
                .width: .int(intValue(data["width"]) ?? 2),
                .dash: .bool(boolValue(data["dash"]) ?? false),
                .arrow: .string(data["arrow"] as? String ?? "end")
            ]
        case "code":
            return [
                .fill: .string(data["fill"] as? String ?? "none"),
                .stroke: .string(data["stroke"] as? String ?? "ink"),
                .width: .int(intValue(data["width"]) ?? 2),
                .dash: .bool(boolValue(data["dash"]) ?? false),
                .radius: .int(intValue(data["radius"]) ?? 0),
                .size: .string(data["size"] as? String ?? "m")
            ]
        default:
            return nil
        }
    }

    public func effectiveConnectionStyle(of id: String) -> [CanvasStyleProperty: CanvasStyleValue]? {
        guard let raw = edge(id) else { return nil }
        let data = raw["data"] as? [String: Any] ?? [:]
        let style = data["connector_style"] as? [String: Any] ?? [:]
        let stroke: CanvasStyleValue
        if let s = style["stroke"] as? String, Self.supportedColors.contains(s) {
            stroke = .string(s)
        } else {
            stroke = .omitted
        }
        let width: Int
        if let w = intValue(style["width"]), Self.supportedWidths.contains(w) {
            width = w
        } else {
            width = 2
        }
        let dash = boolValue(style["dash"]) ?? (boolValue(raw["animated"]) ?? false)
        return [
            .stroke: stroke,
            .width: .int(width),
            .dash: .bool(dash),
            .path: .string(raw["path"] as? String ?? "bezier"),
            .marker: .string(raw["marker"] as? String ?? "arrow")
        ]
    }

    @discardableResult
    public func setNodeStyle(
        _ id: String, property: CanvasStyleProperty, to value: CanvasStyleValue
    ) throws -> CanvasStyleChange? {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        guard let raw = node(id),
              var nodes = root["nodes"] as? [[String: Any]],
              let index = nodes.firstIndex(where: { $0["id"] as? String == id }),
              let beforeData = raw["data"] as? [String: Any] else {
            throw CanvasDocumentError("Unknown node ID: \(id).")
        }
        guard !isLocked(id) else {
            throw CanvasDocumentError("Unlock the selected object before changing styles.")
        }
        let allowed = availableStyleProperties(forNode: id)
        guard allowed.contains(property) else {
            throw CanvasDocumentError("This style is not supported for the selected object; nothing was changed.")
        }
        let rawValue = try validatedStyleJSONValue(property: property, value: value)
        guard effectiveNodeStyle(of: id)?[property] != value else { return nil }
        var afterData = beforeData
        afterData[property.rawValue] = rawValue
        nodes[index]["data"] = afterData
        var candidate = root
        candidate["nodes"] = nodes
        try CanvasDocument.validate(candidate)
        root = candidate
        return CanvasStyleChange(target: .node(id: id, beforeData: beforeData, afterData: afterData))
    }

    @discardableResult
    public func setConnectionStyle(
        _ id: String, property: CanvasStyleProperty, to value: CanvasStyleValue
    ) throws -> CanvasStyleChange? {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        guard var edges = root["edges"] as? [[String: Any]],
              let index = edges.firstIndex(where: { $0["id"] as? String == id }) else {
            throw CanvasDocumentError("Unknown connection ID: \(id).")
        }
        guard [.stroke, .width, .dash, .path, .marker].contains(property) else {
            throw CanvasDocumentError("Invalid connector style command.")
        }
        let rawValue = try validatedStyleJSONValue(property: property, value: value)
        let beforeEdge = edges[index]
        let beforeData = beforeEdge["data"] as? [String: Any]
        if [.stroke, .width, .dash].contains(property),
           let existingStyle = beforeData?["connector_style"], !(existingStyle is [String: Any]) {
            throw CanvasDocumentError("Connector style conflicts with existing metadata; nothing was changed.")
        }
        guard effectiveConnectionStyle(of: id)?[property] != value else { return nil }
        var afterEdge = beforeEdge
        if property == .path || property == .marker {
            afterEdge[property.rawValue] = rawValue
        } else {
            var afterData = beforeData ?? [:]
            var style = afterData["connector_style"] as? [String: Any] ?? [:]
            style[property.rawValue] = rawValue
            afterData["connector_style"] = style
            afterEdge["data"] = afterData
        }
        edges[index] = afterEdge
        var candidate = root
        candidate["edges"] = edges
        try CanvasDocument.validate(candidate)
        root = candidate
        return CanvasStyleChange(target: .connection(id: id, beforeEdge: beforeEdge, afterEdge: afterEdge))
    }

    public func applyStyleChange(_ change: CanvasStyleChange) throws {
        guard !isReadOnly else {
            throw CanvasDocumentError("This canvas is read-only; use Save As to create an editable copy.")
        }
        var candidate = root
        switch change.target {
        case .node(let id, _, let afterData):
            guard var nodes = candidate["nodes"] as? [[String: Any]],
                  let index = nodes.firstIndex(where: { $0["id"] as? String == id }),
                  !isLocked(id) else {
                throw CanvasDocumentError("Cannot apply style change to missing or locked node.")
            }
            nodes[index]["data"] = afterData
            candidate["nodes"] = nodes
        case .connection(let id, _, let afterEdge):
            guard var edges = candidate["edges"] as? [[String: Any]],
                  let index = edges.firstIndex(where: { $0["id"] as? String == id }) else {
                throw CanvasDocumentError("Cannot apply style change to missing connection.")
            }
            edges[index] = afterEdge
            candidate["edges"] = edges
        case .document(let key, _, let afterValue):
            if let afterValue {
                candidate[key] = afterValue
            } else {
                candidate.removeValue(forKey: key)
            }
        }
        try CanvasDocument.validate(candidate)
        root = candidate
    }

    private func validatedStyleJSONValue(
        property: CanvasStyleProperty, value: CanvasStyleValue
    ) throws -> Any {
        switch (property, value) {
        case (.paperBackground, .string(let bg)):
            guard Self.supportedPaperBackgrounds.contains(bg) else {
                throw CanvasDocumentError("Unsupported paper background: \(bg).")
            }
            return bg
        case (.paperGrid, .int(let grid)):
            guard (4...200).contains(grid) else {
                throw CanvasDocumentError("Paper grid must be an integer from 4 to 200.")
            }
            return grid
        case (.fill, .string(let color)), (.stroke, .string(let color)):
            guard Self.supportedColors.contains(color) else {
                throw CanvasDocumentError("Unsupported color: \(color).")
            }
            return color
        case (.width, .int(let width)):
            guard Self.supportedWidths.contains(width) else {
                throw CanvasDocumentError("Unsupported stroke width: \(width).")
            }
            return width
        case (.dash, .bool(let dash)):
            return dash
        case (.radius, .int(let radius)):
            guard Self.supportedRadii.contains(radius) else {
                throw CanvasDocumentError("Unsupported corner radius: \(radius).")
            }
            return radius
        case (.arrow, .string(let arrow)):
            guard Self.supportedArrows.contains(arrow) else {
                throw CanvasDocumentError("Unsupported arrowhead style: \(arrow).")
            }
            return arrow
        case (.path, .string(let path)):
            guard Self.supportedPaths.contains(path) else {
                throw CanvasDocumentError("Unsupported connection path: \(path).")
            }
            return path
        case (.marker, .string(let marker)):
            guard Self.supportedMarkers.contains(marker) else {
                throw CanvasDocumentError("Unsupported connection marker: \(marker).")
            }
            return marker
        case (.font, .string(let font)):
            guard Self.supportedFonts.contains(font) else {
                throw CanvasDocumentError("Unsupported font role: \(font).")
            }
            return font
        case (.size, .string(let size)):
            guard Self.supportedSizes.contains(size) else {
                throw CanvasDocumentError("Unsupported text size: \(size).")
            }
            return size
        case (.align, .string(let align)):
            guard Self.supportedAlignments.contains(align) else {
                throw CanvasDocumentError("Unsupported text alignment: \(align).")
            }
            return align
        default:
            throw CanvasDocumentError("Invalid value for \(property.rawValue).")
        }
    }


    private func edge(_ id: String) -> [String: Any]? {
        (root["edges"] as? [[String: Any]])?.first { $0["id"] as? String == id }
    }

    private func intValue(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber,
              CFGetTypeID(n) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: n.objCType)) else { return nil }
        return Int(exactly: n.int64Value)
    }

    private func boolValue(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber,
              CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
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
